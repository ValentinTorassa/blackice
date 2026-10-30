"""Offline tests. No keychain access, signing, notarization or app execution."""
from datetime import datetime, timezone
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest import mock

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


def bundle(directory, *, probe=False):
    app = Path(directory) / ("BlackiceProbe.app" if probe else "Blackice.app")
    targets = [(Path("."), "Probe", "BlackiceProbe")] if probe else [
        (Path("."), "Host", "BlackiceApp"), (signing.EXTENSION, "Filter", "BlackiceFilter")]
    for relative, role, executable in targets:
        contents = app / relative / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        info = contents / "Info.plist"
        info.write_bytes((MACOS / "Resources" / (role + "-Info.plist")).read_bytes())
        info.chmod(0o644)
        binary = contents / "MacOS" / executable
        binary.write_bytes(b"synthetic, never executed")
        binary.chmod(0o755)
    for path in [app, *app.rglob("*")]:
        if path.is_dir():
            path.chmod(0o755)
    return app


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
            app = bundle(directory)
            signing.validate_bundle(app)
            extra = app / "Contents/embedded.provisionprofile"
            extra.write_bytes(b"old profile")
            extra.chmod(0o644)
            with self.assertRaises(ValueError):
                signing.validate_bundle(app)
            extra.unlink()
            extra.symlink_to("Info.plist")
            with self.assertRaises(ValueError):
                signing.validate_bundle(app)

    def test_bundle_and_parent_reject_writable_modes_or_wrong_owner(self):
        with tempfile.TemporaryDirectory() as directory:
            app = bundle(directory)
            for path in [Path(directory), app, app / "Contents", app / "Contents/MacOS/BlackiceApp",
                         app / signing.EXTENSION / "Contents/Info.plist"]:
                original = path.stat().st_mode & 0o777
                try:
                    for extra_write in [0o020, 0o002]:
                        path.chmod(original | extra_write)
                        with self.subTest(path=path.name, bits=extra_write), self.assertRaises(ValueError):
                            signing.validate_bundle(app)
                finally:
                    path.chmod(original)
            with mock.patch.object(signing.paths.os, "geteuid", return_value=os.geteuid() + 1):
                with self.assertRaises(ValueError):
                    signing.validate_bundle(app)
            signing.validate_bundle(app)

    def test_hard_linked_executable_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            app = bundle(directory)
            os.link(app / "Contents/MacOS/BlackiceApp", Path(directory) / "extra-link")
            with self.assertRaises(ValueError):
                signing.validate_bundle(app)

    def test_private_build_directory_rejects_planted_shared_parent(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory)
            result = signing.paths.prepare_directory(parent / "build/tests")
            self.assertEqual(result.stat().st_mode & 0o777, 0o700)
            self.assertEqual(signing.paths.prepare_directory(result), result)
            shared = parent / "planted"
            shared.mkdir()
            shared.chmod(0o777)
            with self.assertRaises(ValueError):
                signing.paths.prepare_directory(shared / "new-build")
            self.assertFalse((shared / "new-build").exists())
            self.assertEqual(shared.stat().st_mode & 0o777, 0o777)
            alias = parent / "alias"
            alias.symlink_to(result)
            with self.assertRaises(ValueError):
                signing.paths.prepare_directory(alias)

    def test_unsigned_executable_hashes_cover_both_binaries(self):
        with tempfile.TemporaryDirectory() as directory:
            app = bundle(directory)
            hashes = signing.executable_hashes(app)
            self.assertEqual(len(hashes), 2)
            self.assertEqual(set(hashes.values()), {hashlib.sha256(b"synthetic, never executed").hexdigest()})

    def test_unsafe_input_or_output_stops_before_any_native_tool(self):
        with tempfile.TemporaryDirectory() as directory:
            app = bundle(directory)
            output_parent = Path(directory) / "release"
            output_parent.mkdir(mode=0o700)
            arguments = ["sign-notarize", "--team-id", TEAM, "--identity", IDENTITY,
                         "--host-profile", "unused-host-profile", "--extension-profile", "unused-filter-profile",
                         "--keychain-profile", "synthetic-profile", "--app", str(app),
                         "--output", str(output_parent / "new-output")]
            for path, original in [(app, 0o755), (output_parent, 0o700)]:
                path.chmod(0o777)
                try:
                    with mock.patch("sys.argv", arguments), mock.patch.object(signing.platform, "system", return_value="Darwin"), \
                         mock.patch.object(signing, "run") as native:
                        with self.assertRaises(ValueError):
                            signing.main()
                        native.assert_not_called()
                finally:
                    path.chmod(original)

    def test_probe_exact_layout_and_identity_without_profiles(self):
        with tempfile.TemporaryDirectory() as directory:
            app = bundle(directory, probe=True)
            signing.validate_bundle(app, probe=True)
            hashes = signing.executable_hashes(app, probe=True)
            self.assertEqual(hashes, {"Contents/MacOS/BlackiceProbe": hashlib.sha256(b"synthetic, never executed").hexdigest()})
            extra = app / "Contents/embedded.provisionprofile"
            extra.write_bytes(b"must not inherit host profile"); extra.chmod(0o644)
            with self.assertRaises(ValueError):
                signing.validate_bundle(app, probe=True)
            extra.unlink()
            info_path = app / "Contents/Info.plist"
            info = plistlib.loads(info_path.read_bytes())
            info["CFBundleIdentifier"] = signing.HOST_ID
            info_path.write_bytes(plistlib.dumps(info))
            with self.assertRaises(ValueError):
                signing.validate_bundle(app, probe=True)

    def test_unsafe_optional_probe_stops_before_native_tools(self):
        with tempfile.TemporaryDirectory() as directory:
            app = bundle(directory)
            probe = bundle(directory, probe=True)
            probe.chmod(0o777)
            arguments = ["sign-notarize", "--team-id", TEAM, "--identity", IDENTITY,
                         "--host-profile", "unused-host-profile", "--extension-profile", "unused-filter-profile",
                         "--keychain-profile", "synthetic-profile", "--app", str(app),
                         "--output", str(Path(directory) / "new-output"), "--probe-app", str(probe)]
            with mock.patch("sys.argv", arguments), mock.patch.object(signing.platform, "system", return_value="Darwin"), \
                 mock.patch.object(signing, "run") as native:
                with self.assertRaises(ValueError):
                    signing.main()
                native.assert_not_called()

    def test_two_app_preparation_keeps_probe_separate_and_prints_hash_before_signing(self):
        real_temporary = tempfile.TemporaryDirectory
        with real_temporary() as directory:
            root = Path(directory)
            app, probe = bundle(root), bundle(root, probe=True)
            for role in ["Host", "Filter"]:
                (root / (role + ".provisionprofile")).write_bytes(b"synthetic CMS; never passed to native tools")
            output = root / "output"
            arguments = ["sign-notarize", "--team-id", TEAM, "--identity", IDENTITY,
                         "--host-profile", str(root / "Host.provisionprofile"),
                         "--extension-profile", str(root / "Filter.provisionprofile"),
                         "--keychain-profile", "synthetic-profile", "--app", str(app),
                         "--output", str(output), "--probe-app", str(probe)]
            terminal = io.StringIO()
            def native(arguments, *, environment, capture=False):
                self.assertTrue(set(environment).issubset({"PATH", "HOME", "TMPDIR"}))
                if "find-identity" in arguments:
                    return ('  1) ' + FINGERPRINT + ' "' + IDENTITY + '"\n').encode()
                if "cms" in arguments:
                    role = Path(arguments[-1]).stem
                    return plistlib.dumps(profile(signing.HOST_ID if role == "Host" else signing.FILTER_ID))
                return b"/synthetic/tool"
            def pipeline(app, destination, fingerprint, keychain_profile, entitlements, environment, *, probe=False):
                self.assertEqual(fingerprint, FINGERPRINT)
                self.assertEqual(keychain_profile, "synthetic-profile")
                self.assertIn("Unsigned probe SHA-256:", terminal.getvalue())
                self.assertTrue((output / "unsigned-executable-sha256.json").is_file())
                self.assertTrue((output / "probe-unsigned-executable-sha256.json").is_file())
                if probe:
                    self.assertFalse((app / "Contents/embedded.provisionprofile").exists())
                    self.assertEqual(entitlements, [])
                else:
                    self.assertTrue((app / "Contents/embedded.provisionprofile").is_file())
                    self.assertTrue((app / signing.EXTENSION / "Contents/embedded.provisionprofile").is_file())
                return destination / (app.stem + "-notarized.zip")
            with mock.patch("sys.argv", arguments), mock.patch.object(signing.platform, "system", return_value="Darwin"), \
                 mock.patch.object(signing, "run", side_effect=native), \
                 mock.patch.object(signing.tempfile, "TemporaryDirectory", side_effect=lambda **kwargs: real_temporary(dir=root)), \
                 mock.patch.object(signing, "sign_and_notarize", side_effect=pipeline) as pipelines, \
                 contextlib.redirect_stdout(terminal):
                signing.main()
            self.assertEqual(pipelines.call_count, 2)
            self.assertIn("Blackice-notarized.zip", terminal.getvalue())
            self.assertIn("BlackiceProbe-notarized.zip", terminal.getvalue())

    def exercise_pipeline(self, status="Accepted", fail_at=None, probe=False):
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
            return signing.sign_and_notarize(output / ("BlackiceProbe.app" if probe else "Blackice.app"),
                                             output, FINGERPRINT, "synthetic-profile",
                                             [] if probe else [output / "Host.entitlements", output / "Filter.entitlements"],
                                             environment, runner=runner, probe=probe)
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

    def test_probe_notarizes_and_staples_its_own_archive_without_ne_entitlements(self):
        execute, calls = self.exercise_pipeline(probe=True)
        final = execute()
        self.assertEqual(final.name, "BlackiceProbe-notarized.zip")
        self.assertTrue(calls[0][-1].endswith("BlackiceProbe.app"))
        self.assertIn("runtime", calls[0]); self.assertIn("--timestamp", calls[0])
        self.assertNotIn("--entitlements", calls[0])
        self.assertIn("--strict", calls[1])
        self.assertEqual(calls[3][1:3], ["notarytool", "submit"])
        self.assertIn("--keychain-profile", calls[3]); self.assertIn("--wait", calls[3])
        self.assertTrue(calls[3][3].endswith("BlackiceProbe-submission.zip"))
        self.assertEqual(calls[4][1:3], ["stapler", "staple"])
        self.assertEqual(calls[6][:3], ["/usr/sbin/spctl", "-a", "-vv"])
        self.assertEqual(calls[7][1:3], ["stapler", "validate"])
        self.assertEqual(calls[8][-1], str(final))

    def test_probe_failures_never_complete_distribution(self):
        execute, calls = self.exercise_pipeline(probe=True, status="Invalid")
        with self.assertRaises(ValueError):
            execute()
        self.assertEqual(len(calls), 4)
        for position in range(1, 10):
            execute, calls = self.exercise_pipeline(probe=True, fail_at=position)
            with self.subTest(position=position), self.assertRaises(subprocess.CalledProcessError):
                execute()
            self.assertEqual(len(calls), position)


if __name__ == "__main__":
    unittest.main(verbosity=2)
