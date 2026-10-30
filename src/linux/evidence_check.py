#!/usr/bin/env python3
"""Prepare real P0-01/P0-02 observations; never install a helper or write evidence entries.

Requires the expected installed-helper hash before invoking blackice. --controls-only tests the
off-host route without executing a scope. Remote receiver output travels over SSH; no remote log
path can be pre-created. Positive controls bracket every scoped sender, separately for each case.
"""
import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid

HELPER = Path('/usr/local/libexec/blackice-linux-helper')
PORTS = {'tcp4': 47121, 'tcp6': 47122, 'udp4': 47123, 'udp6': 47124}
CASES = ('tcp4', 'tcp6', 'udp4-send', 'udp6-send', 'udp4-connect', 'udp6-connect')

RECEIVER = r'''
import json, os, select, socket, sys, time
v4, v6, seconds = sys.argv[1], sys.argv[2], float(sys.argv[3])
ports = {'tcp4': 47121, 'tcp6': 47122, 'udp4': 47123, 'udp6': 47124}
def emit(**row):
    print(json.dumps(dict(t=time.time(), **row)), flush=True)
socks = {}
try:
    for name, port in ports.items():
        family = socket.AF_INET6 if name.endswith('6') else socket.AF_INET
        kind = socket.SOCK_STREAM if name.startswith('tcp') else socket.SOCK_DGRAM
        sock = socket.socket(family, kind)
        if family == socket.AF_INET6:
            sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        sock.bind((v6 if family == socket.AF_INET6 else v4, port))
        if kind == socket.SOCK_STREAM:
            sock.listen(16)
        socks[sock] = name
    emit(event='listening', pid=os.getpid(), v4=v4, v6=v6, ports=ports)
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        ready, _, _ = select.select([0, *socks], [], [], 0.25)
        if 0 in ready:
            os.read(0, 1024)
            break
        for sock in ready:
            if socks[sock].startswith('tcp'):
                conn, addr = sock.accept()
                with conn:
                    conn.settimeout(1)
                    try:
                        data = conn.recv(256)
                    except socket.timeout:
                        data = b''
            else:
                data, addr = sock.recvfrom(256)
            emit(proto=socks[sock], source=addr[0], data=data.decode(errors='replace'))
    emit(event='stopped')
finally:
    for sock in socks:
        sock.close()
'''

WORKER = r'''
import errno, hashlib, json, os, socket, sys
from pathlib import Path
mode = sys.argv[1]
if mode == 'policy':
    state = Path(os.environ['XDG_STATE_HOME']) / 'blackice/scopes' / os.environ['BLACKICE_SCOPE']
    rows = [json.loads(line) for line in (state / 'receipts.jsonl').read_text().splitlines()]
    assert rows and rows[0]['event'] == 'scope_start', rows
    policy = (state / 'policy.json').read_bytes()
    assert hashlib.sha256(policy).hexdigest() == sys.argv[3]
    assert json.loads(policy)['network']['mode'] == 'deny-all'
    try:
        with (state / 'receipts.jsonl').open('a') as f:
            f.write('forged\n')
    except OSError as exc:
        assert exc.errno in (errno.EROFS, errno.EPERM, errno.EACCES), exc
    else:
        raise AssertionError('scope could modify its receipt log')
    Path(sys.argv[2]).write_text('command executed after observing its policy and scope_start\n')
    print(json.dumps({'event': 'policy_observed', 'policy_sha256': sys.argv[3], 'scope': os.environ['BLACKICE_SCOPE']}), flush=True)
else:
    v4, v6, label = sys.argv[2:5]
    def send():
        for case in ('tcp4', 'tcp6', 'udp4-send', 'udp6-send', 'udp4-connect', 'udp6-connect'):
            proto = case[:4]
            family = socket.AF_INET6 if proto.endswith('6') else socket.AF_INET
            kind = socket.SOCK_STREAM if proto.startswith('tcp') else socket.SOCK_DGRAM
            port = {'tcp4': 47121, 'tcp6': 47122, 'udp4': 47123, 'udp6': 47124}[proto]
            addr = (v6 if family == socket.AF_INET6 else v4, port)
            with socket.socket(family, kind) as sock:
                sock.settimeout(2)
                try:
                    if case.endswith('-send'):
                        sock.sendto((label + '-' + case).encode(), addr)
                    else:
                        sock.connect(addr)
                        sock.sendall((label + '-' + case).encode())
                except OSError as exc:
                    assert exc.errno in (errno.EPERM, errno.EACCES), (case, exc)
                    print(json.dumps({'case': case, 'errno': exc.errno, 'pid': os.getpid(), 'cgroup': Path('/proc/self/cgroup').read_text().strip()}), flush=True)
                else:
                    raise AssertionError('scoped send succeeded: ' + case)
    if mode == 'descendant':
        readfd, writefd = os.pipe()
        child = os.fork()
        if child == 0:
            os.close(readfd)
            os.setsid()
            if os.fork() != 0:
                os._exit(0)
            try:
                time_module = __import__('time')
                time_module.sleep(0.1)
                send()
                os.write(writefd, b'K')
            except BaseException as exc:
                print(repr(exc), file=sys.stderr, flush=True)
            os._exit(0)
        os.close(writefd)
        assert os.read(readfd, 1) == b'K', 'grandchild did not complete its checks'
        os.close(readfd)
        os.waitpid(child, 0)
    else:
        send()
'''


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save(path, value):
    Path(path).write_text(json.dumps(value, indent=2) + '\n')


