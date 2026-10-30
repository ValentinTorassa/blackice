#!/usr/bin/env python3
"""Real local-receiver tests. Requires owner-installed helper; never installs it or invokes sudo.

No P0 evidence is generated. --crash-tests deliberately retains one filtered cgroup for owner teardown.
"""
import argparse
import errno
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import socket
import subprocess
import sys
import threading
import time

REPO = Path(__file__).resolve().parents[2]
HELPER = Path('/usr/local/libexec/blackice-linux-helper')
PROBE = REPO / 'zig-out/bin/blackice-linux-probe'
PERMISSION = (errno.EPERM, errno.EACCES)


def denied(operation):
    try:
        operation()
    except OSError as exc:
        assert exc.errno in PERMISSION, repr(exc)
        return exc.errno
    raise AssertionError('operation unexpectedly succeeded')


def tcp(port, token):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(1)
        sock.connect(('127.0.0.1', port))
        sock.sendall(token.encode())


def append(path, record):
    with open(path, 'a', encoding='utf-8') as stream:
        stream.write(json.dumps(record) + '\n')


def worker(args):
    kind, allowed, forbidden, log_path, token = args
    allowed, forbidden = int(allowed), int(forbidden)
    cgroup = Path('/proc/self/cgroup').read_text().strip().removeprefix('0::')
    assert cgroup.startswith('/blackice/s-'), cgroup
    result = {'case': kind, 'pid': os.getpid(), 'cgroup': cgroup}
    if kind == 'allow':
        tcp(allowed, token)
    elif kind.startswith(('tcp', 'udp')):
        family = socket.AF_INET6 if kind.endswith('6') else socket.AF_INET
        typ = socket.SOCK_DGRAM if kind.startswith('udp') else socket.SOCK_STREAM
        address = ('::1' if family == socket.AF_INET6 else '127.0.0.1', forbidden)
        with socket.socket(family, typ) as sock:
            sock.settimeout(1)
            operation = (lambda: sock.sendto(token.encode(), address)) if 'send' in kind else (lambda: sock.connect(address))
            result['errno'] = denied(operation)
    elif kind in ('sctp4', 'sctp6', 'ping4', 'ping6', 'udplite', 'mptcp'):
        family = socket.AF_INET6 if kind.endswith('6') else socket.AF_INET
        typ = socket.SOCK_DGRAM if kind.startswith('ping') or kind == 'udplite' else socket.SOCK_STREAM
        protocol = {'sctp4': 132, 'sctp6': 132, 'ping4': 1, 'ping6': 58, 'udplite': 136, 'mptcp': 262}[kind]
        def attempt():
            with socket.socket(family, typ, protocol) as sock:
                destination = ('::1' if family == socket.AF_INET6 else '127.0.0.1', forbidden)
                if typ == socket.SOCK_DGRAM:
                    sock.sendto(token.encode(), destination)
                else:
                    sock.connect(destination)
        result['errno'] = denied(attempt)
    elif kind == 'ping-command':
        try:
            run = subprocess.run(['/usr/bin/ping', '-n', '-c1', '-W1', '1.1.1.1'], capture_output=True, text=True)
            assert run.returncode != 0 and 'Operation not permitted' in run.stderr, (run.returncode, run.stderr)
            result['stderr'] = run.stderr.strip()
        except OSError as exc:
            assert exc.errno in PERMISSION, repr(exc)
            result['errno'] = exc.errno
    elif kind == 'reentry':
        marker = log_path + '.must-not-exist'
        try:
            run = subprocess.run([str(HELPER), '--protocol-v1', 's-00000001', '-', str(Path(log_path).parent),
                                  '--', '/usr/bin/touch', marker], capture_output=True, text=True)
            assert run.returncode == 125 and 'PermissionDenied' in run.stderr, (run.returncode, run.stderr)
            result['stderr'] = run.stderr.strip()
        except OSError as exc:
            assert exc.errno in PERMISSION, repr(exc)
            result['errno'] = exc.errno
        assert not Path(marker).exists()
    elif kind == 'membership':
        directory = Path('/sys/fs/cgroup' + cgroup)
        result['mkdir_errno'] = denied(lambda: (directory / 'escape').mkdir())
        result['migration_errno'] = denied(lambda: (directory / 'cgroup.procs').write_text(str(os.getpid())))
        assert Path('/proc/self/cgroup').read_text().strip() == '0::' + cgroup
        result['network_errno'] = denied(lambda: tcp(forbidden, token))
    elif kind in ('double-fork', 'kill-helper', 'kill-blackice'):
        first = os.fork()
        if first == 0:
            os.setsid()
            if os.fork() != 0:
                os._exit(0)
            try:
                limit = 1 if kind == 'double-fork' else 30
                for step in range(limit):
                    record = dict(result, pid=os.getpid(), step=step, monotonic_ns=time.monotonic_ns())
                    record['errno'] = denied(lambda: tcp(forbidden, token))
                    tcp(allowed, token + '-allowed')
                    append(log_path, record)
                    time.sleep(0.1)
            except BaseException as exc:
                append(log_path, {'error': repr(exc)})
                os._exit(1)
            os._exit(0)
        os.waitpid(first, 0)
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if kind == 'double-fork' and Path(log_path).exists():
                return
            time.sleep(0.05)
        raise AssertionError('fault probe was not terminated by its controller')
    else:
        raise AssertionError(kind)
    append(log_path, result)


