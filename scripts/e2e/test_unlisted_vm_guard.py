import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import unlisted_vm_guard as guard


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        known = Path(self.tmp.name) / "known_hosts"
        known.write_text("blackice-vm4 ssh-ed25519 TEST-FIXTURE\n")
        known.chmod(0o600)
        self.manifest = dict(directory=guard.VM_DIRECTORY, hostname=guard.VM_NAME,
                             machine_id="a" * 32, boot_id="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                             ssh_port=2225, ssh_user="demo", known_hosts=str(known),
                             host_key_sha256="SHA256:" + "a" * 43)
        self.observed = dict(hostname=guard.VM_NAME, machine_id=self.manifest["machine_id"],
                             boot_id=self.manifest["boot_id"], virtualization="kvm", uid=1000)
        self.calls = []

    def run_mock(self, args, **kwargs):
        self.calls.append(args)
        if args[0] == "/usr/bin/ssh-keygen":
            return subprocess.CompletedProcess(args, 0, "256 " + self.manifest["host_key_sha256"] + " fixture\n")
        self.assertEqual(args[0], "/usr/bin/ssh")
        self.assertIn("StrictHostKeyChecking=yes", args)
        self.assertIn("GlobalKnownHostsFile=/dev/null", args)
        self.assertIn("ClearAllForwardings=yes", args)
        self.assertEqual(args[-2:], ["demo@127.0.0.1", "/usr/bin/python3 -I -"])
        self.assertEqual(kwargs["input"], guard.GUEST_QUERY)
        return subprocess.CompletedProcess(args, 0, json.dumps(self.observed))

    def test_only_declared_guest_is_queried_read_only(self):
        self.assertEqual(guard.preflight(self.manifest, "b" * 32, self.run_mock), self.observed)
        self.assertEqual(len(self.calls), 2)

    def test_host_other_vm_and_injected_fields_refuse_before_any_process(self):
        for key, value in [("hostname", "valendebian"), ("directory", "/var/tmp/blackice-vm3"),
                           ("machine_id", "b" * 32), ("ssh_user", "root"),
                           ("ssh_user", "-oProxyCommand=anything"), ("ssh_port", True)]:
            with self.subTest(key=key):
                changed = self.manifest | {key: value}
                with self.assertRaises(ValueError):
                    guard.preflight(changed, "b" * 32, self.run_mock)
        with self.assertRaises(ValueError):
            guard.preflight(self.manifest | {"command": "anything"}, "b" * 32, self.run_mock)
        self.assertEqual(self.calls, [])

    def test_unreachable_guest_has_no_local_fallback(self):
        def fail(args, **kwargs):
            if args[0] == "/usr/bin/ssh":
                self.calls.append(args)
                raise subprocess.CalledProcessError(255, args)
            return self.run_mock(args, **kwargs)
        with self.assertRaises(subprocess.CalledProcessError):
            guard.preflight(self.manifest, "b" * 32, fail)
        self.assertEqual([c[0] for c in self.calls], ["/usr/bin/ssh-keygen", "/usr/bin/ssh"])

    def test_observed_host_reboot_or_non_kvm_refuses(self):
        for key, value in [("hostname", "valendebian"), ("machine_id", "b" * 32),
                           ("boot_id", "bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee"),
                           ("uid", 0), ("virtualization", "none")]:
            with self.subTest(key=key):
                with self.assertRaises(ValueError):
                    guard.check_observation(self.manifest, self.observed | {key: value})

    def test_identity_duplicates_and_symlinks_refuse(self):
        with self.assertRaises(ValueError):
            json.loads('{"hostname":"one","hostname":"two"}', object_pairs_hook=guard.unique_pairs)
        linked = Path(self.tmp.name) / "link"
        linked.symlink_to(self.manifest["known_hosts"])
        with self.assertRaises(OSError):
            guard.regular(linked)


if __name__ == "__main__":
    unittest.main()