class Receiver:
    def __init__(self, ssh, v4, v6, directory):
        self.rows = []
        self.condition = threading.Condition()
        self.error = None
        self.log = (directory / 'receiver.jsonl').open('x')
        self.stderr = (directory / 'receiver.stderr').open('x')
        command = shlex.join(['/usr/bin/python3', '-I', '-c', RECEIVER, v4, v6, '150'])
        self.process = subprocess.Popen([*shlex.split(ssh), command], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=self.stderr, text=True)
        self.thread = threading.Thread(target=self.read, daemon=True)
        self.thread.start()

    def read(self):
        try:
            for line in self.process.stdout:
                self.log.write(line)
                self.log.flush()
                row = json.loads(line)
                with self.condition:
                    self.rows.append(row)
                    self.condition.notify_all()
        except Exception as exc:
            with self.condition:
                self.error = repr(exc)
                self.condition.notify_all()

    def wait_for(self, predicate, seconds=8):
        deadline = time.monotonic() + seconds
        with self.condition:
            while not predicate(self.rows):
                if self.error or self.process.poll() is not None:
                    raise RuntimeError('receiver stopped: ' + str(self.error))
                left = deadline - time.monotonic()
                if left <= 0:
                    return False
                self.condition.wait(min(left, 0.2))
            return True

    def stop(self):
        if self.process.poll() is None:
            try:
                self.process.stdin.write('stop\n')
                self.process.stdin.flush()
            except BrokenPipeError:
                pass
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=5)
        self.thread.join(timeout=2)
        self.log.close()
        self.stderr.close()


def control(receiver, v4, v6, label):
    outcomes = []
    expected = {label + '-' + case for case in CASES}
    for case in CASES:
        proto = case[:4]
        family = socket.AF_INET6 if proto.endswith('6') else socket.AF_INET
        kind = socket.SOCK_STREAM if proto.startswith('tcp') else socket.SOCK_DGRAM
        address = (v6 if family == socket.AF_INET6 else v4, PORTS[proto])
        with socket.socket(family, kind) as sock:
            sock.settimeout(2)
            try:
                if case.endswith('-send'):
                    sock.sendto((label + '-' + case).encode(), address)
                else:
                    sock.connect(address)
                    sock.sendall((label + '-' + case).encode())
                outcomes.append({'case': case, 'sent': True})
            except OSError as exc:
                outcomes.append({'case': case, 'sent': False, 'errno': exc.errno, 'error': str(exc)})
    complete = receiver.wait_for(lambda rows: expected <= {r.get('data') for r in rows})
    seen = {r.get('data') for r in receiver.rows}
    for row in outcomes:
        row['receiver_observed'] = label + '-' + row['case'] in seen
    return {'label': label, 'all_observed': complete, 'cases': outcomes}