class Receiver:
    def __init__(self, family, typ):
        self.family, self.typ = family, typ
        self.socket = socket.socket(family, typ)
        if family == socket.AF_INET6:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        self.socket.bind(('::1' if family == socket.AF_INET6 else '127.0.0.1', 0))
        self.port = self.socket.getsockname()[1]
        if typ == socket.SOCK_STREAM:
            self.socket.listen()
        self.socket.settimeout(0.05)
        self.seen = []
        self.stopping = False
        self.thread = threading.Thread(target=self.receive, daemon=True)
        self.thread.start()

    def receive(self):
        while not self.stopping:
            try:
                if self.typ == socket.SOCK_STREAM:
                    conn, _ = self.socket.accept()
                    with conn:
                        conn.settimeout(1)
                        self.seen.append(conn.recv(2048).decode())
                else:
                    self.seen.append(self.socket.recvfrom(2048)[0].decode())
            except (TimeoutError, OSError):
                continue

    def control(self):
        address = ('::1' if self.family == socket.AF_INET6 else '127.0.0.1', self.port)
        with socket.socket(self.family, self.typ) as sock:
            sock.settimeout(1)
            if self.typ == socket.SOCK_STREAM:
                sock.connect(address)
                sock.sendall(b'outside-positive-control')
            else:
                sock.sendto(b'outside-positive-control', address)
        wait_for(lambda: 'outside-positive-control' in self.seen)

    def close(self):
        self.stopping = True
        self.thread.join(2)
        self.socket.close()


def wait_for(condition, seconds=4):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = condition()
        if value:
            return value
        time.sleep(0.025)
    raise AssertionError('timed out waiting for probe state')


def rows(path):
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line]


def exited(pidfd, timeout=4000):
    poll = select.poll()
    poll.register(pidfd, select.POLLIN)
    return bool(poll.poll(timeout))


