"""Developer ID release preparation; credentials stay in the owner's keychain.

The profile checks are a preflight, not a substitute for Apple's signature,
notarization or runtime entitlement validation. Never import profile entitlements
wholesale: only the two reviewed capability sets below are claimed.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import tempfile

HOST_ID = "com.valentorassa.blackice"
FILTER_ID = "com.valentorassa.blackice.filter"
EXTENSION = Path("Contents/Library/SystemExtensions") / (FILTER_ID + ".systemextension")
NE_KEY = "com.apple.developer.networking.networkextension"
NE_VALUE = "content-filter-provider-systemextension"
INSTALL_KEY = "com.apple.developer.system-extension.install"
TEAM_KEY = "com.apple.developer.team-identifier"
APP_KEY = "com.apple.application-identifier"
SOURCE = Path(__file__).resolve().parents[1]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def identity_fingerprint(listing, identity, team):
    require(re.fullmatch(r"[A-Z0-9]{10}", team), "TEAM_ID must be the enrolled ten-character Team ID")
    require(identity.startswith("Developer ID Application: ") and identity.endswith(" (" + team + ")"),
            "identity must be a Developer ID Application certificate for TEAM_ID")
    matches = [match.group(1).upper() for match in re.finditer(
        r'^\s*\d+\) ([0-9A-Fa-f]{40}) "([^"]+)"\s*$', listing, re.MULTILINE
    ) if match.group(2) == identity]
    require(len(matches) == 1, "exactly one valid matching signing identity must exist in the keychain")
    return matches[0]


def make_entitlements(profile, template, team, bundle_id, fingerprint, now=None):
    now = now or datetime.now(timezone.utc)
    require(isinstance(profile, dict), "invalid profile payload")
    require(profile.get("TeamIdentifier") == [team], "profile TeamIdentifier mismatch")
    require(profile.get("ProvisionsAllDevices") is True and "ProvisionedDevices" not in profile,
            "a Developer ID distribution profile is required")
    expires = profile.get("ExpirationDate")
    require(isinstance(expires, datetime), "profile has no expiration date")
    if expires.tzinfo is None:
        expires = expires.replace(tzinfo=timezone.utc)
    require(expires > now, "profile has expired")
    certificates = profile.get("DeveloperCertificates", [])
    require(isinstance(certificates, list) and all(isinstance(cert, bytes) for cert in certificates),
            "invalid profile certificates")
    # codesign's identity selector uses a certificate SHA-1 fingerprint. Apple
    # validates the certificate/signature; this is not a release integrity hash.
    require(fingerprint in [hashlib.sha1(cert).hexdigest().upper() for cert in certificates],
            "selected certificate is not authorized by the profile")
    allowed = profile.get("Entitlements", {})
    require(isinstance(allowed, dict), "invalid profile entitlements")
    require(allowed.get(TEAM_KEY) == team, "profile entitlement Team ID mismatch")
    prefixes = profile.get("ApplicationIdentifierPrefix", [])
    require(isinstance(prefixes, list) and len(prefixes) == 1 and
            isinstance(prefixes[0], str) and re.fullmatch(r"[A-Z0-9]{10}", prefixes[0]),
            "profile must have one explicit App ID prefix")
    app_id = prefixes[0] + "." + bundle_id
    require(allowed.get(APP_KEY) == app_id, "profile must authorize the exact bundle ID, not a wildcard")
    require(isinstance(allowed.get(NE_KEY), list) and NE_VALUE in allowed[NE_KEY],
            "profile lacks content-filter-provider-systemextension")
    require(not allowed.get("get-task-allow", False) and
            not allowed.get("com.apple.security.get-task-allow", False), "debug profile is not allowed")
    expected = {NE_KEY: [NE_VALUE]}
    if bundle_id == HOST_ID:
        expected[INSTALL_KEY] = True
        # System-extension activation is claimed by the host. A profile may not
        # enumerate unrestricted macOS entitlements; never accept a denial.
        require(allowed.get(INSTALL_KEY, True) is True, "profile denies system-extension installation")
    require(template == expected, "entitlement template changed: security review required")
    return dict(expected, **{APP_KEY: app_id, TEAM_KEY: team})


def validate_bundle(app):
    files = {
        Path("Contents/Info.plist"), Path("Contents/MacOS/BlackiceApp"),
        EXTENSION / "Contents/Info.plist", EXTENSION / "Contents/MacOS/BlackiceFilter",
    }
    directories = {parent for item in files for parent in item.parents if parent != Path(".")}
    require(app.is_dir() and not app.is_symlink() and app.name == "Blackice.app", "expected unsigned Blackice.app")
    actual = set()
    for path in app.rglob("*"):
        relative = path.relative_to(app)
        require(not path.is_symlink(), "bundle symlinks are not supported by this signing recipe")
        if path.is_dir():
            require(relative in directories, "unexpected bundle directory: " + str(relative))
        else:
            require(path.is_file() and relative in files, "unexpected bundle file: " + str(relative))
            actual.add(relative)
    require(actual == files, "bundle is incomplete; run macos/build.sh into a fresh directory")
    metadata = []
    for relative, bundle_id, executable, kind in [
        (Path("."), HOST_ID, "BlackiceApp", "APPL"),
        (EXTENSION, FILTER_ID, "BlackiceFilter", "SYSX"),
    ]:
        info = plistlib.loads((app / relative / "Contents/Info.plist").read_bytes())
        require(info.get("CFBundleIdentifier") == bundle_id and info.get("CFBundleExecutable") == executable
                and info.get("CFBundlePackageType") == kind, "bundle metadata mismatch")
        require(os.access(app / relative / "Contents/MacOS" / executable, os.X_OK), "bundle executable is not executable")
        metadata.append((info.get("CFBundleVersion"), info.get("CFBundleShortVersionString")))
    require(metadata[0] == metadata[1] and all(isinstance(v, str) and v for v in metadata[0]),
            "host and extension versions must match")


def run(arguments, *, environment, capture=False):
    # No shell, password argument, API key argument or credential environment.
    return subprocess.run([str(arg) for arg in arguments], env=environment, check=True,
                          stdout=subprocess.PIPE if capture else None,
                          text=False).stdout


def sign_and_notarize(app, output, fingerprint, keychain_profile, entitlements, environment, runner=run):
    extension = app / EXTENSION
    for target, entitlement_path in [(extension, entitlements[1]), (app, entitlements[0])]:
        runner(["/usr/bin/codesign", "--force", "--sign", fingerprint, "--options", "runtime",
                "--timestamp", "--generate-entitlement-der", "--entitlements", entitlement_path, target],
               environment=environment)
    runner(["/usr/bin/codesign", "--verify", "--strict", "--deep", "--verbose=2", app], environment=environment)
    submission = output / "Blackice-submission.zip"
    runner(["/usr/bin/ditto", "-c", "-k", "--keepParent", app, submission], environment=environment)
    result = runner(["/usr/bin/xcrun", "notarytool", "submit", submission, "--wait",
                     "--keychain-profile", keychain_profile, "--output-format", "json"],
                    environment=environment, capture=True)
    (output / "notary-result.json").write_bytes(result)
    response = json.loads(result)
    require(isinstance(response, dict) and response.get("status") == "Accepted",
            "notarization not accepted; see notary-result.json")
    runner(["/usr/bin/xcrun", "stapler", "staple", app], environment=environment)
    runner(["/usr/bin/codesign", "--verify", "--strict", "--deep", "--verbose=2", app], environment=environment)
    runner(["/usr/sbin/spctl", "-a", "-vv", "--type", "execute", app], environment=environment)
    runner(["/usr/bin/xcrun", "stapler", "validate", app], environment=environment)
    # Distribute the archive made AFTER stapling, not the submission archive.
    final_archive = output / "Blackice-notarized.zip"
    runner(["/usr/bin/ditto", "-c", "-k", "--keepParent", app, final_archive], environment=environment)
    return final_archive


def main():
    parser = argparse.ArgumentParser(description="Manual signing/notarization after team enrollment and security review. Never installs or activates.")
    for name in ["team-id", "identity", "host-profile", "extension-profile", "keychain-profile", "app", "output"]:
        parser.add_argument("--" + name, required=True)
    args = parser.parse_args()
    require(re.fullmatch(r"[A-Z0-9]{10}", args.team_id), "TEAM_ID must be the enrolled ten-character Team ID")
    require(args.identity.startswith("Developer ID Application: ") and args.identity.endswith(" (" + args.team_id + ")"),
            "provide the exact Developer ID Application identity for TEAM_ID")
    require(re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", args.keychain_profile), "invalid keychain profile name")
    require(platform.system() == "Darwin", "signing requires macOS; no signing operation was attempted")
    requested_app = Path(args.app).absolute()
    require(not requested_app.is_symlink(), "input app cannot be a symlink")
    app = requested_app.resolve(strict=True)
    validate_bundle(app)
    requested_output = Path(args.output).absolute()
    require(not requested_output.is_symlink(), "output cannot be a symlink")
    output = requested_output.resolve()
    repository = SOURCE.parent
    require(output != repository and repository not in output.parents, "output must be outside the source repository")
    require(not output.exists() and output.parent.is_dir(), "output must be new, with an existing parent directory")
    require(output != app and app not in output.parents, "output cannot be inside the input app")
    # Tools only see the OS user environment needed for the keychain and temp
    # files. Inherited Apple passwords, API keys and unrelated tokens are absent.
    environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(Path.home())}
    for tool in ["notarytool", "stapler"]:
        run(["/usr/bin/xcrun", "--find", tool], environment=environment, capture=True)
    listing = run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"],
                  environment=environment, capture=True).decode("utf-8")
    fingerprint = identity_fingerprint(listing, args.identity, args.team_id)
    with tempfile.TemporaryDirectory(prefix="blackice-sign-preflight-", dir="/private/tmp") as scratch_name:
        scratch = Path(scratch_name)
        environment["TMPDIR"] = str(scratch)
        profiles, entitlements = [], []
        for role, supplied, bundle_id in [("Host", args.host_profile, HOST_ID),
                                         ("Filter", args.extension_profile, FILTER_ID)]:
            source = Path(supplied)
            require(source.is_file() and not source.is_symlink() and source.stat().st_size <= 4 * 1024 * 1024,
                    "profile must be a regular file of at most 4 MiB")
            snapshot = scratch / (role + ".provisionprofile")
            with source.open("rb") as stream:
                data = stream.read(4 * 1024 * 1024 + 1)
            require(len(data) <= 4 * 1024 * 1024, "profile exceeds 4 MiB")
            snapshot.write_bytes(data)
            decoded = run(["/usr/bin/security", "cms", "-D", "-i", snapshot], environment=environment, capture=True)
            profile = plistlib.loads(decoded)
            template = plistlib.loads((SOURCE / "Resources" / (role + ".entitlements")).read_bytes())
            entitlements.append(make_entitlements(profile, template, args.team_id, bundle_id, fingerprint))
            profiles.append(snapshot)
        output.mkdir(mode=0o700)
        signed_app = output / "Blackice.app"
        shutil.copytree(app, signed_app)
        validate_bundle(signed_app)
        entitlement_paths = []
        for role, target, profile, values in zip(["Host", "Filter"], [signed_app, signed_app / EXTENSION], profiles, entitlements):
            shutil.copyfile(profile, target / "Contents/embedded.provisionprofile")
            path = output / (role + ".entitlements")
            path.write_bytes(plistlib.dumps(values, sort_keys=True))
            entitlement_paths.append(path)
        final_archive = sign_and_notarize(signed_app, output, fingerprint, args.keychain_profile,
                                         entitlement_paths, environment)
        print("Verified notarized archive: " + str(final_archive))
        print("No app or extension was installed, activated or loaded.")


if __name__ == "__main__":
    os.umask(0o077)
    try:
        main()
    except (ValueError, OSError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        raise SystemExit("sign-notarize: " + str(error))
