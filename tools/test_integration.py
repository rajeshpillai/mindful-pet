"""Private-socket regression tests. Build pet first; no real desktop is touched."""
import argparse
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
BINARY = ROOT / "zig-out/bin/pet"


# A 1920x1080 monitor above a 1366x768 primary panel at x=710.
STACKED = ((0, 0, 1920, 1080), (710, 1080, 1366, 768))


def snapshot(primary, monitors):
    """The v3 geometry snapshot the extension sends on connect and on monitor changes."""
    lines = ["screen %d %d %d %d" % primary, "monitors %d" % len(monitors)]
    lines.extend("monitor %d %d %d %d" % m for m in monitors)
    return ("\n".join(lines) + "\n").encode()


def wait_for(predicate, timeout=3):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.01)
    raise AssertionError("timed out waiting for the pet")


class FakeShell:
    def __init__(self, runtime, legacy=False, geometry=None):
        self.legacy = legacy
        self.geometry = geometry
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
                            geometry = self.geometry if self.geometry is not None else snapshot(STACKED[1], STACKED)
                            conn.sendall(b"capabilities input monitors\n" + geometry)
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
    def start(self, legacy=False, scale=4, roam=False, roam_group=None, geometry=None):
        temp = tempfile.TemporaryDirectory(prefix="mp-regression-")
        self.addCleanup(temp.cleanup)
        runtime = Path(temp.name)
        shell = FakeShell(runtime, legacy, geometry)
        self.addCleanup(shell.close)
        env = {**os.environ, "XDG_RUNTIME_DIR": str(runtime)}
        args = [str(BINARY), "--mute", "--name", "regression", "--scale", str(scale)]
        if roam:
            args.append("--roam")
        if roam_group:
            args.extend(["--roam-group", roam_group])
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
            window["conn"].sendall(snapshot((900, 1200, 1366, 768), (STACKED[0], (900, 1200, 1366, 768))))
        expected = (first[0] + 190, first[1] + 120)
        wait_for(lambda: primary["moves"][-1] == expected)
        for window in shell.windows:
            window["conn"].sendall(snapshot((0, 0, 800, 600), ((0, 0, 800, 600),)))
        wait_for(lambda: primary["moves"][-1][1] == 536)
        self.assertLessEqual(primary["moves"][-1][0], 736)
        self.command(fifo, "quit")
        self.assertEqual(pet.wait(timeout=1), 0)

    def test_monitor_snapshot_applies_only_once_complete(self):
        shell, pet, fifo = self.start(roam=True)
        primary = next(w for w in shell.windows if w["primary"])
        self.command(fifo, "work")
        wait_for(lambda: bool(primary["moves"]))
        before = primary["moves"][-1]
        whole = snapshot((0, 0, 800, 600), ((0, 0, 800, 600), (900, 1200, 1366, 768)))
        head, tail = whole.rsplit(b"\n", 2)[0] + b"\n", whole.rsplit(b"\n", 2)[1] + b"\n"
        self.assertTrue(tail.startswith(b"monitor 900"))
        for window in shell.windows:
            window["conn"].sendall(head)
        time.sleep(0.3)
        self.assertEqual(primary["moves"][-1], before, "a partial snapshot must not move the pet")
        for window in shell.windows:
            window["conn"].sendall(tail)
        wait_for(lambda: primary["moves"][-1][1] == 536)
        # The new list is usable at once: the pointer finds the second monitor.
        self.command(fifo, "done")
        time.sleep(0.08)
        primary["conn"].sendall(b"pointer 1000 1300\n")
        wait_for(lambda: primary["moves"][-1][1] == 1904)
        self.command(fifo, "quit")
        self.assertEqual(pet.wait(timeout=1), 0)

    def test_invalid_or_incomplete_snapshots_recover_at_startup_and_hotplug(self):
        for suffix in (b"", b"monitors 2\nmonitor 0 0 1920 1080\n",
                       b"monitors 999999\nmonitor 0 0 1920 1080\n"):
            with self.subTest(suffix=suffix):
                shell, pet, fifo = self.start(roam=True, geometry=b"screen 710 1080 1366 768\n" + suffix)
                primary = next(w for w in shell.windows if w["primary"])
                self.command(fifo, "work")
                wait_for(lambda: bool(primary["moves"]))
                self.assertEqual(primary["moves"][-1][1], 1784)
                for window in shell.windows:
                    window["conn"].sendall(b"screen 0 0 800 600\n" + suffix)
                wait_for(lambda: primary["moves"][-1][1] == 536)
                self.assertLessEqual(primary["moves"][-1][0], 736)
                for window in shell.windows:
                    window["conn"].sendall(snapshot(STACKED[1], STACKED))
                wait_for(lambda: primary["moves"][-1][1] == 1784)
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
        self.command(fifo, "done")
        time.sleep(0.08)
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

    def test_solo_pointer_roaming_leaves_work_and_sleep_undisturbed(self):
        for state in ("work", "sleep"):
            with self.subTest(state=state):
                shell, pet, fifo = self.start(roam=True)
                primary = next(w for w in shell.windows if w["primary"])
                self.command(fifo, state)
                wait_for(lambda: bool(primary["moves"]))
                time.sleep(0.08)
                primary["conn"].sendall(b"pointer 100 500\n")
                time.sleep(0.15)
                self.assertEqual(primary["moves"][-1][1], 1784)
                self.command(fifo, "done" if state == "work" else "wake")
                time.sleep(0.75)
                primary["conn"].sendall(b"pointer 110 500\n")
                wait_for(lambda: primary["moves"][-1][1] == 1016)
                self.command(fifo, "quit")
                self.assertEqual(pet.wait(timeout=1), 0)

    def test_same_monitor_pointer_motion_keeps_group_heartbeat_bounded(self):
        shell, pet, fifo = self.start(roam_group="heartbeat")
        primary = next(w for w in shell.windows if w["primary"])
        path = fifo.parent / f"pet-roam-{os.geteuid()}-heartbeat.state"
        wait_for(lambda: path.exists() and path.stat().st_size > 0)
        self.command(fifo, "work")
        time.sleep(0.08)
        self.command(fifo, "done")
        time.sleep(0.08)
        last_write = path.stat().st_mtime_ns
        changes = 0
        for i in range(40):
            primary["conn"].sendall(f"pointer {1000+i} 1300\n".encode())
            time.sleep(0.02)
            stamp = path.stat().st_mtime_ns
            if stamp != last_write:
                changes += 1
                last_write = stamp
        self.assertLessEqual(changes, 7, "local pointer motion must not write the group file every frame")
        self.command(fifo, "quit")
        self.assertEqual(pet.wait(timeout=1), 0)

    def test_missing_shared_monitor_falls_back_without_rewriting_the_plan(self):
        shell, pet, fifo = self.start(roam_group="geometry")
        primary = next(w for w in shell.windows if w["primary"])
        path = fifo.parent / f"pet-roam-{os.geteuid()}-geometry.state"
        wait_for(lambda: bool(primary["moves"]))
        primary["conn"].sendall(b"pointer 100 500\n")
        wait_for(lambda: primary["moves"][-1][1] == 1016)
        wait_for(lambda: struct.unpack_from("<ii", path.read_bytes(), 40) == (0, 0))
        for window in shell.windows:
            window["conn"].sendall(snapshot(STACKED[1], (STACKED[1],)))
        wait_for(lambda: primary["moves"][-1][1] == 1784)
        time.sleep(0.3)
        self.assertIsNone(pet.poll())
        self.assertEqual(struct.unpack_from("<ii", path.read_bytes(), 40), (0, 0))
        self.command(fifo, "quit")
        _, log = pet.communicate(timeout=2)
        self.assertEqual(pet.returncode, 0, log.decode())
        self.assertEqual(log.decode().count("leaving group geometry (IncompatibleMonitors); roaming alone"), 1)

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

    def test_final_motion_and_release_in_one_frame_lands_in_default_and_group_modes(self):
        for group in (None, "drop-order"):
            with self.subTest(group=group):
                shell, pet, fifo = self.start(roam_group=group)
                primary = next(w for w in shell.windows if w["primary"])
                self.command(fifo, "work")
                wait_for(lambda: bool(primary["moves"]))
                x, y = primary["moves"][-1]
                count = len(primary["moves"])
                primary["conn"].sendall(f"press 1 {x+20} {y+20} 20 20\npointer 100 500\nrelease 1 100 500\n".encode())
                wait_for(lambda: any(my < 1784 for _, my in primary["moves"][count:]))
                floor = 1016 if group else 1784
                wait_for(lambda: primary["moves"][-1][1] == floor)
                self.command(fifo, "quit")
                self.assertEqual(pet.wait(timeout=1), 0)

    def test_group_monitor_request_survives_lock_contention(self):
        import fcntl
        shell, pet, fifo = self.start(roam_group="contended")
        primary = next(w for w in shell.windows if w["primary"])
        path = fifo.parent / f"pet-roam-{os.geteuid()}-contended.state"
        wait_for(lambda: path.exists() and path.stat().st_size > 0)
        with path.open("rb") as plan:
            fcntl.flock(plan, fcntl.LOCK_EX | fcntl.LOCK_NB)
            primary["conn"].sendall(b"pointer 100 500\n")
            wait_for(lambda: primary["moves"][-1][1] == 1016)
            time.sleep(0.1)
            fcntl.flock(plan, fcntl.LOCK_UN)
        # No further pointer event: the pending request must reach the group file.
        time.sleep(0.5)
        self.assertEqual(primary["moves"][-1][1], 1016)
        with path.open("rb") as plan:
            header = struct.unpack("<QqqqQiiiiII", plan.read(64))
        self.assertEqual(header[5:9], STACKED[0])
        self.command(fifo, "quit")
        self.assertEqual(pet.wait(timeout=1), 0)

    def test_group_goto_walk_is_not_overridden_by_a_shared_plan(self):
        shell, pet, fifo = self.start(roam_group="manual-walk")
        primary = next(w for w in shell.windows if w["primary"])
        path = fifo.parent / f"pet-roam-{os.geteuid()}-manual-walk.state"
        wait_for(lambda: path.exists() and path.stat().st_size > 0 and bool(primary["moves"]))
        self.command(fifo, "work")
        time.sleep(0.1)
        x, y = primary["moves"][-1]
        primary["conn"].sendall(f"press 1 {x+20} {y+20} 20 20\npointer 1380 1804\nrelease 1 1380 1804\n".encode())
        wait_for(lambda: primary["moves"][-1] == (1360, 1784))
        with path.open("rb") as plan:
            header = struct.unpack("<QqqqQiiiiII", plan.read(64))
        direction = 1 if header[9] / 1_000_000 * 1366 > 682 else -1
        start = primary["moves"][-1][0]
        # Walk away from the group's current destination for over a poll interval.
        target = 32 if direction > 0 else 1334
        self.command(fifo, f"goto {target}")
        wait_for(lambda: -direction * (primary["moves"][-1][0] - start) >= 40)
        self.command(fifo, "quit")
        self.assertEqual(pet.wait(timeout=1), 0)

    def test_multiple_pets_share_only_their_named_group_and_resume_after_sleep(self):
        temp = tempfile.TemporaryDirectory(prefix="mp-groups-regression-")
        self.addCleanup(temp.cleanup)
        runtime = Path(temp.name)
        shell = FakeShell(runtime)
        self.addCleanup(shell.close)
        env = {**os.environ, "XDG_RUNTIME_DIR": str(runtime), "PET_DEBUG": "1"}
        clients = []
        for name, group in (("cat", "friends"), ("dog", "friends"), ("rabbit", "other"), ("solo", None)):
            count = len(shell.windows)
            args = [str(BINARY), "--mute", "--name", name, "--pet", name if name != "solo" else "cat"]
            args.extend(["--roam-group", group] if group else ["--roam"])
            pet = subprocess.Popen(args, env=env, stderr=subprocess.PIPE)
            def cleanup(pet=pet):
                if pet.poll() is None:
                    pet.terminate()
                pet.communicate(timeout=2)
            self.addCleanup(cleanup)
            fifo = runtime / f"pet-{name}.fifo"
            wait_for(lambda: fifo.exists() and len(shell.windows) == count + 2)
            primary = next(w for w in shell.windows[count:] if w["primary"])
            wait_for(lambda: bool(primary["moves"]))
            clients.append((pet, fifo, primary))
        cat, dog, other, solo = clients

        def broadcast(line):
            # The shell reports the pointer to every window, not only the one under it.
            for pet, _, primary in clients:
                if pet.poll() is None:
                    primary["conn"].sendall(line)

        self.command(dog[1], "sleep")
        self.command(other[1], "sleep")
        time.sleep(0.1)
        broadcast(b"pointer 100 500\n")
        wait_for(lambda: cat[2]["moves"][-1][1] == 1016)
        wait_for(lambda: solo[2]["moves"][-1][1] == 1016)
        time.sleep(0.3)
        self.assertEqual(dog[2]["moves"][-1][1], 1784, "sleep should delay joining a group visit")
        self.assertEqual(other[2]["moves"][-1][1], 1784, "a sleeping group member must not follow the pointer")
        self.command(dog[1], "wake")
        wait_for(lambda: dog[2]["moves"][-1][1] == 1016)
        self.command(other[1], "wake")
        time.sleep(0.5)
        self.assertEqual(other[2]["moves"][-1][1], 1784, "a different group must stay independent")
        self.assertEqual(len(list(runtime.glob("pet-roam-*.state"))), 2)
        # A group has no permanent leader: the surviving pet keeps responding.
        self.command(cat[1], "quit")
        self.assertEqual(cat[0].wait(timeout=1), 0)
        broadcast(b"pointer 1000 1800\n")
        wait_for(lambda: dog[2]["moves"][-1][1] == 1784)
        logs = []
        for pet, fifo, _ in clients:
            if pet.poll() is None:
                self.command(fifo, "quit")
            _, log = pet.communicate(timeout=2)
            self.assertEqual(pet.returncode, 0, log.decode())
            logs.append(log.decode())
        self.assertIn("group friends monitor 0,0 walk to", logs[0])
        self.assertIn("group friends monitor 0,0 walk to", logs[1])
        self.assertNotIn("group other monitor 0,0", logs[2], "the pointer must not plan a visit for a sleeping group")
        self.assertNotIn(" group ", logs[3], "--roam must not join a group implicitly")

    def test_group_file_failure_degrades_to_solo_roaming(self):
        shell, pet, fifo = self.start()
        runtime = fifo.parent
        env = {**os.environ, "XDG_RUNTIME_DIR": str(runtime), "PET_DEBUG": "1"}
        # A full group: 32 members with fresh heartbeats, in the private state layout.
        now = time.monotonic_ns() // 1_000_000 - 50
        member = struct.Struct("<qqII")
        header = struct.Struct("<QqqqQiiiiII")
        state = header.pack(0x4d50524752503031, now, now + 30000, now + 8000, 1,
                            *STACKED[1], 500000, 0)
        state += b"".join(member.pack(i + 1, now, 64, 0) for i in range(32))
        path = runtime / f"pet-roam-{os.geteuid()}-full.state"
        path.write_bytes(state)
        path.chmod(0o600)
        count = len(shell.windows)
        full = subprocess.Popen([str(BINARY), "--mute", "--name", "full", "--roam-group", "full"],
                                env=env, stderr=subprocess.PIPE)
        def cleanup():
            if full.poll() is None:
                full.terminate()
            full.communicate(timeout=2)
        self.addCleanup(cleanup)
        full_fifo = runtime / "pet-full.fifo"
        wait_for(lambda: full_fifo.exists() and len(shell.windows) == count + 2)
        primary = next(w for w in shell.windows[count:] if w["primary"])
        self.command(full_fifo, "work")
        wait_for(lambda: bool(primary["moves"]))
        time.sleep(0.3)
        self.assertIsNone(full.poll(), "a group failure must not end the pet")
        self.command(full_fifo, "done")
        time.sleep(0.08)
        primary["conn"].sendall(b"pointer 100 500\n")
        wait_for(lambda: primary["moves"][-1][1] == 1016)
        self.command(full_fifo, "quit")
        _, log = full.communicate(timeout=2)
        self.assertEqual(full.returncode, 0, log.decode())
        self.assertIn("leaving group full (GroupFull); roaming alone", log.decode())
        self.assertNotIn("group full monitor", log.decode())
        self.command(fifo, "quit")
        self.assertEqual(pet.wait(timeout=1), 0)

    def test_group_rejects_unsafe_paths_and_does_not_wait_on_a_locked_plan(self):
        shell, pet, fifo = self.start()
        runtime = fifo.parent
        env = {**os.environ, "XDG_RUNTIME_DIR": str(runtime)}
        for name in ("../escape", "", "x" * 33):
            result = subprocess.run([str(BINARY), "--roam-group", name], env=env, capture_output=True, timeout=1)
            self.assertEqual(result.returncode, 2)
        path = runtime / f"pet-roam-{os.geteuid()}-unsafe.state"
        victim = runtime / "untouched"
        victim.write_text("keep this")
        path.symlink_to(victim)
        result = subprocess.run([str(BINARY), "--mute", "--name", "unsafe", "--roam-group", "unsafe"],
                                env=env, capture_output=True, timeout=2)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(victim.read_text(), "keep this")
        # Holding the plan lock must not delay socket processing or clean quit.
        import fcntl
        lock_path = runtime / f"pet-roam-{os.geteuid()}-locked.state"
        fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            member = subprocess.Popen([str(BINARY), "--mute", "--name", "locked", "--roam-group", "locked"],
                                      env=env, stderr=subprocess.PIPE)
            try:
                member_fifo = runtime / "pet-locked.fifo"
                wait_for(member_fifo.exists)
                self.command(member_fifo, "quit")
                _, log = member.communicate(timeout=1)
                self.assertEqual(member.returncode, 0, log.decode())
            finally:
                if member.poll() is None:
                    member.terminate()
                    member.communicate(timeout=2)
        finally:
            os.close(fd)
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
            window["conn"].sendall(snapshot((0, 0, 800, 600), ((0, 0, 800, 600),)))
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
