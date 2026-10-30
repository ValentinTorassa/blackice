#!/usr/bin/env python3
"""Read-only VM4 identity preflight. This draft cannot install, arm or run B tests."""
import argparse
import json
import os
from pathlib import Path
import re
import stat
import subprocess

VM_NAME = "blackice-vm4"
VM_DIRECTORY = "/var/tmp/blackice-vm4"
FIELDS = {"directory", "hostname", "machine_id", "boot_id", "ssh_port", "ssh_user", "known_hosts", "host_key_sha256"}


def regular(path, limit=16384):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit or info.st_mode & 0o022:
            raise ValueError("Expected a bounded regular file without group/other write access")
        data = os.read(fd, limit + 1)
        if len(data) != info.st_size:
            raise ValueError("Identity file changed during read")
        return data
    finally:
        os.close(fd)


def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate identity field")
        result[key] = value
    return result


def validate_manifest(data, host_machine_id):
    if not isinstance(data, dict) or set(data) != FIELDS:
        raise ValueError("Supply every VM4 identity field; unknown fields are refused")
    if data["directory"] != VM_DIRECTORY or data["hostname"] != VM_NAME:
        raise ValueError("Only the designated VM4 is accepted")
    if not isinstance(data["machine_id"], str) or not re.fullmatch(r"[0-9a-f]{32}", data["machine_id"]):
        raise ValueError("Invalid guest machine ID")
    if data["machine_id"] == host_machine_id or data["machine_id"] == "0" * 32:
        raise ValueError("Host or empty machine identity refused")
    if not isinstance(data["boot_id"], str) or not re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", data["boot_id"]):
        raise ValueError("Invalid boot ID")
    if type(data["ssh_port"]) is not int or not 1024 <= data["ssh_port"] <= 65535:
        raise ValueError("Expected the declared local VM port")
    if not isinstance(data["ssh_user"], str) or not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", data["ssh_user"]) or data["ssh_user"] == "root":
        raise ValueError("Preflight requires an unprivileged guest account")
    if not isinstance(data["known_hosts"], str) or not Path(data["known_hosts"]).is_absolute():
        raise ValueError("An explicit absolute known_hosts path is required")
    if not isinstance(data["host_key_sha256"], str) or not re.fullmatch(r"SHA256:[A-Za-z0-9+/]{43}", data["host_key_sha256"]):
        raise ValueError("Pin the guest SSH host-key fingerprint")
    return data


GUEST_QUERY = """import json, os, socket, subprocess
from pathlib import Path
print(json.dumps({'hostname':socket.gethostname(), 'machine_id':Path('/etc/machine-id').read_text().strip(),
'boot_id':Path('/proc/sys/kernel/random/boot_id').read_text().strip(), 'uid':os.getuid(),
'virtualization':subprocess.check_output(['/usr/bin/systemd-detect-virt','--vm'],text=True).strip()}))
"""


def check_observation(manifest, observed):
    if not isinstance(observed, dict) or set(observed) != {"hostname", "machine_id", "boot_id", "uid", "virtualization"}:
        raise ValueError("Unexpected guest observation")
    for key in ("hostname", "machine_id", "boot_id"):
        if observed[key] != manifest[key]:
            raise ValueError(f"Guest {key} differs from the declared VM4 identity")
    if observed["virtualization"] != "kvm" or type(observed["uid"]) is not int or observed["uid"] <= 0:
        raise ValueError("Require KVM and an unprivileged guest session")
    return observed


def preflight(manifest, host_machine_id, run=subprocess.run):
    validate_manifest(manifest, host_machine_id)
    known = regular(manifest["known_hosts"])
    lines = [line for line in known.decode("ascii").splitlines() if line and not line.startswith("#")]
    if len(lines) != 1 or lines[0].split()[0] != VM_NAME:
        raise ValueError("known_hosts must contain exactly the explicit VM4 alias")
    result = run(["/usr/bin/ssh-keygen", "-lf", manifest["known_hosts"], "-E", "sha256"],
                 capture_output=True, text=True, check=True, timeout=5)
    if result.stdout.split()[1:2] != [manifest["host_key_sha256"]]:
        raise ValueError("Host-key fingerprint differs")
    args = ["/usr/bin/ssh", "-T", "-F", "/dev/null", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
            "-o", "StrictHostKeyChecking=yes", "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "UserKnownHostsFile=" + manifest["known_hosts"], "-o", "HostKeyAlias=" + VM_NAME,
            "-o", "ClearAllForwardings=yes", "-o", "RequestTTY=no", "-p", str(manifest["ssh_port"]),
            manifest["ssh_user"] + "@127.0.0.1", "/usr/bin/python3 -I -"]
    result = run(args, input=GUEST_QUERY, capture_output=True, text=True, check=True, timeout=15)
    return check_observation(manifest, json.loads(result.stdout, object_pairs_hook=unique_pairs))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    args = parser.parse_args()
    if os.geteuid() == 0:
        raise ValueError("Run the identity preflight as the normal host user")
    manifest = json.loads(regular(args.manifest), object_pairs_hook=unique_pairs)
    observed = preflight(manifest, Path("/etc/machine-id").read_text().strip())
    print(json.dumps({"identity": "verified", "guest": observed, "enforcement_tests": "NOT RUN",
                      "runtime": "disabled; privileged recovery and accounting integration still required"}, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(f"VM4 preflight refused: {error}") from None
