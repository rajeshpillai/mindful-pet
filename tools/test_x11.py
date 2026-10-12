"""Real XRandR/window checks in a private Xvfb display; build pet first."""
import argparse
import ctypes
import os
from pathlib import Path
import select
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
BINARY = ROOT / "zig-out/bin/pet"


def wait_for(predicate, timeout=3):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.02)
    raise AssertionError("timed out waiting for X11 geometry")


class X11(unittest.TestCase):
    def setUp(self):
        for cmd in ("Xvfb", "xrandr", "xdotool"):
            if not shutil.which(cmd):
                self.skipTest(f"requires {cmd}")
        temp = tempfile.TemporaryDirectory(prefix="mp-x11-regression-")
        self.addCleanup(temp.cleanup)
        self.runtime = Path(temp.name)
        rd, wr = os.pipe()
        try:
            self.server = subprocess.Popen(["Xvfb", "-displayfd", str(wr), "-screen", "0",
                                            "2076x1848x24", "-nolisten", "tcp"],
                                           pass_fds=(wr,), stderr=subprocess.PIPE)
        finally:
            os.close(wr)
        def stop_server():
            self.server.terminate()
            self.server.communicate(timeout=3)
        self.addCleanup(stop_server)
        try:
            self.assertTrue(select.select([rd], [], [], 3)[0], "Xvfb did not start")
            display = ":" + os.read(rd, 64).decode().strip()
        finally:
            os.close(rd)
        self.env = {**os.environ, "DISPLAY": display, "XDG_RUNTIME_DIR": str(self.runtime), "LC_ALL": "C"}
        # Keep a connection alive: otherwise Xvfb resets between xrandr calls.
        xlib = ctypes.CDLL("libX11.so.6")
        xlib.XOpenDisplay.restype = ctypes.c_void_p
        xlib.XCloseDisplay.argtypes = [ctypes.c_void_p]
        keeper = xlib.XOpenDisplay(display.encode())
        self.assertTrue(keeper)
        self.addCleanup(lambda: xlib.XCloseDisplay(keeper))
        self.run_cmd("xrandr", "--setmonitor", "hdmi", "1920/440x1080/250+0+0", "none")
        self.run_cmd("xrandr", "--setmonitor", "laptop", "1366/310x768/170+710+1080", "screen")
        self.run_cmd("xrandr", "--output", "screen", "--primary")
        self.assertIn("Monitors: 2", self.run_cmd("xrandr", "--listactivemonitors"))

    def run_cmd(self, *args):
        return subprocess.run(args, env=self.env, capture_output=True, text=True, timeout=3, check=True).stdout

    def start(self, roam=False):
        args = [str(BINARY), "--mute", "--name", "x11-regression"]
        if roam:
            args.append("--roam")
        self.pet = subprocess.Popen(args, env=self.env, stderr=subprocess.PIPE)
        def stop_pet():
            if self.pet.poll() is None:
                self.pet.terminate()
            self.pet.communicate(timeout=2)
        self.addCleanup(stop_pet)
        wait_for(lambda: (self.runtime / "pet-x11-regression.fifo").exists())
        ids = self.run_cmd("xdotool", "search", "--name", "^pet$").split()
        self.window = next(w for w in ids if self.geometry(w)["WIDTH"] == 64)
        self.command("work")
        wait_for(lambda: self.geometry()["Y"] == 1784)

    def geometry(self, window=None):
        text = self.run_cmd("xdotool", "getwindowgeometry", "--shell", window or self.window)
        return {k: int(v) for k, v in (line.split("=", 1) for line in text.splitlines())}

    def command(self, *args):
        self.run_cmd(str(ROOT / "scripts/petctl"), "-n", "x11-regression", *args)

    def quit(self):
        self.command("quit")
        _, log = self.pet.communicate(timeout=2)
        self.assertEqual(self.pet.returncode, 0, log.decode())
        self.assertIn(b"1366x768 screen", log)
        self.assertIn(b"x11 backend", log)

    def test_primary_origin_external_move_recovery_and_live_resize(self):
        self.start()
        self.run_cmd("xdotool", "mousemove", "100", "500")
        self.run_cmd("xdotool", "windowmove", self.window, "0", "3000")
        wait_for(lambda: self.geometry()["Y"] == 1784)
        self.assertTrue(710 <= self.geometry()["X"] <= 2012)
        self.run_cmd("xrandr", "--delmonitor", "laptop")
        self.run_cmd("xrandr", "--setmonitor", "laptop", "800/310x600/170+900+1200", "screen")
        wait_for(lambda: self.geometry()["Y"] == 1736)
        self.assertTrue(900 <= self.geometry()["X"] <= 1636)
        self.quit()

    def test_roam_uses_actual_monitors_and_ignores_gaps(self):
        self.start(roam=True)
        self.run_cmd("xdotool", "mousemove", "100", "500")
        time.sleep(0.15)
        self.assertEqual(self.geometry()["Y"], 1784, "work must not follow the pointer")
        self.command("done")
        time.sleep(0.08)
        self.run_cmd("xdotool", "mousemove", "110", "500")
        wait_for(lambda: self.geometry()["Y"] == 1016)
        self.assertTrue(0 <= self.geometry()["X"] <= 1856)
        self.run_cmd("xdotool", "mousemove", "100", "1800")
        time.sleep(0.1)
        self.assertEqual(self.geometry()["Y"], 1016)
        self.run_cmd("xdotool", "mousemove", "1000", "1800")
        wait_for(lambda: self.geometry()["Y"] == 1784)
        self.quit()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, default=BINARY)
    args, rest = parser.parse_known_args()
    BINARY = args.binary.resolve()
    unittest.main(argv=[__file__, *rest])
