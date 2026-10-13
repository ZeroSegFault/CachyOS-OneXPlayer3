"""Exercise the real battery D-Bus service on an isolated bus and fake sysfs.

Run: /usr/bin/python3 tests/test_charge_limit.py
Requires python-gobject and dbus-run-session; never touches host power settings.
"""

import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SERVICE = ROOT / "files/pkg/oxp3-support/oxp3-charge-limit"
BUS_NAME = "local.oxp3.ChargeLimit"
OBJECT_PATH = "/local/oxp3/ChargeLimit"
IFACE = "com.steampowered.SteamOSManager1.BatteryChargeLimit1"


class ChargeLimitTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.threshold = Path(self.temp.name) / "charge_control_end_threshold"
        self.threshold.write_text("80\n")
        self.log = open(Path(self.temp.name) / "service.log", "w+")
        self.addCleanup(self.log.close)
        self.process = None
        self.addCleanup(self.stop_service)
        self.start_service()

    def start_service(self):
        self.process = subprocess.Popen(
            [sys.executable, "-c",
             "import runpy,sys; sys.exit(runpy.run_path(sys.argv[1])['main'](sys.argv[2]))",
             str(SERVICE), str(self.threshold)],
            env={**os.environ, "DBUS_SYSTEM_BUS_ADDRESS": os.environ["DBUS_SESSION_BUS_ADDRESS"]},
            stdout=self.log, stderr=self.log,
        )
        for _ in range(100):
            result = self.bus("get-property", IFACE, "MaxChargeLevel", check=False)
            if result.returncode == 0:
                return
            if self.process.poll() is not None:
                break
            time.sleep(0.02)
        self.log.seek(0)
        self.fail(f"service did not start: {self.log.read()}")

    def stop_service(self):
        if self.process is not None:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
                self.fail("service did not stop on SIGTERM")
            self.process = None

    def bus(self, operation, *args, check=True):
        return subprocess.run(
            ["busctl", f"--address={os.environ['DBUS_SESSION_BUS_ADDRESS']}",
             "--timeout=2", operation, "--", BUS_NAME, OBJECT_PATH, *args],
            text=True, capture_output=True, check=check, timeout=3,
        )

    def set_limit(self, value, check=True):
        return self.bus("set-property", IFACE, "MaxChargeLevel", "i", str(value), check=check)

    def get_limit(self):
        return self.bus("get-property", IFACE, "MaxChargeLevel").stdout.strip()

    def test_disabled_limit_charges_to_full(self):
        self.set_limit(-1)
        self.assertEqual(self.threshold.read_text(), "100\n")
        self.assertEqual(self.get_limit(), "i -1")

    def test_positive_limit_round_trip(self):
        self.set_limit(60)
        self.assertEqual(self.threshold.read_text(), "60\n")
        self.assertEqual(self.get_limit(), "i 60")
        self.set_limit(100)
        self.assertEqual(self.threshold.read_text(), "100\n")
        self.assertEqual(self.get_limit(), "i -1")

    def test_invalid_values_do_not_change_the_target(self):
        for value in (-2, 0, 101):
            with self.subTest(value=value):
                self.assertNotEqual(self.set_limit(value, check=False).returncode, 0)
                self.assertEqual(self.threshold.read_text(), "80\n")

    def test_repeated_request_does_not_rewrite_hardware(self):
        self.set_limit(-1)
        before = self.threshold.stat().st_mtime_ns
        self.set_limit(-1)
        self.assertEqual(self.threshold.stat().st_mtime_ns, before)

    def test_restart_preserves_positive_user_limit(self):
        self.set_limit(60)
        self.stop_service()
        self.start_service()
        self.assertEqual(self.get_limit(), "i 60")
        self.assertEqual(self.threshold.read_text(), "60\n")

    def test_start_repairs_legacy_zero_target(self):
        self.stop_service()
        self.threshold.write_text("0\n")
        self.start_service()
        self.assertEqual(self.threshold.read_text(), "100\n")
        self.assertEqual(self.get_limit(), "i -1")

    def test_missing_battery_reports_failure_then_recovers(self):
        self.threshold.unlink()
        self.assertNotEqual(self.set_limit(-1, check=False).returncode, 0)
        self.assertFalse(self.threshold.exists())
        self.threshold.write_text("80\n")
        self.set_limit(-1)
        self.assertEqual(self.threshold.read_text(), "100\n")

    def test_suggested_minimum_is_read_only(self):
        result = self.bus("get-property", IFACE, "SuggestedMinimumLimit")
        self.assertEqual(result.stdout.strip(), "i 10")
        result = self.bus("set-property", IFACE, "SuggestedMinimumLimit", "i", "20", check=False)
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    if "--inside-bus" not in sys.argv:
        sys.exit(subprocess.call(["dbus-run-session", "--", sys.executable, __file__, "--inside-bus"]))
    sys.argv.remove("--inside-bus")
    unittest.main()
