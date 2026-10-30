#!/usr/bin/python3
"""Offline fixture checks. Every socket constructor is replaced; no network or fork runs."""
import errno
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import sys
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
path = Path(__file__).resolve().parents[1] / "scripts/e2e/linux-appfilter-probe.py"
spec = importlib.util.spec_from_file_location("appfilter_probe", path)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class ProbeResultTests(unittest.TestCase):
    def run_send(self, expected, exception):
        args = SimpleNamespace(v4="192.0.2.1", v6="2001:db8::1", token="unit", phase="test", expect=expected)
        rows = []
        with patch.object(probe.socket, "socket", side_effect=exception), patch.object(probe, "emit", side_effect=lambda _event, **row: rows.append(row)):
            result = probe.send(args)
        self.assertEqual(len(rows), 6)
        return result, rows

    def test_permission_error_is_a_refusal_but_not_a_control(self):
        result, rows = self.run_send("deny", PermissionError(errno.EPERM, "test"))
        self.assertEqual(result, 0)
        self.assertTrue(all(row["passed"] for row in rows))
        self.assertEqual(self.run_send("control", PermissionError(errno.EPERM, "test"))[0], 1)

    def test_timeout_without_errno_never_counts_as_delivery_or_filtering(self):
        for expected in ("control", "deny"):
            result, rows = self.run_send(expected, TimeoutError("test"))
            self.assertEqual(result, 1)
            self.assertTrue(all(not row["passed"] for row in rows))

    def test_missing_route_never_counts_as_filtering(self):
        self.assertEqual(self.run_send("deny", OSError(errno.ENETUNREACH, "test"))[0], 1)

    def test_explicit_unicast_families_and_mapped_cases(self):
        self.assertEqual(probe.address("192.0.2.1", 4), "192.0.2.1")
        for value, family in (("0.0.0.0", 4), ("224.0.0.1", 4), ("::", 6), ("::1", 4)):
            with self.assertRaises(ValueError):
                probe.address(value, family)
        entries = probe.cases("192.0.2.1", "2001:db8::1")
        self.assertEqual(len({row[0] for row in entries}), 6)
        self.assertEqual(entries[4][3], ("::ffff:192.0.2.1", 47121))


if __name__ == "__main__":
    unittest.main()
