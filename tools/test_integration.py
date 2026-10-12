"""Private-socket regression tests. Build pet first; no real desktop is touched."""
import argparse
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
BINARY = ROOT / "zig-out/bin/pet"


def wait_for(predicate, timeout=3):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.01)
    raise AssertionError("timed out waiting for the pet")


class FakeShell:
    def __init__(self, runtime, legacy=False):
        self.legacy = legacy
        self.windows = []
        self.connections = []
        self.stop = threading.Event()
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(str(runtime / "mindful-pet-shell.sock"))
        self.server.listen(8)
        self.server.settimeout(0.1)
        self.thread = threading.Thread(target=self.accept, daemon=True)
        self.thread.start()

    def accept(self):
        while not self.stop.is_set():
            try:
                conn, _ = self.server.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            self.connections.append(conn)
            threading.Thread(target=self.read, args=(conn,), daemon=True).start()

    def read(self, conn):
        window = {"conn": conn, "lines": [], "moves": []}
        try:
            with conn.makefile("rb") as reader:
                for raw in reader:
                    if raw.startswith(b"hello "):
                        _, w, h, *_ = raw.split()
                        window["primary"] = w == h
                        self.windows.append(window)
                        if self.legacy:
                            conn.sendall(b"screen 1280 800\n")
                        else:
                            conn.sendall(b"capabilities input\nscreen 710 1080 1366 768\n"
                                         b"monitors\nmonitor 0 0 1920 1080\nmonitor 710 1080 1366 768\n")
                    elif raw.startswith(b"move "):
                        window["moves"].append(tuple(map(int, raw.split()[1:])))
                    elif not raw.startswith(b"img "):
                        window["lines"].append(raw.decode().strip())
        except OSError:
            pass
        finally:
            conn.close()

    def close(self):
        self.stop.set()
        self.thread.join(timeout=1)
        self.server.close()
        for conn in self.connections:
            try:
                conn.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            conn.close()


