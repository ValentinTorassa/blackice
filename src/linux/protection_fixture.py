"""Adversarial filesystem operations, executed only by a disposable rootless Zig test child."""
import ctypes
import errno
import os
from pathlib import Path
import socket
import subprocess
import sys

base = Path(sys.argv[1])
binary = base / 'parent/bin/blackice'
policy = base / 'parent/policy/policy.json'
link = base / 'parent/bin/blackice-link'
dir_link = base / 'parent/bin-link'
state = base / 'state-parent/state'
refusals = 0


def refused(operation, expected):
    global refusals
    try:
        operation()
    except OSError as error:
        assert error.errno in expected, repr(error)
        refusals += 1
        return
    raise AssertionError('protected operation unexpectedly succeeded')


ro = (errno.EROFS,)
busy = (errno.EBUSY, errno.EROFS, errno.EXDEV)
for path in (binary, policy, link, dir_link / 'blackice', Path('/proc/self/root' + str(policy))):
    refused(lambda: path.write_text('tampered'), ro)
    refused(lambda: os.truncate(path, 0), ro)
    refused(lambda: os.chmod(path, 0o777), ro)
    refused(lambda: os.utime(path, None), ro)

for path in (binary, policy, link, dir_link):
    refused(lambda: path.unlink(), busy)
    refused(lambda: path.rename(path.with_name(path.name + '.moved')), busy)
    candidate = path.with_name('replacement')
    candidate.write_text('replacement')
    refused(lambda: os.replace(candidate, path), busy)
    candidate.unlink()
    candidate.symlink_to('untrusted')
    refused(lambda: os.replace(candidate, path), busy)
    candidate.unlink()

for path in (link, dir_link):
    refused(lambda: os.chown(path, os.getuid(), os.getgid(), follow_symlinks=False), ro)
    refused(lambda: os.utime(path, None, follow_symlinks=False), ro)

for path in (base, base / 'parent', binary.parent, policy.parent, base / 'state-parent', state):
    refused(lambda: path.rename(path.with_name(path.name + '.moved')), busy)
    refused(lambda: path.rmdir(), busy)

receipt = state / 'scopes/one/receipts'
refused(lambda: receipt.write_text('forged'), ro)
refused(lambda: os.chmod(receipt, 0o777), ro)
refused(lambda: os.link(policy, binary.parent / 'alias'), busy)
refused(lambda: Path(f'/proc/{os.getppid()}/root{policy}').write_text('outside-alias'), (errno.EPERM, errno.EACCES))
refused(lambda: socket.socket(socket.AF_UNIX, socket.SOCK_STREAM), (errno.EPERM,))

candidate = binary.parent / 'exchange'
candidate.write_text('exchange')
libc = ctypes.CDLL(None, use_errno=True)
libc.renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]


def exchange():
    if libc.renameat2(-100, os.fsencode(candidate), -100, os.fsencode(binary), 2) < 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


refused(exchange, busy)
candidate.unlink()

# Ordinary neighboring files still support create, write, rename, chmod and removal.
for parent in (binary.parent, policy.parent, base / 'state-parent'):
    neighbor = parent / 'neighbor'
    neighbor.write_text('neighbor')
    neighbor.chmod(0o600)
    neighbor.rename(parent / 'neighbor-renamed')
    (parent / 'neighbor-renamed').unlink()

assert binary.read_text() == '#!/bin/sh\nexit 0\n'
assert policy.read_text() == 'original-policy\n'
assert os.readlink(link) == 'blackice'
assert os.readlink(dir_link) == 'bin'
assert Path.cwd() == binary.parent
assert subprocess.run([str(binary)]).returncode == 0
if sys.argv[2] == 'temporary':
    assert not (base / 'parent/unrelated').exists()
assert refusals >= 50, refusals