def run_suite(crashes):
    built = REPO / 'zig-out/bin/blackice-linux-helper'
    if not HELPER.exists():
        print('BLOCKED: owner-installed helper is missing; no traffic tests ran.', file=sys.stderr)
        return 2
    if not PROBE.exists() or not built.exists():
        print('Build with zig build and zig build linux-probe first.', file=sys.stderr)
        return 2
    if hashlib.sha256(HELPER.read_bytes()).digest() != hashlib.sha256(built.read_bytes()).digest():
        print('BLOCKED: installed and built helpers differ; ask the owner to install the reviewed build.', file=sys.stderr)
        return 2
    directory = REPO / 'out' / ('linux-integration-' + str(time.time_ns()))
    directory.mkdir(parents=True)
    receivers = [Receiver(family, typ) for family in (socket.AF_INET, socket.AF_INET6)
                 for typ in (socket.SOCK_STREAM, socket.SOCK_DGRAM)]
    allowed = Receiver(socket.AF_INET, socket.SOCK_STREAM)
    receivers.append(allowed)
    results = []
    try:
        for receiver in receivers:
            receiver.control()
        cases = ['allow', 'tcp4', 'tcp6', 'udp-connect4', 'udp-connect6', 'udp-send4', 'udp-send6',
                 'sctp4', 'sctp6', 'ping4', 'ping6', 'udplite', 'mptcp', 'ping-command', 'reentry',
                 'membership', 'double-fork']
        if crashes:
            cases += ['kill-blackice', 'kill-helper']
        for kind in cases:
            family = socket.AF_INET6 if kind.endswith('6') else socket.AF_INET
            typ = socket.SOCK_DGRAM if kind.startswith('udp') else socket.SOCK_STREAM
            denied_receiver = next(r for r in receivers if r.family == family and r.typ == typ)
            token = 'blackice-test-' + kind
            state = directory / kind
            state.mkdir()
            receipt_path = state / 'receipts.local.jsonl'
            worker_log = directory / (kind + '.worker.jsonl') # outside the read-only scope state
            command = [str(PROBE), str(allowed.port), str(receipt_path), '--', sys.executable,
                       str(Path(__file__).resolve()), '--worker', kind, str(allowed.port),
                       str(denied_receiver.port), str(worker_log), token]
            process = subprocess.Popen(command, cwd=REPO, env=dict(os.environ, LC_ALL='C'),
                                       stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            handles = []
            try:
                if kind.startswith('kill-'):
                    first = wait_for(lambda: rows(worker_log))
                    assert first[0].get('errno') in PERMISSION, first
                    orphanfd = os.pidfd_open(first[0]['pid'])
                    handles.append(orphanfd)
                    if kind == 'kill-blackice':
                        targetfd = os.pidfd_open(process.pid)
                    else:
                        children = Path(f'/proc/{process.pid}/task/{process.pid}/children').read_text().split()
                        assert len(children) == 1, children
                        targetfd = os.pidfd_open(int(children[0]))
                    handles.append(targetfd)
                    killed_at = time.monotonic_ns()
                    signal.pidfd_send_signal(targetfd, signal.SIGKILL)
                    stdout, stderr = process.communicate(timeout=10)
                    if kind == 'kill-blackice':
                        assert process.returncode == -signal.SIGKILL
                        assert exited(orphanfd), 'helper did not reap the scope after supervisor death'
                    else:
                        assert process.returncode == 125, (process.returncode, stderr)
                        after = [r for r in rows(worker_log) if r.get('monotonic_ns', 0) > killed_at + 100_000_000]
                        assert len(after) >= 2 and all(r.get('errno') in PERMISSION for r in after), after
                        assert exited(orphanfd), 'bounded orphan probe did not finish'
                else:
                    stdout, stderr = process.communicate(timeout=20)
                    assert process.returncode == 0, (kind, process.returncode, stdout, stderr)
                    receipts = rows(receipt_path)
                    assert any(r['event'] == 'backend_armed' for r in receipts), receipts
                    assert any(r['event'] == 'backend_cleanup' for r in receipts), receipts
                    assert rows(worker_log) and all('error' not in row for row in rows(worker_log))
                    if kind.startswith(('tcp', 'udp')) or kind in ('membership', 'double-fork'):
                        assert any(r['event'] == 'kernel_drop' and r.get('verdict') == 'deny'
                                   and r.get('port') == denied_receiver.port for r in receipts), receipts
                time.sleep(0.1)
                assert token not in denied_receiver.seen, (kind, 'denied traffic arrived')
                if kind == 'allow':
                    wait_for(lambda: token in allowed.seen)
                results.append({'case': kind, 'status': 'passed', 'receipts': str(receipt_path.relative_to(directory))})
                print(kind + ': passed', flush=True)
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=4)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                for fd in handles:
                    os.close(fd)
        report = {'kernel': os.uname().release, 'helper_sha256': hashlib.sha256(HELPER.read_bytes()).hexdigest(),
                  'receiver_scope': 'local loopback; not off-host P0-02 evidence', 'cases': results,
                  'owner_teardown_required': crashes}
        (directory / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
        print('Results:', directory)
        if crashes:
            print('The killed-helper case retains an empty filtered cgroup. Owner teardown is required.')
        return 0
    finally:
        for receiver in receivers:
            receiver.close()


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--worker':
        worker(sys.argv[2:])
    else:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument('--crash-tests', action='store_true', help='also kill our supervisor/helper; leaves a retained cgroup for owner teardown')
        sys.exit(run_suite(parser.parse_args().crash_tests))