class Integration(unittest.TestCase):
    def start(self, legacy=False, scale=4, roam=False):
        temp = tempfile.TemporaryDirectory(prefix="mp-regression-")
        self.addCleanup(temp.cleanup)
        runtime = Path(temp.name)
        shell = FakeShell(runtime, legacy)
        self.addCleanup(shell.close)
        env = {**os.environ, "XDG_RUNTIME_DIR": str(runtime)}
        args = [str(BINARY), "--mute", "--name", "regression", "--scale", str(scale)]
        if roam:
            args.append("--roam")
        pet = subprocess.Popen(args, env=env,
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        def cleanup():
            if pet.poll() is None:
                pet.terminate()
            pet.communicate(timeout=2)
        self.addCleanup(cleanup)
        fifo = runtime / "pet-regression.fifo"
        wait_for(lambda: fifo.exists() and len(shell.windows) == 2)
        return shell, pet, fifo

    def command(self, fifo, text):
        subprocess.run([str(ROOT / "scripts/petctl"), text],
                       env={**os.environ, "PET_FIFO": str(fifo)}, timeout=1, check=True)

    def test_monitor_resize_and_origin_change(self):
        shell, pet, fifo = self.start()
        primary = next(w for w in shell.windows if w["primary"])
        self.command(fifo, "work")
        wait_for(lambda: bool(primary["moves"]))
        first = primary["moves"][-1]
        for window in shell.windows:
            window["conn"].sendall(b"screen 900 1200 1366 768\n")
        expected = (first[0] + 190, first[1] + 120)
        wait_for(lambda: primary["moves"][-1] == expected)
        for window in shell.windows:
            window["conn"].sendall(b"screen 0 0 800 600\n")
        wait_for(lambda: primary["moves"][-1][1] == 536)
        self.assertLessEqual(primary["moves"][-1][0], 736)
        self.command(fifo, "quit")
        self.assertEqual(pet.wait(timeout=1), 0)

    def test_default_stays_primary_even_when_dragged_to_another_screen(self):
        shell, pet, fifo = self.start()
        primary = next(w for w in shell.windows if w["primary"])
        self.command(fifo, "work")
        wait_for(lambda: bool(primary["moves"]))
        x, y = primary["moves"][-1]
        primary["conn"].sendall(f"press 1 {x+20} {y+20} 20 20\npointer 100 500\n".encode())
        wait_for(lambda: primary["moves"][-1] == (710, 1080))
        primary["conn"].sendall(b"release 1 100 500\n")
        self.command(fifo, "quit")
        self.assertEqual(pet.wait(timeout=1), 0)

    def test_roam_follows_pointer_and_bubble_without_entering_gaps(self):
        shell, pet, fifo = self.start(roam=True)
        primary = next(w for w in shell.windows if w["primary"])
        bubble = next(w for w in shell.windows if not w["primary"])
        self.command(fifo, "work")
        self.command(fifo, "say roaming")
        wait_for(lambda: bool(primary["moves"]))
        primary["conn"].sendall(b"pointer 100 500\n")
        wait_for(lambda: primary["moves"][-1][1] == 1016)
        wait_for(lambda: bool(bubble["moves"]) and bubble["moves"][-1][1] < 1080)
        self.assertTrue(0 <= primary["moves"][-1][0] <= 1856)
        before = primary["moves"][-1]
        primary["conn"].sendall(b"pointer 100 1800\n")  # a gap below the top screen
        time.sleep(0.1)
        self.assertEqual(primary["moves"][-1], before)
        primary["conn"].sendall(b"pointer 1000 1800\n")
        wait_for(lambda: primary["moves"][-1][1] == 1784)
        self.assertTrue(710 <= primary["moves"][-1][0] <= 2012)
        self.command(fifo, "quit")
        self.assertEqual(pet.wait(timeout=1), 0)

    def test_roam_drag_continues_across_monitor_origins(self):
        shell, pet, fifo = self.start(roam=True)
        primary = next(w for w in shell.windows if w["primary"])
        self.command(fifo, "work")
        wait_for(lambda: bool(primary["moves"]))
        x, y = primary["moves"][-1]
        primary["conn"].sendall(f"press 1 {x+20} {y+20} 20 20\npointer 100 500\n".encode())
        wait_for(lambda: primary["moves"][-1] == (80, 480))
        primary["conn"].sendall(b"pointer 120 550\n")
        wait_for(lambda: primary["moves"][-1] == (100, 530))
        primary["conn"].sendall(b"pointer 1000 1300\n")
        wait_for(lambda: primary["moves"][-1] == (980, 1280))
        primary["conn"].sendall(b"release 1 1000 1300\n")
        wait_for(lambda: primary["moves"][-1][1] == 1784)
        self.command(fifo, "quit")
        self.assertEqual(pet.wait(timeout=1), 0)

    def test_bubble_disconnect_exits_cleanly(self):
        shell, pet, _ = self.start()
        bubble = next(w for w in shell.windows if not w["primary"])
        bubble["conn"].shutdown(socket.SHUT_RDWR)
        self.assertEqual(pet.wait(timeout=1), 0)

    def test_input_disabled_on_bubble_only(self):
        shell, pet, fifo = self.start()
        bubble = next(w for w in shell.windows if not w["primary"])
        primary = next(w for w in shell.windows if w["primary"])
        wait_for(lambda: "input 0" in bubble["lines"] and "input 1" in primary["lines"])
        self.command(fifo, "work")
        time.sleep(0.5)  # multiple animation frames must not resend input mode
        self.assertEqual(primary["lines"].count("input 1"), 1)
        self.command(fifo, "quit")
        self.assertEqual(pet.wait(timeout=1), 0)

    def test_wide_bubble_survives_monitor_shrink(self):
        shell, pet, fifo = self.start(scale=12)
        self.command(fifo, "work")
        for window in shell.windows:
            window["conn"].sendall(b"screen 0 0 800 600\n")
        self.command(fifo, "say " + "x" * 40)
        bubble = next(w for w in shell.windows if not w["primary"])
        wait_for(lambda: bool(bubble["moves"]))
        self.assertGreaterEqual(bubble["moves"][-1][0], 0)
        self.command(fifo, "quit")
        self.assertEqual(pet.wait(timeout=1), 0)

    def test_old_extension_remains_compatible(self):
        shell, pet, fifo = self.start(legacy=True)
        self.command(fifo, "say hello")
        self.command(fifo, "quit")
        _, log = pet.communicate(timeout=1)
        self.assertEqual(pet.returncode, 0)
        self.assertIn(b"1280x800 screen", log)
        for window in shell.windows:
            self.assertFalse(any(line.startswith("input ") for line in window["lines"]))

    def test_petctl_full_fifo_and_missing_reader(self):
        with tempfile.TemporaryDirectory(prefix="mp-fifo-regression-") as runtime:
            fifo = Path(runtime) / "pet.fifo"
            os.mkfifo(fifo, 0o600)
            self.command(fifo, "quit")  # no reader: must return immediately
            fd = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
            try:
                while True:
                    try:
                        os.write(fd, b"x" * 4096)
                    except BlockingIOError:
                        break
                self.command(fifo, "quit")  # full: must drop, never wait
                subprocess.run([str(ROOT / "scripts/petctl"), "run", "true"],
                               env={**os.environ, "PET_FIFO": str(fifo)}, timeout=1, check=True)
            finally:
                os.close(fd)

    def test_petctl_ignores_python_environment(self):
        with tempfile.TemporaryDirectory(prefix="mp-python-regression-") as runtime:
            fifo = Path(runtime) / "pet.fifo"
            os.mkfifo(fifo, 0o600)
            fd = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
            try:
                env = {**os.environ, "PET_FIFO": str(fifo), "PYTHONHOME": "/nonexistent-python-home",
                       "PYTHONPATH": runtime}
                result = subprocess.run([str(ROOT / "scripts/petctl"), "ok"], env=env,
                                        cwd=runtime, timeout=1, capture_output=True, check=True)
                self.assertEqual(result.stderr, b"")
                self.assertEqual(os.read(fd, 512), b"ok\n")
            finally:
                os.close(fd)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, default=BINARY)
    args, rest = parser.parse_known_args()
    BINARY = args.binary.resolve()
    unittest.main(argv=[__file__, *rest])