def scope(args, work, name, command, policy, extra=()):
    state = work / 'state'
    before = set(state.glob('blackice/scopes/*'))
    argv = [str(args.blackice), 'run', '--policy', str(policy), *extra, '--', *command]
    run = subprocess.run(argv, cwd=work, env=dict(os.environ, XDG_STATE_HOME=str(state)),
                         stdin=subprocess.DEVNULL, capture_output=True, timeout=25)
    (work / (name + '.stdout')).write_bytes(run.stdout)
    (work / (name + '.stderr')).write_bytes(run.stderr)
    new_scopes = set(state.glob('blackice/scopes/*')) - before
    logs = sorted(p / 'receipts.jsonl' for p in new_scopes if (p / 'receipts.jsonl').exists())
    rows = [json.loads(line) for path in logs for line in path.read_text().splitlines()]
    result = {'argv': argv, 'exit': run.returncode, 'receipts': [str(p) for p in logs],
              'scope_directories': sorted(str(p) for p in new_scopes)}
    save(work / (name + '.result.json'), result)
    return run, rows, result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--blackice', type=Path)
    parser.add_argument('--blackice-sha256')
    parser.add_argument('--commit')
    parser.add_argument('--helper-sha256')
    parser.add_argument('--legacy-protected-paths', action='store_true')
    parser.add_argument('--controls-only', action='store_true')
    parser.add_argument('--ssh-command', required=True, help='Trusted SSH command, parsed with shlex; no eval')
    parser.add_argument('--v4', required=True)
    parser.add_argument('--v6', required=True)
    args = parser.parse_args()
    args.v4 = str(ipaddress.IPv4Address(args.v4))
    args.v6 = str(ipaddress.IPv6Address(args.v6))
    if not args.controls_only:
        if not args.blackice or not args.blackice_sha256 or not args.commit or not args.helper_sha256:
            parser.error('scope checks require --blackice, --blackice-sha256, --commit and --helper-sha256')
        args.blackice = args.blackice.resolve(strict=True)
        if digest(args.blackice) != args.blackice_sha256:
            print('NOT RUN: blackice does not match the requested build hash; no command executed.', file=sys.stderr)
            return 2
        if not HELPER.exists() or digest(HELPER) != args.helper_sha256:
            print('NOT RUN: installed helper does not match the requested reviewed hash; no command executed.', file=sys.stderr)
            return 2
    work = Path(tempfile.mkdtemp(prefix='bi-ev-'))
    print('Artifacts: ' + str(work), flush=True)
    (work / 'worker.py').write_text(WORKER)
    (work / 'receiver.py').write_text(RECEIVER)
    policy = work / 'deny.json'
    policy.write_text('{"version":"blackice.policy/v0","network":{"mode":"deny-all"}}\n')
    zig = os.environ.get('ZIG') or shutil.which('zig') or str(Path.home() / '.local/bin/zig')
    try:
        zig_run = subprocess.run([zig, 'version'], capture_output=True, text=True, timeout=5)
        zig_version = zig_run.stdout.strip() if zig_run.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        zig_version = None
    host_platform = platform.uname()
    summary = {'date_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
               'platform': {'system': host_platform.system, 'release': host_platform.release,
                            'version': host_platform.version, 'machine': host_platform.machine},
               'commit': args.commit, 'blackice_sha256': digest(args.blackice) if args.blackice else None,
               'helper_sha256': digest(HELPER) if HELPER.exists() else None,
               'zig_version': zig_version, 'harness_sha256': digest(__file__),
               'protected_paths_expected': None if args.controls_only else not args.legacy_protected_paths,
               'limits': ['Protected paths are not enforced in this legacy Linux build.'] if args.legacy_protected_paths else [],
               'controls_only': args.controls_only, 'v4': args.v4, 'v6': args.v6,
               'controls': [], 'scopes': [], 'status': 'NOT RUN'}
    receiver = None
    try:
        if not args.controls_only:
            invalid = work / 'invalid.json'
            invalid.write_text('{"version":"unsupported"}')
            marker = work / 'must-not-exist'
            run, rows, result = scope(args, work, 'invalid-policy', ['/usr/bin/touch', str(marker)], invalid)
            assert run.returncode == 125 and not marker.exists() and not result['scope_directories'], result
            if not args.legacy_protected_paths:
                run, rows, result = scope(args, work, 'policy-hash-mismatch', ['/usr/bin/touch', str(marker)], policy,
                                          ['--policy-sha256', '0' * 64])
                assert run.returncode == 125 and not marker.exists() and not result['scope_directories'], result
            marker = work / 'policy-command-ran'
            run, rows, result = scope(args, work, 'policy-before-exec',
                                      ['/usr/bin/python3', '-I', str(work / 'worker.py'), 'policy', str(marker), digest(policy)], policy)
            assert run.returncode == 0 and marker.exists(), result
            assert rows[0]['event'] == 'scope_start' and rows[-1]['event'] == 'scope_end', rows
            assert any(r['event'] == 'backend_armed' and r.get('point') == 'kernel' for r in rows), rows
            if not args.legacy_protected_paths:
                assert any(r['event'] == 'backend_armed' and 'protected_paths' in r.get('detail', '') for r in rows), rows
            summary['policy_before_exec'] = result
        receiver = Receiver(args.ssh_command, args.v4, args.v6, work)
        assert receiver.wait_for(lambda rows: any(r.get('event') == 'listening' for r in rows), 10), 'receiver did not start'
        nonce = uuid.uuid4().hex
        for mode in ('immediate',) if args.controls_only else ('immediate', 'descendant'):
            before = control(receiver, args.v4, args.v6, nonce + '-before-' + mode)
            summary['controls'].append(before)
            if not before['all_observed'] and not args.controls_only:
                raise RuntimeError('positive control missing; no off-host deny claim can be made for that route')
            if not args.controls_only:
                label = nonce + '-scoped-' + mode
                run, rows, result = scope(args, work, mode,
                                          ['/usr/bin/python3', '-I', str(work / 'worker.py'), mode, args.v4, args.v6, label], policy)
                summary['scopes'].append(result)
                assert run.returncode == 0, result
                assert rows[-1]['event'] == 'scope_end', rows
                observed = [json.loads(line) for line in run.stdout.decode().splitlines()]
                assert {r['case'] for r in observed} == set(CASES), observed
                assert all(r['cgroup'].startswith('0::/blackice/s-') for r in observed), observed
                for proto, port in PORTS.items():
                    address = ipaddress.ip_address(args.v6 if proto.endswith('6') else args.v4)
                    drops = [r for r in rows if r.get('event') == 'kernel_drop' and r.get('point') == 'kernel'
                             and r.get('verdict') == 'deny' and r.get('port') == port
                             and ipaddress.ip_address(r['ip']) == address
                             and ('protocol=' + ('6' if proto.startswith('tcp') else '17')) in r.get('detail', '')]
                    assert len(drops) >= (1 if proto.startswith('tcp') else 2), (proto, drops)
                time.sleep(1)  # Keep observing after scope completion before the trailing route controls.
            after = control(receiver, args.v4, args.v6, nonce + '-after-' + mode)
            summary['controls'].append(after)
            assert args.controls_only or after['all_observed'], 'trailing positive control missing'
            assert not any(nonce + '-scoped-' in r.get('data', '') for r in receiver.rows), 'receiver observed scoped traffic'
        summary['status'] = 'CONTROLS PASS' if args.controls_only else 'CHECKS PASS'
        if not all(c['all_observed'] for c in summary['controls']):
            summary['status'] = 'INCOMPLETE CONTROLS'
    except Exception as exc:
        summary['status'] = 'FAILED'
        summary['error'] = repr(exc)
    finally:
        if receiver is not None:
            try:
                receiver.stop()
            except Exception as exc:
                summary['receiver_stop_error'] = repr(exc)
                summary['status'] = 'FAILED'
            summary['receiver_exit'] = receiver.process.returncode
            summary['receiver_stopped'] = any(r.get('event') == 'stopped' for r in receiver.rows)
            if receiver.process.returncode != 0 or not summary['receiver_stopped']:
                summary['status'] = 'FAILED'
        save(work / 'summary.json', summary)
        print(json.dumps(summary, indent=2))
    return 0 if summary['status'] in ('CHECKS PASS', 'CONTROLS PASS') else 2


if __name__ == '__main__':
    sys.exit(main())
