#!/usr/bin/python3
"""Prepared runtime fixture; never invoked by builds or unit tests. No BPF/control/setup calls."""
import argparse
import errno
import ipaddress
import json
import os
from pathlib import Path
import re
import select
import selectors
import socket
import sys
import time


def emit(event, **fields):
    print(json.dumps({"event": event, "monotonic_ns": time.monotonic_ns(), **fields}), flush=True)


def address(value, version):
    parsed = ipaddress.ip_address(value)
    if parsed.version != version or parsed.is_unspecified or parsed.is_multicast:
        raise ValueError("expected a specific unicast address of the requested family")
    return str(parsed)


def cases(v4, v6):
    return [
        ("tcp4", socket.AF_INET, socket.SOCK_STREAM, (v4, 47121)),
        ("tcp6", socket.AF_INET6, socket.SOCK_STREAM, (v6, 47122)),
        ("udp4", socket.AF_INET, socket.SOCK_DGRAM, (v4, 47123)),
        ("udp6", socket.AF_INET6, socket.SOCK_DGRAM, (v6, 47124)),
        ("tcp_mapped", socket.AF_INET6, socket.SOCK_STREAM, ("::ffff:" + v4, 47121)),
        ("udp_mapped", socket.AF_INET6, socket.SOCK_DGRAM, ("::ffff:" + v4, 47123)),
    ]


def send(args):
    ok = True
    for name, family, kind, destination in cases(args.v4, args.v6):
        payload = f"{args.token}:{args.phase}:{name}".encode("ascii")
        failure = None
        try:
            with socket.socket(family, kind) as client:
                client.settimeout(2)
                if kind == socket.SOCK_STREAM:
                    client.connect(destination)
                    client.sendall(payload)
                else:
                    client.sendto(payload, destination)
        except OSError as error:
            failure = error.errno if error.errno is not None else -1
        passed = (failure in (errno.EPERM, errno.EACCES)) if args.expect == "deny" else failure is None
        emit("attempt", case=name, phase=args.phase, expected=args.expect,
             errno=failure, passed=passed, pid=os.getpid())
        ok = ok and passed
    return 0 if ok else 1


def protocols(_args):
    ok = True
    for name, family, kind, protocol in (
        ("icmp4", socket.AF_INET, socket.SOCK_DGRAM, 1),
        ("icmp6", socket.AF_INET6, socket.SOCK_DGRAM, 58),
        ("sctp4", socket.AF_INET, socket.SOCK_STREAM, 132),
        ("udplite4", socket.AF_INET, socket.SOCK_DGRAM, 136),
        ("mptcp4", socket.AF_INET, socket.SOCK_STREAM, 262),
        ("raw4", socket.AF_INET, socket.SOCK_RAW, 1),
    ):
        failure = None
        try:
            with socket.socket(family, kind, protocol):
                pass
        except OSError as error:
            failure = error.errno if error.errno is not None else -1
        passed = failure in (errno.EPERM, errno.EACCES)
        emit("socket_attempt", case=name, expected="deny", errno=failure, passed=passed, pid=os.getpid())
        ok = ok and passed
    return 0 if ok else 1


