"""Offline tests. No keychain access, signing, notarization or app execution."""
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

MACOS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("signing", MACOS / "Signing/sign_notarize.py")
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)
TEAM = "ABCDE12345"
CERT = b"synthetic certificate bytes, not a real signing identity"
FINGERPRINT = hashlib.sha1(CERT).hexdigest().upper()
IDENTITY = "Developer ID Application: Synthetic Test (" + TEAM + ")"
NOW = datetime(2026, 10, 30, tzinfo=timezone.utc)


def profile(bundle_id):
    return {
        "TeamIdentifier": [TEAM], "ProvisionsAllDevices": True,
        "ApplicationIdentifierPrefix": [TEAM], "DeveloperCertificates": [CERT],
        "ExpirationDate": datetime(2030, 1, 1),
        "Entitlements": {signing.TEAM_KEY: TEAM, signing.APP_KEY: TEAM + "." + bundle_id,
                         signing.NE_KEY: [signing.NE_VALUE, "packet-tunnel-provider-systemextension"]},
    }


def template(role):
    return plistlib.loads((MACOS / "Resources" / (role + ".entitlements")).read_bytes())


class SigningTests(unittest.TestCase):
    def test_exact_valid_identity_required(self):
        row = '  1) ' + FINGERPRINT + ' "' + IDENTITY + '"\n'
        self.assertEqual(signing.identity_fingerprint(row, IDENTITY, TEAM), FINGERPRINT)
        for listing, identity, team in [("", IDENTITY, TEAM), (row + row, IDENTITY, TEAM),
                                        (row, IDENTITY, "OTHER12345"), (row, "Apple Development: Test", TEAM)]:
            with self.assertRaises(ValueError):
                signing.identity_fingerprint(listing, identity, team)

    def test_only_reviewed_entitlements_are_claimed(self):
        for role, bundle_id in [("Host", signing.HOST_ID), ("Filter", signing.FILTER_ID)]:
            values = signing.make_entitlements(profile(bundle_id), template(role), TEAM, bundle_id, FINGERPRINT, NOW)
            self.assertEqual(values[signing.NE_KEY], [signing.NE_VALUE])
            self.assertEqual(values[signing.TEAM_KEY], TEAM)
            self.assertEqual(values[signing.APP_KEY], TEAM + "." + bundle_id)
            self.assertEqual(set(values), {signing.NE_KEY, signing.TEAM_KEY, signing.APP_KEY} |
                             ({signing.INSTALL_KEY} if role == "Host" else set()))

    def test_app_id_prefix_can_differ_from_team_id(self):
        candidate = profile(signing.HOST_ID)
        candidate["ApplicationIdentifierPrefix"] = ["PREFIX1234"]
        candidate["Entitlements"][signing.APP_KEY] = "PREFIX1234." + signing.HOST_ID
        values = signing.make_entitlements(candidate, template("Host"), TEAM, signing.HOST_ID, FINGERPRINT, NOW)
        self.assertEqual(values[signing.APP_KEY], "PREFIX1234." + signing.HOST_ID)
        self.assertEqual(values[signing.TEAM_KEY], TEAM)

    def test_profile_team_bundle_certificate_type_expiry_and_capability_gates(self):
        changes = [
            (False, "TeamIdentifier", ["OTHER12345"]), (False, "ProvisionsAllDevices", False),
            (False, "ProvisionedDevices", ["synthetic-device"]), (False, "ExpirationDate", datetime(2020, 1, 1)),
            (False, "DeveloperCertificates", [b"different certificate"]),
            (False, "ApplicationIdentifierPrefix", [TEAM, "OTHER12345"]),
            (True, signing.APP_KEY, TEAM + ".*"), (True, signing.TEAM_KEY, "OTHER12345"),
            (True, signing.NE_KEY, ["content-filter-provider"]), (True, signing.INSTALL_KEY, False),
            (True, "get-task-allow", True), (True, "com.apple.security.get-task-allow", True),
        ]
        for entitlement, key, value in changes:
            candidate = profile(signing.HOST_ID)
            (candidate["Entitlements"] if entitlement else candidate)[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                signing.make_entitlements(candidate, template("Host"), TEAM, signing.HOST_ID, FINGERPRINT, NOW)
        changed = dict(template("Host"), **{"com.apple.security.cs.disable-library-validation": True})
        with self.assertRaises(ValueError):
            signing.make_entitlements(profile(signing.HOST_ID), changed, TEAM, signing.HOST_ID, FINGERPRINT, NOW)

    def test_fresh_build_layout_only(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Blackice.app"
            for relative, role, executable in [(Path("."), "Host", "BlackiceApp"),
                                                (signing.EXTENSION, "Filter", "BlackiceFilter")]:
                contents = app / relative / "Contents"
                (contents / "MacOS").mkdir(parents=True)
                (contents / "Info.plist").write_bytes((MACOS / "Resources" / (role + "-Info.plist")).read_bytes())
                binary = contents / "MacOS" / executable
                binary.write_bytes(b"synthetic, never executed")
                binary.chmod(0o755)
            signing.validate_bundle(app)
            extra = app / "Contents/embedded.provisionprofile"
            extra.write_bytes(b"old profile")
            with self.assertRaises(ValueError):
                signing.validate_bundle(app)
            extra.unlink()
            extra.symlink_to("Info.plist")
            with self.assertRaises(ValueError):
                signing.validate_bundle(app)

    def exercise_pipeline(self, status="Accepted", fail_at=None):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        output = Path(temporary.name)
        calls = []
        environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/synthetic/home"}

        def runner(arguments, *, environment, capture=False):
            call = [str(value) for value in arguments]
            calls.append(call)
            if len(calls) == fail_at:
                raise subprocess.CalledProcessError(1, call)
            return json.dumps({"status": status, "id": "synthetic"}).encode() if capture else None

        def execute():
            return signing.sign_and_notarize(output / "Blackice.app", output, FINGERPRINT, "synthetic-profile",
                                             [output / "Host.entitlements", output / "Filter.entitlements"],
                                             environment, runner=runner)
        return execute, calls

    def test_inside_out_signing_and_stapled_distribution_archive(self):
        execute, calls = self.exercise_pipeline()
        final = execute()
        self.assertTrue(calls[0][-1].endswith(str(signing.EXTENSION)))
        self.assertTrue(calls[1][-1].endswith("Blackice.app"))
        for call in calls[:2]:
            self.assertIn("runtime", call)
            self.assertIn("--timestamp", call)
            self.assertIn("--entitlements", call)
            self.assertNotIn("--deep", call)
        self.assertEqual(calls[4][1:3], ["notarytool", "submit"])
        self.assertIn("--wait", calls[4])
        self.assertIn("--keychain-profile", calls[4])
        self.assertEqual(calls[5][1:3], ["stapler", "staple"])
        self.assertIn("--strict", calls[6])
        self.assertEqual(calls[7][:3], ["/usr/sbin/spctl", "-a", "-vv"])
        self.assertEqual(calls[8][1:3], ["stapler", "validate"])
        self.assertEqual(calls[9][-1], str(final))
        self.assertEqual(final.name, "Blackice-notarized.zip")
        for call in calls:
            self.assertFalse(any(value in call for value in ["--password", "--key", "activate", "enable", "open"]))

    def test_rejected_notarization_never_staples_or_reports_release(self):
        execute, calls = self.exercise_pipeline(status="Invalid")
        with self.assertRaises(ValueError):
            execute()
        self.assertEqual(len(calls), 5)

    def test_command_failure_stops_pipeline(self):
        for position in range(1, 11):
            execute, calls = self.exercise_pipeline(fail_at=position)
            with self.subTest(position=position), self.assertRaises(subprocess.CalledProcessError):
                execute()
            self.assertEqual(len(calls), position)


if __name__ == "__main__":
    unittest.main(verbosity=2)