def receiver(args):
    selector = selectors.DefaultSelector()
    opened = []
    streams = {}
    ready = False
    try:
        for name, family, kind, endpoint in cases(args.v4, args.v6)[:4]:
            listener = socket.socket(family, kind)
            opened.append(listener)
            if family == socket.AF_INET6:
                listener.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            listener.bind(endpoint)
            if kind == socket.SOCK_STREAM:
                listener.listen(16)
            listener.setblocking(False)
            selector.register(listener, selectors.EVENT_READ, (name, kind))
        emit("ready", ports=[47121, 47122, 47123, 47124])
        ready = True
        deadline = time.monotonic() + args.seconds
        while time.monotonic() < deadline:
            for key, _ in selector.select(min(0.2, max(0, deadline - time.monotonic()))):
                current = key.fileobj
                name, kind = key.data
                if kind == "stream":
                    data = current.recv(4096)
                    streams[current] += data
                    if len(streams[current]) > 4096:
                        raise ValueError("unexpected oversized receiver payload")
                    if not data:
                        emit("payload", case=name, payload=streams.pop(current).decode("ascii", "replace"))
                        selector.unregister(current)
                        current.close()
                elif kind == socket.SOCK_STREAM:
                    peer, _ = current.accept()
                    if len(streams) >= 32:
                        peer.close()
                        raise ValueError("unexpected receiver connection flood")
                    peer.setblocking(False)
                    streams[peer] = b""
                    selector.register(peer, selectors.EVENT_READ, (name, "stream"))
                else:
                    data, _ = current.recvfrom(4096)
                    emit("payload", case=name, payload=data.decode("ascii", "replace"))
        if streams:
            raise ValueError("receiver stopped with incomplete TCP payloads")
        return 0
    finally:
        for stream in streams:
            stream.close()
        for listener in opened:
            listener.close()
        selector.close()
        if ready:
            emit("stopped")


def wait_barrier(args):
    if not args.wait_for:
        return
    release = Path(args.wait_for)
    if release.exists():
        raise ValueError("release marker already exists")
    if not args.ready_file:
        raise ValueError("wait-for requires a ready-file")
    with Path(args.ready_file).open("x") as out:
        json.dump({"pid": os.getpid(), "monotonic_ns": time.monotonic_ns()}, out)
    deadline = time.monotonic() + 120
    while not release.exists():
        if time.monotonic() >= deadline:
            raise TimeoutError("operator did not release the prepared probe within 120 seconds")
        time.sleep(0.01)


def double_fork(args, operation):
    read_fd, write_fd = os.pipe()
    child = os.fork()
    if child == 0:
        os.close(read_fd)
        os.setsid()
        if os.fork() != 0:
            os._exit(0)
        try:
            status = operation(args)
        except BaseException as error:
            emit("probe_error", reason=type(error).__name__)
            status = 1
        os.write(write_fd, bytes([status]))
        os.close(write_fd)
        os._exit(status)
    os.close(write_fd)
    os.waitpid(child, 0)
    try:
        if not select.select([read_fd], [], [], 40)[0]:
            raise TimeoutError("detached probe did not report completion")
        result = os.read(read_fd, 1)
        return result[0] if result else 1
    finally:
        os.close(read_fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("receiver", "send", "protocols"))
    parser.add_argument("--authorized-network-test", action="store_true", required=True)
    parser.add_argument("--v4")
    parser.add_argument("--v6")
    parser.add_argument("--seconds", type=int, default=90)
    parser.add_argument("--expect", choices=("control", "deny"), default="deny")
    parser.add_argument("--token", default="blackice-appfilter")
    parser.add_argument("--phase", default="denied")
    parser.add_argument("--double-fork", action="store_true")
    parser.add_argument("--wait-for")
    parser.add_argument("--ready-file")
    args = parser.parse_args()
    if args.mode != "protocols":
        args.v4, args.v6 = address(args.v4, 4), address(args.v6, 6)
    if not 1 <= args.seconds <= 1800:
        parser.error("seconds must be 1..1800")
    if any(not re.fullmatch(r"[A-Za-z0-9_-]{1,80}", value) for value in (args.token, args.phase)):
        parser.error("token and phase must be short ASCII identifiers")
    if args.mode == "receiver":
        if args.double_fork or args.wait_for or args.ready_file:
            parser.error("receiver has no fork or barrier options")
        return receiver(args)
    wait_barrier(args)
    operation = send if args.mode == "send" else protocols
    return double_fork(args, operation) if args.double_fork else operation(args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        emit("fixture_error", reason=type(error).__name__, detail=str(error))
        sys.exit(1)
