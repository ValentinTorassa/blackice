#!/usr/bin/python3 -I
"""blackice Linux app filter: kernel tests in a disposable VM.

Runs INSIDE the test VM only, never on a real machine. The host driver (../run.sh) copies this file to
/opt/aftest/aftest.py and calls `sudo python3 -I /opt/aftest/aftest.py phase NAME`. The same file is the probe that
the phases start as other users, under listed launchers, from cron/at and as system or user services
(`aftest.py probe ...`).

Each test case writes /var/tmp/aftest/results/cases/<case>/:
  log.txt                    every command, its output and every check, in order
  tree-before.txt/.json      `bpftool cgroup tree` (and program/link lists) when the case starts
  tree-after.txt/.json       the same when it ends
and appends one JSON line per check to /var/tmp/aftest/results/results.jsonl:
  {"case", "id", "finding", "expect", "got", "verdict": PASS|FAIL|OBSERVE|SKIP, "detail"}
OBSERVE records a behaviour security must classify (for example a documented limit); it is not a pass.
EXPECTED.md explains every case. This file holds the expected values.
"""
import argparse
import base64
import ctypes
import errno
import hashlib
import json
import os
import pwd
import re
import resource
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import time
import traceback
from datetime import datetime

ROOT = "/opt/aftest"
SELF = ROOT + "/aftest.py"
CLI = ROOT + "/bin/blackice"
URING = ROOT + "/bin/uringprobe"
CANDIDATE = ROOT + "/candidate"
POLICY = ROOT + "/policies/tests.json"  # six apps, for the listener-guard matrix
POLICY_HOST = ROOT + "/policies/host-curl.json"  # curl only, like the owner's first host policy
WORK = "/var/tmp/aftest"
RESULTS = WORK + "/results"
DROP = WORK + "/drop"


def _conf():
    try:
        with open(ROOT + "/aftest.json") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


CONF = _conf()  # written by run.sh: owner, other, label, commit
OWNER, OTHER = CONF.get("owner", "test"), CONF.get("other", "other")
LABEL = CONF.get("label", "unlabelled")
LABEL_TEXT = "DRY RUN (debugging only, not evidence)" if LABEL == "dry-run" else LABEL
LAUNCH_DIR = ROOT + "/launch"
POLKIT_RULE = "/etc/polkit-1/rules.d/49-aftest-vm-only.rules"
UNIT = "blackice-appfilter.service"
STATE_DIR = "/var/lib/blackice-appfilter"
PIN_ROOT = "/run/blackice-appfilter/bpf"
PIN_KERNEL = "6.12.113+deb13-amd64"
PIN_BTF = "5727b13fd2212290ae031719c9367251c0c8eda0a3f48181af71452ccf5f8943"

NETNS, HOST_IF, NS_IF = "aftest", "aft-h", "aft-n"
HOST4, NS4, HOST6, NS6 = "10.99.0.1", "10.99.0.2", "fd99::1", "fd99::2"
NS6_EXTRA = ["fd99::12", "fd99::13", "fd99::14"]  # SRH first hops for the tagged cases
NS_TCP_PORT = 9000  # the netns answers TCP here (controls)

# Test policy, in order: app id = index + 1. Launchers let a probe run with that app's tag.
APPS = [
    ("setsid", "/usr/bin/setsid", ["/usr/bin/setsid", "--fork", "--wait"], "example.com"),
    ("env", "/usr/bin/env", ["/usr/bin/env"], "example.org"),
    ("nice", "/usr/bin/nice", ["/usr/bin/nice", "-n", "0"], "example.com"),
    ("curl", "/usr/bin/curl", None, "example.com"),
    ("wget", "/usr/bin/wget", None, "example.org"),
    ("aft-launch", LAUNCH_DIR + "/aft-launch", [LAUNCH_DIR + "/aft-launch", "--fork", "--wait"], "example.com"),
]
FIRST_PORT, LAST_PORT = 760, 774
LAUNCHED = [1, 2, 3, 6]  # app ids with a launcher

# The seven hooks of 6c849ec: five at user.slice, the listener guard (peer4/6) at the cgroup root.
USER_HOOKS = {"bi_af_conn4", "bi_af_conn6", "bi_af_send4", "bi_af_send6", "bi_af_create"}
ROOT_HOOKS = {"bi_af_peer4", "bi_af_peer6"}
PHASES_ARMING = {"maps": 1, "cgroup": 2, "listeners": 3, "tracking": 4, "armed": 5}


def app_ports(app):
    tls = FIRST_PORT + (app - 1) * 2
    return (tls, tls + 1)


CAP_NET_BIND_SERVICE, CAP_NET_ADMIN, CAP_PERFMON, CAP_BPF = 10, 12, 38, 39

# ---------------------------------------------------------------------------------------------------------------
# helpers and per-case logging

CURRENT = None  # the open Case, if any


def jprint(**fields):
    print(json.dumps(fields, sort_keys=True), flush=True)


def outcome_of(exc):
    if isinstance(exc, socket.timeout) or isinstance(exc, TimeoutError):
        return "timeout"
    if isinstance(exc, OSError) and exc.errno:
        return errno.errorcode.get(exc.errno, str(exc.errno))
    return type(exc).__name__


def note(text):
    if CURRENT is not None:
        CURRENT.write(text)


def run(cmd, timeout=120, input=None, check=False, quiet=False):
    """Runs a command, returns (rc, stdout, stderr), and logs it to the open case."""
    t0 = time.time()
    try:
        p = subprocess.run(cmd, input=input, capture_output=True, text=True, timeout=timeout)
        rc, out, err = p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired as e:
        rc, out, err = 124, (e.stdout or b"").decode() if isinstance(e.stdout, bytes) else (e.stdout or ""), "[timeout]"
    if not quiet:
        note(f"$ {' '.join(cmd)}\n  rc={rc} ({time.time() - t0:.2f}s)\n" + "".join(f"  | {l}\n" for l in out.splitlines()[:200])
             + "".join(f"  ! {l}\n" for l in err.splitlines()[:50]))
    if check and rc != 0:
        raise RuntimeError(f"{cmd!r} failed: {rc} {err.strip()}")
    return rc, out, err


def as_user(user, cmd):
    return ["/usr/sbin/runuser", "-u", user, "--"] + cmd


def probe_cmd(*args):
    return ["/usr/bin/python3", "-I", SELF, "probe"] + list(args)


def launched(app, cmd):
    return APPS[app - 1][2] + cmd


def json_lines(text):
    out = []
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("{"):
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
    return out


def record(check_id, finding, expect, got, verdict, **detail):
    os.makedirs(RESULTS, exist_ok=True)
    row = {"case": CURRENT.cid if CURRENT else "-", "id": check_id, "finding": finding, "expect": expect, "got": got,
           "verdict": verdict, "ts": time.time()}
    if detail:
        row["detail"] = detail
    with open(RESULTS + "/results.jsonl", "a") as f:
        f.write(json.dumps(row, sort_keys=True, default=str) + "\n")
    line = f"{verdict:7} {check_id}: expect {expect!r}, got {got!r}"
    print(line[:600], flush=True)
    note(line + ("\n  detail: " + json.dumps(detail, default=str)[:4000] if detail else "") + "\n")
    if CURRENT is not None and verdict == "FAIL":
        CURRENT.failed = True
    return verdict != "FAIL"


def check(check_id, finding, expect, got, ok, **detail):
    return record(check_id, finding, expect, got, "PASS" if ok else "FAIL", **detail)


def save(name, text):
    os.makedirs(RESULTS, exist_ok=True)
    with open(f"{RESULTS}/{name}", "w") as f:
        f.write(text)


def bpftool_json(*args):
    rc, out, err = run(["/usr/sbin/bpftool", "-j"] + list(args), timeout=30, quiet=True)
    if rc != 0:
        return {"error": err.strip()}
    try:
        return json.loads(out)
    except ValueError:
        return {"error": "bad json", "raw": out[:2000]}


def cgroup_attachments():
    """Rows of (cgroup, attach_type, name, id) from `bpftool cgroup tree`."""
    tree = bpftool_json("cgroup", "tree")
    rows = []
    if isinstance(tree, list):
        for entry in tree:
            for prog in entry.get("programs", []):
                rows.append({"cgroup": entry.get("cgroup", "").rstrip("/") or "/", "attach_type": prog.get("attach_type"),
                             "name": prog.get("name", ""), "id": prog.get("id")})
    return rows


def trees():
    """Human and JSON views of the BPF state that every case records before and after."""
    text = run(["/usr/sbin/bpftool", "cgroup", "tree"], timeout=30, quiet=True)[1]
    progs = bpftool_json("prog", "show")
    links = bpftool_json("link", "show")
    ours_progs = [{"id": p.get("id"), "name": p.get("name"), "type": p.get("type")} for p in progs if isinstance(p, dict) and str(p.get("name", "")).startswith("bi_af_")] if isinstance(progs, list) else progs
    data = {"cgroup_tree": cgroup_attachments(), "bi_af_programs": ours_progs, "links": links,
            "pins": sorted(os.listdir(PIN_ROOT)) if os.path.isdir(PIN_ROOT) else None, "t": time.time()}
    return text, data


class Case:
    """One test case: its own directory, log and before/after trees."""

    def __init__(self, cid, title, finding, before=True, after=True, resume=False, reset=True):
        self.cid, self.title, self.finding, self.failed = cid, title, finding, False
        self.reset = reset
        self.dir = f"{RESULTS}/cases/{cid}"
        # A case driven from the host (interactive off) spans two phases: the first records tree-before, the
        # second resumes the same log and records tree-after.
        self.want_before, self.want_after, self.resume = before, after, resume

    def write(self, text):
        with open(self.dir + "/log.txt", "a") as f:
            f.write(text)

    def tree(self, when):
        text, data = trees()
        with open(f"{self.dir}/tree-{when}.txt", "w") as f:
            f.write(text)
        with open(f"{self.dir}/tree-{when}.json", "w") as f:
            json.dump(data, f, indent=1, sort_keys=True, default=str)
        return data

    def __enter__(self):
        global CURRENT
        os.makedirs(self.dir, exist_ok=True)
        CURRENT = self
        now = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
        if self.resume:
            self.write(f"# resumed {now}\n")
        else:
            self.write(f"# {self.cid}: {self.title} ({self.finding})\n# run: {LABEL_TEXT}, commit {CONF.get('commit', '?')}\n# start {now}\n")
        print(f"-- case {self.cid}: {self.title}{' (resumed)' if self.resume else ''}", flush=True)
        if self.reset and not self.resume:
            harness_reset(self)
        self.before = self.tree("before") if self.want_before else None
        return self

    def __exit__(self, kind, value, tb):
        global CURRENT
        if kind is not None:
            self.write("EXCEPTION\n" + "".join(traceback.format_exception(kind, value, tb)))
            record(f"{self.cid}.completed", self.finding, "case runs to the end", f"{kind.__name__}: {value}", "FAIL")
        self.after = self.tree("after") if self.want_after else None
        self.write(f"# {'end' if self.want_after else 'pause'} {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}: {'FAIL' if self.failed else 'ok'}\n")
        CURRENT = None
        return True  # an exception fails this case; the phase goes on with the next one


# ---------------------------------------------------------------------------------------------------------------
# probes (run as any user, in any context; they only print JSON lines)


def whoami():
    with open("/proc/self/cgroup") as f:
        cgroup = f.read().strip()
    jprint(event="whoami", uid=os.getuid(), euid=os.geteuid(), pid=os.getpid(), cgroup=cgroup)


def own_addresses():
    """Non-loopback addresses of this host (main namespace), for the non-local spellings."""
    rc, out, _ = run(["/usr/sbin/ip", "-j", "addr", "show"], timeout=10)
    addrs = []
    if rc == 0:
        for link in json.loads(out):
            for a in link.get("addr_info", []):
                ip = a.get("local", "")
                if not ip or ip.startswith("127.") or ip == "::1":
                    continue
                if a.get("scope") == "link":
                    continue  # link-local needs a scope id; covered by the others
                addrs.append(ip)
    return addrs


# (label, family, address, kind). kinds: exact | loop-other | unspec | zeronet | nonlocal
def spellings():
    rows = [
        ("127.0.0.1", socket.AF_INET, "127.0.0.1", "exact"),
        ("127.0.0.2", socket.AF_INET, "127.0.0.2", "loop-other"),
        ("127.255.255.254", socket.AF_INET, "127.255.255.254", "loop-other"),
        ("0.0.0.0", socket.AF_INET, "0.0.0.0", "unspec"),
        ("0.1.2.3", socket.AF_INET, "0.1.2.3", "zeronet"),
        ("::1", socket.AF_INET6, "::1", "exact"),
        ("::", socket.AF_INET6, "::", "unspec"),
        ("::ffff:127.0.0.1", socket.AF_INET6, "::ffff:127.0.0.1", "exact"),
        ("::ffff:127.0.0.2", socket.AF_INET6, "::ffff:127.0.0.2", "loop-other"),
        ("::ffff:0.0.0.0", socket.AF_INET6, "::ffff:0.0.0.0", "unspec"),
        ("::ffff:0.1.2.3", socket.AF_INET6, "::ffff:0.1.2.3", "zeronet"),
        ("::127.0.0.1", socket.AF_INET6, "::127.0.0.1", "nonlocal"),
    ]
    for ip in own_addresses():
        fam = socket.AF_INET6 if ":" in ip else socket.AF_INET
        rows.append((f"own:{ip}", fam, ip, "nonlocal"))
    return rows


def try_connect(family, addr, port, proto=0, timeout=1.5, fastopen=False):
    try:
        s = socket.socket(family, socket.SOCK_STREAM, proto)
    except OSError as e:
        return "socket:" + outcome_of(e)
    try:
        if family == socket.AF_INET6:
            s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        if fastopen:
            # MSG_FASTOPEN on a non-blocking socket: the hook's refusal comes back from sendto itself;
            # otherwise the SYN is out (EINPROGRESS) and SO_ERROR tells how the handshake ended.
            s.setblocking(False)
            try:
                s.sendto(b"x", 0x20000000, (addr, port))
                return "connected"
            except BlockingIOError:
                p = select.poll()
                p.register(s, select.POLLOUT)
                if not p.poll(int(timeout * 1000)):
                    return "timeout"
                err = s.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
                return "connected" if err == 0 else errno.errorcode.get(err, str(err))
        s.settimeout(timeout)
        s.connect((addr, port))
        return "connected"
    except Exception as e:  # noqa: BLE001 - the outcome is the result
        return outcome_of(e)
    finally:
        s.close()


def probe_h1(args):
    whoami()
    rows = spellings()
    for label, fam, addr, kind in rows:
        for port in range(FIRST_PORT, LAST_PORT + 1):
            jprint(event="h1", via="connect", spelling=label, kind=kind, port=port, outcome=try_connect(fam, addr, port))
    # TCP Fast Open and MPTCP, on a subset: they reach connect through other kernel paths.
    subset = [r for r in rows if r[0] in ("127.0.0.1", "0.0.0.0", "::1", "::", "::ffff:0.0.0.0", "::ffff:127.0.0.1")]
    for label, fam, addr, kind in subset:
        for port in (760, 762, 770, 774):
            jprint(event="h1", via="fastopen", spelling=label, kind=kind, port=port,
                   outcome=try_connect(fam, addr, port, fastopen=True))
            jprint(event="h1", via="mptcp", spelling=label, kind=kind, port=port,
                   outcome=try_connect(fam, addr, port, proto=262))
    jprint(event="done")


def probe_connect(args):
    fam = socket.AF_INET6 if ":" in args.addr else socket.AF_INET
    jprint(event="connect", addr=args.addr, port=args.port, outcome=try_connect(fam, args.addr, args.port, timeout=args.timeout))


def bound_device(s):
    try:
        raw = s.getsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, 16)
        return raw.split(b"\0", 1)[0].decode()
    except OSError as e:
        return "error:" + outcome_of(e)


def probe_listen(args):
    fam = socket.AF_INET6 if args.bind and ":" in args.bind else socket.AF_INET
    s = socket.socket(fam, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if fam == socket.AF_INET6:
        s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
    try:
        if args.bind != "none":
            s.bind((args.bind, args.port))
        s.listen(16)  # unbound: autobinds to an ephemeral port on the wildcard address
    except OSError as e:
        jprint(event="listening", error=outcome_of(e))
        return
    jprint(event="listening", port=s.getsockname()[1], bound_device=bound_device(s))
    s.settimeout(0.2)
    accepted = []
    end = time.time() + args.seconds
    while time.time() < end:
        try:
            c, peer = s.accept()
        except socket.timeout:
            continue
        accepted.append({"peer": peer[0], "bound_device": bound_device(c)})
        c.close()
    jprint(event="done", accepted=accepted)


def probe_bindtodevice(args):
    ifindex = socket.if_nametoindex(args.iface)
    for kind in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
        s = socket.socket(socket.AF_INET, kind)
        result = {"initial": bound_device(s)}
        for name, level, opt, value in (
            ("set_iface", socket.SOL_SOCKET, socket.SO_BINDTODEVICE, args.iface.encode()),
            ("set_empty", socket.SOL_SOCKET, socket.SO_BINDTODEVICE, b""),
            ("ifindex_iface", socket.SOL_SOCKET, 62, struct.pack("i", ifindex)),  # SO_BINDTOIFINDEX
            ("ifindex_zero", socket.SOL_SOCKET, 62, struct.pack("i", 0)),
        ):
            try:
                s.setsockopt(level, opt, value)
                result[name] = "ok"
            except OSError as e:
                result[name] = outcome_of(e)
        result["final"] = bound_device(s)
        s.close()
        jprint(event="bindtodevice", type="tcp" if kind == socket.SOCK_STREAM else "udp", **result)


def probe_pktinfo(args):
    ifindex = socket.if_nametoindex(args.iface)
    token = args.token.encode()
    # IPv4: IP_PKTINFO = struct in_pktinfo { int ipi_ifindex; in_addr ipi_spec_dst; in_addr ipi_addr; }
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    info = struct.pack("i4s4s", ifindex, socket.inet_aton(HOST4), socket.inet_aton("0.0.0.0"))
    try:
        s.sendmsg([token + b"-v4"], [(socket.IPPROTO_IP, socket.IP_PKTINFO, info)], 0, (args.dst4, args.port))
        r4 = "sent"
    except OSError as e:
        r4 = outcome_of(e)
    s.close()
    # IPv6 socket to the mapped stub: IPV6_PKTINFO = struct in6_pktinfo { in6_addr ipi6_addr; int ipi6_ifindex; }
    s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
    s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
    info6 = struct.pack("16si", socket.inet_pton(socket.AF_INET6, "::"), ifindex)
    try:
        s.sendmsg([token + b"-v6"], [(socket.IPPROTO_IPV6, socket.IPV6_PKTINFO, info6)], 0, (args.dst6, args.port))
        r6 = "sent"
    except OSError as e:
        r6 = outcome_of(e)
    s.close()
    jprint(event="pktinfo", v4=r4, v6=r6, dst4=args.dst4, dst6=args.dst6, port=args.port, token=args.token)


def dns_query(name):
    q = struct.pack(">HHHHHH", 0x4242, 0x0100, 1, 0, 0, 0)
    for part in name.split("."):
        q += bytes([len(part)]) + part.encode()
    return q + b"\0" + struct.pack(">HH", 1, 1)


def probe_dns(args):
    for fam, addr in ((socket.AF_INET, "127.0.0.53"), (socket.AF_INET6, "::ffff:127.0.0.53")):
        s = socket.socket(fam, socket.SOCK_DGRAM)
        if fam == socket.AF_INET6:
            s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        s.settimeout(5)
        try:
            s.sendto(dns_query("example.com"), (addr, 53))
            data = s.recv(2048)
            ok = len(data) > 12 and data[:2] == b"\x42\x42"
            res = "answered" if ok else "bad-answer"
        except Exception as e:  # noqa: BLE001
            res = outcome_of(e)
        s.close()
        jprint(event="dns", server=addr, outcome=res)


def probe_redirect(args):
    for fam, addr in ((socket.AF_INET, "1.1.1.1"), (socket.AF_INET6, "2606:4700:4700::1111"), (socket.AF_INET6, "::ffff:1.1.1.1")):
        for port in (443, 80):
            s = socket.socket(fam, socket.SOCK_STREAM)
            if fam == socket.AF_INET6:
                s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
            s.settimeout(3)
            try:
                s.connect((addr, port))
                peer = s.getpeername()
                res = {"outcome": "connected", "peer": [peer[0], peer[1]]}
            except Exception as e:  # noqa: BLE001
                res = {"outcome": outcome_of(e)}
            s.close()
            jprint(event="redirect", dst=addr, port=port, **res)


def srh(segment):
    # struct ipv6_sr_hdr with two segments: [0] is replaced by the final destination, [1] is the first hop.
    segs = socket.inet_pton(socket.AF_INET6, "::") + socket.inet_pton(socket.AF_INET6, segment)
    return struct.pack("BBBBBBH", 0, 4, 4, 1, 1, 0, 0) + segs  # nexthdr, hdrlen, type 4, segments_left, last_entry


def probe_srh(args):
    s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    try:
        s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_RTHDR, srh(args.segment))
        opt = "ok"
    except OSError as e:
        opt = outcome_of(e)
    s.settimeout(2)
    try:
        s.connect((args.dst, args.port))
        res = "connected"
    except Exception as e:  # noqa: BLE001
        res = outcome_of(e)
    s.close()
    jprint(event="srh", segment=args.segment, dst=args.dst, port=args.port, setsockopt=opt, connect=res)


def probe_lsrr(args):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    opt = bytes([0x83, 7, 4]) + socket.inet_aton(args.hop) + b"\x01"  # LSRR, len 7, ptr 4, hop, NOP pad
    try:
        s.setsockopt(socket.IPPROTO_IP, socket.IP_OPTIONS, opt)
        res = "ok"
    except OSError as e:
        res = outcome_of(e)
    s.close()
    jprint(event="lsrr", setsockopt=res)


def raise_nofile(want):
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    resource.setrlimit(resource.RLIMIT_NOFILE, (min(max(soft, want), hard), hard))
    return resource.getrlimit(resource.RLIMIT_NOFILE)[0]


def probe_idle_flood(args):
    limit = raise_nofile(args.count + 64)
    socks, refused = [], {}
    for _ in range(args.count):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(1)
        try:
            s.connect(("127.0.0.1", args.port))
            s.setblocking(False)
            socks.append(s)
        except Exception as e:  # noqa: BLE001
            refused[outcome_of(e)] = refused.get(outcome_of(e), 0) + 1
            s.close()
    start = time.time()
    jprint(event="flood-open", connected=len(socks), refused=refused, nofile=limit)
    closed = set()
    by_fd = {s.fileno(): s for s in socks}
    poller = select.poll()  # select() cannot watch fds above 1023
    for fd in by_fd:
        poller.register(fd, select.POLLIN | select.POLLRDHUP)
    for mark in sorted(args.marks):
        while time.time() - start < mark:
            for fd, _ in poller.poll(200):
                try:
                    gone = by_fd[fd].recv(1) == b""
                except BlockingIOError:
                    gone = False
                except OSError:
                    gone = True
                if gone:
                    closed.add(fd)
                    poller.unregister(fd)
        jprint(event="flood-mark", seconds=mark, closed_by_server=len(closed), connected=len(socks))
    for s in socks:
        s.close()


def probe_udp_flood(args):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    errs = {}
    for _ in range(args.count):
        try:
            s.sendto(b"x", (args.dst, args.port))
            errs["sent"] = errs.get("sent", 0) + 1
        except OSError as e:
            errs[outcome_of(e)] = errs.get(outcome_of(e), 0) + 1
    jprint(event="udp-flood", outcomes=errs)


def probe_tagcheck(args):
    tls = app_ports(args.app)[0]
    jprint(event="tagcheck", app=args.app, own_port=try_connect(socket.AF_INET, "127.0.0.1", tls, timeout=1),
           netns=try_connect(socket.AF_INET, NS4, NS_TCP_PORT, timeout=1))


def probe_forker(args):
    """A long-lived (tagged) parent: each new value in the trigger file forks one child that runs the tag check
    and appends {"n", "own_port", "netns"} to the output file. The value "exit" ends it."""
    jprint(event="forker", pid=os.getpid())
    seen, end = None, time.time() + 1800
    tls = app_ports(args.app)[0]
    while time.time() < end:
        try:
            with open(args.trigger) as f:
                value = f.read().strip()
        except OSError:
            value = None
        if value is not None and value != seen:
            seen = value
            if value == "exit":
                break
            r, w = os.pipe()
            pid = os.fork()
            if pid == 0:
                os.close(r)
                row = {"n": int(value) if value.isdigit() else value, "pid": os.getpid(),
                       "own_port": try_connect(socket.AF_INET, "127.0.0.1", tls, timeout=1),
                       "netns": try_connect(socket.AF_INET, NS4, NS_TCP_PORT, timeout=1)}
                os.write(w, json.dumps(row, sort_keys=True).encode())
                os._exit(0)
            os.close(w)
            with os.fdopen(r) as f:
                line = f.read()
            os.waitpid(pid, 0)
            with open(args.out, "a") as f:
                f.write(line + "\n")
        time.sleep(0.1)
    jprint(event="done")


def wait_closed(s, limit):
    """Seconds until the peer closes `s` (EOF or reset), or 'still-open' after `limit` seconds."""
    t0 = time.time()
    s.settimeout(limit)
    try:
        data = s.recv(1)
        how = "eof" if data == b"" else "data"
    except socket.timeout:
        how = "still-open"
    except OSError as e:
        how = outcome_of(e)
    return {"how": how, "closed_after": round(time.time() - t0, 2)}


def probe_header_timeout(args):
    fam = socket.AF_INET6 if ":" in args.addr else socket.AF_INET
    s = socket.socket(fam, socket.SOCK_STREAM)
    s.settimeout(3)
    try:
        s.connect((args.addr, args.port))
    except Exception as e:  # noqa: BLE001
        jprint(event="header-timeout", connect=outcome_of(e))
        return
    jprint(event="header-timeout", connect="connected", **wait_closed(s, args.wait))


def probe_conn_limit(args):
    tls = app_ports(args.app)[0]
    targets = [(socket.AF_INET, "127.0.0.1", tls), (socket.AF_INET, "127.0.0.1", tls + 1),
               (socket.AF_INET6, "::1", tls), (socket.AF_INET6, "::1", tls + 1)]
    socks, errors = [], []
    for i in range(16):
        fam, addr, port = targets[i % 4]
        s = socket.socket(fam, socket.SOCK_STREAM)
        s.settimeout(2)
        try:
            s.connect((addr, port))
            socks.append(s)
        except Exception as e:  # noqa: BLE001
            errors.append([addr, port, outcome_of(e)])
    time.sleep(0.5)

    def still_open():
        n = 0
        for s in socks:
            p = select.poll()
            p.register(s, select.POLLIN | select.POLLRDHUP | select.POLLHUP)
            if not p.poll(0):
                n += 1
        return n
    before = still_open()
    s17 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s17.settimeout(2)
    try:
        s17.connect(("127.0.0.1", tls))
        seventeenth = {"connect": "connected", **wait_closed(s17, 3)}
    except Exception as e:  # noqa: BLE001
        seventeenth = {"connect": outcome_of(e)}
    jprint(event="conn-limit", first16_connected=len(socks), errors=errors, first16_open_before=before,
           seventeenth=seventeenth, first16_open_after=still_open())
    for s in socks + [s17]:
        s.close()


def probe_tcp_flood(args):
    outcomes = {}
    t0 = time.time()
    for _ in range(args.count):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(1)
        try:
            s.connect((args.dst, args.port))
            o = "connected"
        except Exception as e:  # noqa: BLE001
            o = outcome_of(e)
        s.close()
        outcomes[o] = outcomes.get(o, 0) + 1
    jprint(event="tcp-flood", outcomes=outcomes, seconds=round(time.time() - t0, 2))


def probe_mptcp_create(args):
    for fam in (socket.AF_INET, socket.AF_INET6):
        try:
            socket.socket(fam, socket.SOCK_STREAM, 262).close()
            res = "ok"
        except OSError as e:
            res = outcome_of(e)
        jprint(event="mptcp-create", family="inet6" if fam == socket.AF_INET6 else "inet", outcome=res)


# ---------------------------------------------------------------------------------------------------------------
# netns side (root, inside netns "aftest")


def ns_server(args):
    socks = []
    for fam, addr in ((socket.AF_INET, "0.0.0.0"), (socket.AF_INET6, "::")):
        s = socket.socket(fam, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if fam == socket.AF_INET6:
            s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        s.bind((addr, NS_TCP_PORT))
        s.listen(64)
        socks.append(s)
    while True:
        r, _, _ = select.select(socks, [], [])
        for s in r:
            c, _ = s.accept()
            c.close()


def parse_frame(frame):
    """Ethernet frame -> dict with family, src, dst, proto, sport, dport, flags, rthdr; None if not IP."""
    if len(frame) < 14:
        return None
    ethertype = struct.unpack(">H", frame[12:14])[0]
    p = frame[14:]
    info = {}
    if ethertype == 0x0800 and len(p) >= 20:
        ihl = (p[0] & 15) * 4
        info.update(family=4, src=socket.inet_ntoa(p[12:16]), dst=socket.inet_ntoa(p[16:20]), proto=p[9])
        l4 = p[ihl:]
    elif ethertype == 0x86DD and len(p) >= 40:
        info.update(family=6, src=socket.inet_ntop(socket.AF_INET6, p[8:24]), dst=socket.inet_ntop(socket.AF_INET6, p[24:40]))
        nh, l4 = p[6], p[40:]
        while nh in (0, 43, 60) and len(l4) >= 8:
            if nh == 43:
                info["rthdr_type"] = l4[2]
            nh, l4 = l4[0], l4[(l4[1] + 1) * 8:]
        info["proto"] = nh
    else:
        return None
    if info["proto"] in (6, 17) and len(l4) >= 4:
        info["sport"], info["dport"] = struct.unpack(">HH", l4[:4])
        if info["proto"] == 6 and len(l4) >= 14:
            info["tcp_flags"] = l4[13]
    m = re.search(rb"AFTEST-[A-Za-z0-9-]{1,40}", frame)
    if m:
        info["token"] = m.group().decode()
    return info


def sniff(args):
    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(3))
    s.bind((args.iface, 0))
    with open(args.out, "a", buffering=1) as f:
        while True:
            frame = s.recv(65535)
            info = parse_frame(frame)
            if info is not None:
                info["t"] = time.time()
                f.write(json.dumps(info, sort_keys=True) + "\n")


def sniffed(since, until=None, **match):
    """Packets seen on the netns side between since and until that match every key."""
    rows = []
    path = RESULTS + "/sniff.jsonl"
    if not os.path.exists(path):
        return None
    with open(path) as f:
        for line in f:
            try:
                p = json.loads(line)
            except ValueError:
                continue
            if p["t"] < since or (until is not None and p["t"] > until):
                continue
            if all(p.get(k) == v for k, v in match.items()):
                rows.append(p)
    return rows


# ---------------------------------------------------------------------------------------------------------------
# service state


CURL = ["/usr/bin/curl", "-q", "--proxy", "", "--noproxy", "*", "-sS", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "20"]


def unit_show():
    rc, out, _ = run(["systemctl", "show", UNIT, "-p", "MainPID,NRestarts,ActiveState,SubState,ExecMainStatus,ProtectControlGroups"], timeout=15, quiet=True)
    return dict(line.split("=", 1) for line in out.splitlines() if "=" in line)


SOCKET_UNIT = "blackice-appfilter.socket"


def unit_props(unit, props):
    out = run(["systemctl", "show", unit, "-p", props], timeout=15, quiet=True)[1]
    return dict(line.split("=", 1) for line in out.splitlines() if "=" in line)


def harness_reset(case):
    """Before each case: `systemctl reset-failed` on the service and its socket, and start the socket if it is not
    listening. One failure (a start limit hit, finding A3-R1 on 63a38cc) then cannot cascade into later cases. The
    state before is written to the case log, and recorded as OBSERVE when something was failed. Cases that measure
    the start limit itself opt out."""
    svc = unit_props(UNIT, "LoadState,ActiveState,Result,NRestarts")
    if svc.get("LoadState") != "loaded":
        return
    sock = unit_props(SOCKET_UNIT, "ActiveState,Result")
    run(["systemctl", "reset-failed", UNIT, SOCKET_UNIT], timeout=15, quiet=True)
    started = sock.get("ActiveState") != "active"
    if started:
        run(["systemctl", "start", SOCKET_UNIT], timeout=30, quiet=True)
    case.write(f"# harness reset-failed before the case: service {svc}, socket {sock}{'; socket started' if started else ''}\n")
    if svc.get("ActiveState") == "failed" or started:
        record(f"{case.cid}.harness-reset", "harness", "reset-failed before the case found a failed unit (state before recorded)",
               {"service": svc, "socket": sock, "socket_started": started}, "OBSERVE")


def cli(*args, user=OWNER, app=None):
    cmd = [CLI, "app"] + list(args)
    if app is not None:
        cmd = launched(app, cmd)
    return run(as_user(user, cmd), timeout=180)


def cli_status():
    rc, out, err = cli("status")
    return out.strip() or err.strip()


def status_label(text=None):
    """'armed', 'off', 'disarmed_by_reboot', ... from `OK <label> [key=value ...]` (6c849ec prints `OK <label>`)."""
    text = cli_status() if text is None else text
    parts = text.split()
    return parts[1] if len(parts) > 1 and parts[0] == "OK" else text


def status_fields(text):
    return dict(p.split("=", 1) for p in text.split()[2:] if "=" in p)


def time_wait_on_listener_ports():
    """TIME_WAIT sockets on 760-774 (a restart that binds without SO_REUSEADDR fails while they exist)."""
    return run(["/usr/bin/ss", "-tanH", "state", "time-wait", "( sport >= :760 and sport <= :774 )"], timeout=10, quiet=True)[1].strip().splitlines()


def reset_start_limit():
    """Deliberate kills must not trip the unit's StartLimit (the final commit allows 5 starts in 600 s):
    reset-failed clears the start counter before each one. The configured limit is recorded in P3."""
    run(["systemctl", "reset-failed", UNIT], timeout=15)


def receipts():
    rows = []
    if os.path.isdir(STATE_DIR):
        for path in sorted(os.listdir(STATE_DIR)):
            if path.startswith("receipt-") and path.endswith(".jsonl"):
                with open(os.path.join(STATE_DIR, path)) as f:
                    rows += json_lines(f.read())
    return rows


def count_receipts(**match):
    return sum(1 for r in receipts() if all(r.get(k) == v for k, v in match.items()))


def receipt_bytes():
    total = 0
    if os.path.isdir(STATE_DIR):
        for path in os.listdir(STATE_DIR):
            if path.startswith("receipt-"):
                total += os.path.getsize(os.path.join(STATE_DIR, path))
    return total


def journal(name, since):
    rc, out, _ = run(["journalctl", "--no-pager", "-o", "short-iso-precise", "--since", f"@{int(since)}",
                      "-u", UNIT, "-u", "blackice-appfilter.socket", "-u", "blackice-appfilter-bpffs.service"], timeout=30, quiet=True)
    if CURRENT is not None:
        with open(f"{CURRENT.dir}/journal-{name}.txt", "w") as f:
            f.write(out)
    # --since takes whole seconds; keep only lines at or after the exact start, so an earlier case's lines from the
    # same second are not counted here.
    keep = []
    for line in out.splitlines():
        try:
            if datetime.fromisoformat(line.split(" ", 1)[0]).timestamp() >= since:
                keep.append(line)
        except ValueError:
            continue
    return "\n".join(keep)


def ours(rows):
    return [r for r in rows if str(r["name"]).startswith("bi_af_")]


def foreign(rows):
    return sorted((r["cgroup"], r["attach_type"], r["name"]) for r in rows if not str(r["name"]).startswith("bi_af_"))


def hooks_ok(rows):
    """All seven hooks attached once each, at the right cgroups. Returns (ok, summary)."""
    mine = ours(rows)
    user = sorted(r["name"] for r in mine if r["cgroup"].endswith("/user.slice"))
    root = sorted(r["name"] for r in mine if r["cgroup"] in ("/sys/fs/cgroup", "/"))
    ok = user == sorted(USER_HOOKS) and root == sorted(ROOT_HOOKS) and len(mine) == 7
    return ok, {"user.slice": user, "root": root, "total": len(mine)}


def baseline_foreign():
    with open(RESULTS + "/baseline-foreign.json") as f:
        return [tuple(x) for x in json.load(f)]


def systemd_unit_program(row):
    cgroup, _, name = row
    return bool(re.fullmatch(r"/sys/fs/cgroup/system\.slice/[^/]+\.service", cgroup)) and name in ("sd_devices", "sd_fw_egress", "sd_fw_ingress")


def clean_check(prefix):
    """No program, link, pin or listener of ours is left, and foreign attachments equal the baseline."""
    _, data = trees()
    ok = check(f"{prefix}.no-hooks", "cleanup", "no bi_af_ attachment", [r["name"] for r in ours(data["cgroup_tree"])], not ours(data["cgroup_tree"]))
    ok &= check(f"{prefix}.no-programs", "cleanup", "no bi_af_ program loaded", data["bi_af_programs"], data["bi_af_programs"] == [])
    ok &= check(f"{prefix}.no-pins", "cleanup", "bpffs empty or absent", data["pins"], not data["pins"])
    got, base = foreign(data["cgroup_tree"]), baseline_foreign()
    added, removed = sorted(set(got) - set(base)), sorted(set(base) - set(got))
    if got != base and all(systemd_unit_program(row) for row in added + removed):
        # systemd attaches its own sd_devices / sd_fw_* to a service's cgroup when the service starts (polkit.service,
        # D-Bus activated by the first authorization) and detaches them when it stops: not ours, recorded only.
        record(f"{prefix}.foreign-unchanged", "cleanup", "other attachments equal the baseline, apart from systemd's own per-service programs",
               {"added": added, "removed": removed}, "OBSERVE")
    else:
        ok &= check(f"{prefix}.foreign-unchanged", "cleanup", "other attachments equal the baseline", {"added": added, "removed": removed, "all": got},
                    got == base)
    listeners = run(["/usr/bin/ss", "-ltnH", "sport >= :760 and sport <= :774"], timeout=15)[1].strip()
    ok &= check(f"{prefix}.no-listeners", "cleanup", "nothing listens on 760-774", listeners, listeners == "")
    return ok


def armed_check(prefix):
    _, data = trees()
    ok, summary = hooks_ok(data["cgroup_tree"])
    ok = check(f"{prefix}.seven-hooks", "test7", "5 at user.slice + peer4/peer6 at the root", summary, ok)
    status = cli_status()
    ok &= check(f"{prefix}.status", "test7", "OK armed", status, status_label(status) == "armed")
    return ok


CONTROL_SOCKET = "/run/blackice-appfilter/control.sock"


def wake_service():
    """While off, the service exits after each valid request, so a status call cannot hold it up. A root connection
    is refused (NotOwner) and the service keeps serving after a refused request, so its MainPID stays put until the
    next valid request. Leaves one app_filter_control deny receipt; recorded."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    try:
        s.connect(CONTROL_SOCKET)
        reply = s.recv(200).decode(errors="replace").strip()
    finally:
        s.close()
    wait_active()
    pid = unit_show().get("MainPID", "0")
    if CURRENT is not None:
        CURRENT.write(f"# woke the service with a root control connection: reply {reply!r}, MainPID {pid}\n")
        record(f"{CURRENT.cid}.wake", "harness", "root control connection refused NotOwner; the service stays up", {"reply": reply, "main_pid": pid}, "OBSERVE")
    return reply


def main_pid():
    """The service's main pid, starting it through its socket if it is not running. Never 0: `kill -9 0` would
    signal the harness's own process group."""
    if unit_show().get("MainPID", "0") == "0":
        wake_service()
    pid = int(unit_show().get("MainPID", "0"))
    if pid <= 1:
        raise RuntimeError("the service is not running (MainPID 0)")
    return pid


def ensure_service(tag):
    """Lets one product failure not mask the cases after it. If the control socket does not answer, wait until
    no TIME_WAIT socket holds a listener port (up to 75 s), reset-failed both units and start the socket. Recorded
    as a harness recovery; the failure itself stays recorded in the case that caused it."""
    status = cli_status()
    if status.startswith("OK "):
        return True
    tw = time_wait_on_listener_ports()
    end = time.time() + 75
    while time_wait_on_listener_ports() and time.time() < end:
        time.sleep(2)
    run(["systemctl", "reset-failed", UNIT, "blackice-appfilter.socket"], timeout=15)
    run(["systemctl", "start", "blackice-appfilter.socket"], timeout=30)
    after = cli_status()
    record(f"{tag}.harness-recovery", "harness", "service was down before this case: waited for TIME_WAIT to clear, reset-failed, started the socket",
           {"status_before": status, "time_wait_sockets": len(tw), "status_after": after}, "OBSERVE")
    return after.startswith("OK ")


def wait_active(seconds=20):
    end = time.time() + seconds
    while time.time() < end:
        if unit_show().get("ActiveState") == "active":
            return True
        time.sleep(0.3)
    return False


def write_polkit_rule():
    with open(POLKIT_RULE, "w") as f:
        f.write("// VM-only test rule: stands in for the owner typing the admin password.\n"
                "polkit.addRule(function(action, subject) {\n"
                f"  if (action.id == \"org.blackice.appfilter.change\" && subject.user == \"{OWNER}\") return polkit.Result.YES;\n"
                "});\n")
    time.sleep(2)  # polkitd reloads rules on inotify


def rules_listing():
    return run(["/usr/bin/ls", "-la", "/etc/polkit-1/rules.d/"], timeout=10, quiet=True)[1]


def authorized_off():
    """One `app off` with the VM-only polkit rule in place; the rule is removed right after the request."""
    before = rules_listing()
    write_polkit_rule()
    with open(POLKIT_RULE, "rb") as f:
        sha = hashlib.sha256(f.read()).hexdigest()
    cid = CURRENT.cid if CURRENT else "-"
    polkit_before = run(["systemctl", "is-active", "polkit"], timeout=10, quiet=True)[1].strip()
    try:
        rc, out, err = cli("off")
        if rc != 0 and "PolkitUnavailable" in out + err:
            # polkit.service is D-Bus activated and the service's CheckAuthorization does not start it (c592f6e's
            # run: inactive until pkttyagent activated it). Record it, start polkit, and retry once.
            polkit_now = run(["systemctl", "is-active", "polkit"], timeout=10, quiet=True)[1].strip()
            run(["systemctl", "start", "polkit"], timeout=30)
            time.sleep(1)
            first = [rc, (out + err).strip()[-300:]]
            rc, out, err = cli("off")
            record(f"{cid}.polkit-unavailable", "L10", "PolkitUnavailable with polkit.service inactive; started it and retried once",
                   {"polkit_before": polkit_before, "polkit_at_failure": polkit_now, "first": first, "retry": [rc, (out + err).strip()[-300:]]},
                   "OBSERVE")
    finally:
        os.remove(POLKIT_RULE)
        time.sleep(2)
    check(f"{cid}.polkit-rule-removed", "L10", "rule present only for this request",
          {"sha256_while_present": sha, "present_now": os.path.exists(POLKIT_RULE)}, not os.path.exists(POLKIT_RULE),
          rules_d_before=before, rules_d_after=rules_listing(), polkit_before=polkit_before)
    return rc, (out + err).strip()


def tagcheck(app, user=OWNER, tagged=True):
    cmd = probe_cmd("tagcheck", "--app", str(app))
    rows = json_lines(run(as_user(user, launched(app, cmd) if tagged else cmd), timeout=30)[1])
    return rows[0] if rows else {}


# ---------------------------------------------------------------------------------------------------------------
# expected outcomes for the listener guard (EXPECTED.md, case group A)

NOT_CONNECTED = "anything but connected"


def h1_expect(tag, kind, port, via):
    """Allowed outcomes for one attempt by a caller with `tag` (0 = untagged)."""
    if via == "mptcp" and tag != 0:
        return {"socket:EPERM"}  # sock_create refuses IPPROTO_MPTCP for tagged sockets
    local = kind != "nonlocal"
    if tag == 0:
        return {"EPERM"} if local else NOT_CONNECTED
    if port in app_ports(tag):
        if kind == "exact":
            return {"connected"}
        if kind == "unspec":
            return {"connected", "EPERM"}  # either is safe: it can only reach this app's own listener
        return NOT_CONNECTED
    return {"EPERM"} if local else NOT_CONNECTED


def h1_ok(expect, outcome):
    return outcome != "connected" if expect == NOT_CONNECTED else outcome in expect


def evaluate_h1(caller, tag, rows, must_be_in):
    who = [r for r in rows if r.get("event") == "whoami"]
    attempts = [r for r in rows if r.get("event") == "h1"]
    done = any(r.get("event") == "done" for r in rows)
    cg = who[0]["cgroup"] if who else "?"
    ok = check(f"{caller}.placement", "harness", f"cgroup contains {must_be_in}", cg, must_be_in in cg, uid=who[0]["uid"] if who else None)
    if not attempts or not done:
        return check(f"{caller}.ran", "harness", "probe ran to the end", f"{len(attempts)} attempts, done={done}", False)
    bad, skipped = [], 0
    for r in attempts:
        if r["via"] == "mptcp" and r["outcome"] in ("socket:EPROTONOSUPPORT", "socket:ENOPROTOOPT"):
            skipped += 1  # MPTCP disabled in this kernel: preflight records it
            continue
        exp = h1_expect(tag, r["kind"], r["port"], r["via"])
        if not h1_ok(exp, r["outcome"]):
            bad.append({"via": r["via"], "spelling": r["spelling"], "port": r["port"], "outcome": r["outcome"],
                        "expect": sorted(exp) if exp != NOT_CONNECTED else exp})
    unspec_own = sorted({r["outcome"] for r in attempts if tag and r["kind"] == "unspec" and r["port"] in app_ports(tag)})
    ok &= check(f"{caller}.matrix", "H1", "every spelling x port 760-774 as in h1_expect", f"{len(bad)} mismatches of {len(attempts)}",
                not bad, mismatches=bad[:60], mptcp_skipped=skipped, tagged_own_port_via_unspecified=unspec_own)
    return ok


# ---------------------------------------------------------------------------------------------------------------
# raw bpf() for the arming-phase stepper (root reads the pinned state map; no bpftool fork per step)

_libc = ctypes.CDLL(None, use_errno=True)
SYS_BPF, BPF_MAP_LOOKUP_ELEM, BPF_OBJ_GET, BPF_F_RDONLY = 321, 1, 7, 1 << 3


def bpf_obj_get(path):
    name = ctypes.create_string_buffer(path.encode())
    attr = ctypes.create_string_buffer(128)
    struct.pack_into("=QII", attr, 0, ctypes.addressof(name), 0, BPF_F_RDONLY)
    fd = _libc.syscall(SYS_BPF, BPF_OBJ_GET, attr, 128)
    return fd if fd >= 0 else None


def read_phase(fd):
    key = ctypes.create_string_buffer(4)
    value = ctypes.create_string_buffer(64)
    attr = ctypes.create_string_buffer(128)
    struct.pack_into("=I4xQQQ", attr, 0, fd, ctypes.addressof(key), ctypes.addressof(value), 0)
    if _libc.syscall(SYS_BPF, BPF_MAP_LOOKUP_ELEM, attr, 128) != 0:
        return None
    return struct.unpack_from("=I", value, 0)[0]


# ---------------------------------------------------------------------------------------------------------------
# netns

def netns_up():
    if not os.path.exists(f"/run/netns/{NETNS}"):
        cmds = [
            ["ip", "netns", "add", NETNS],
            ["ip", "link", "add", HOST_IF, "type", "veth", "peer", "name", NS_IF],
            ["ip", "link", "set", NS_IF, "netns", NETNS],
            ["ip", "addr", "add", HOST4 + "/24", "dev", HOST_IF],
            ["ip", "-6", "addr", "add", HOST6 + "/64", "dev", HOST_IF, "nodad"],
            ["ip", "link", "set", HOST_IF, "up"],
            ["ip", "-n", NETNS, "link", "set", "lo", "up"],
            ["ip", "-n", NETNS, "addr", "add", NS4 + "/24", "dev", NS_IF],
            ["ip", "-n", NETNS, "-6", "addr", "add", NS6 + "/64", "dev", NS_IF, "nodad"],
        ] + [["ip", "-n", NETNS, "-6", "addr", "add", a + "/64", "dev", NS_IF, "nodad"] for a in NS6_EXTRA] + [
            ["ip", "-n", NETNS, "link", "set", NS_IF, "up"],
        ]
        for c in cmds:
            run(["/usr/sbin/" + c[0]] + c[1:], timeout=10, check=True)
    for unit, cmd in (("aftest-ns-server", ["nsserver"]), ("aftest-sniffer", ["sniff", "--iface", NS_IF, "--out", RESULTS + "/sniff.jsonl"])):
        if run(["systemctl", "is-active", "--quiet", unit], timeout=5)[0] != 0:
            run(["systemd-run", "--quiet", "--collect", "--unit", unit, "-p", f"NetworkNamespacePath=/run/netns/{NETNS}",
                 "/usr/bin/python3", "-I", SELF] + cmd, timeout=15, check=True)
    time.sleep(1)


def ns_connect(addr, port):
    rc, out, _ = run(["/usr/sbin/ip", "netns", "exec", NETNS, "/usr/bin/python3", "-I", SELF, "probe", "connect", "--addr", addr, "--port", str(port), "--timeout", "3"], timeout=30)
    rows = json_lines(out)
    return rows[0]["outcome"] if rows else "no-output"


def background(cmd):
    note(f"$ (background) {' '.join(cmd)}\n")
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    first = p.stdout.readline()
    note(f"  | {first.strip()}\n")
    return p, (json.loads(first) if first.startswith("{") else {"raw": first})


def finish(p):
    out, _ = p.communicate(timeout=60)
    note("".join(f"  | {l}\n" for l in out.splitlines()))
    return json_lines(out)


# ---------------------------------------------------------------------------------------------------------------
# phases: preparation


def phase_preflight(_args):
    with Case("P0-preflight", "VM matches the pinned kernel and is not the demo VM", "pin"):
        facts = {"kernel": os.uname().release, "hostname": socket.gethostname()}
        import hashlib
        with open("/sys/kernel/btf/vmlinux", "rb") as f:
            facts["btf_sha256"] = hashlib.sha256(f.read()).hexdigest()
        for key in ("kernel.io_uring_disabled", "net.mptcp.enabled", "net.ipv4.ip_unprivileged_port_start",
                    "kernel.unprivileged_bpf_disabled", "kernel.yama.ptrace_scope", "net.ipv4.tcp_fastopen",
                    "fs.protected_hardlinks", "kernel.apparmor_restrict_unprivileged_userns"):
            facts[key] = run(["/usr/sbin/sysctl", "-n", key], timeout=5)[1].strip() or "absent"
        facts["rootfs"] = run(["/usr/bin/findmnt", "-n", "-o", "FSTYPE", "/"], timeout=5)[1].strip()
        facts["lsm"] = open("/sys/kernel/security/lsm").read().strip() if os.path.exists("/sys/kernel/security/lsm") else "?"
        save("preflight.json", json.dumps(facts, indent=1, sort_keys=True))
        check("P0.kernel", "pin", PIN_KERNEL, facts["kernel"], facts["kernel"] == PIN_KERNEL)
        check("P0.btf", "pin", PIN_BTF, facts["btf_sha256"], facts["btf_sha256"] == PIN_BTF)
        check("P0.not-demo-vm", "safety", "hostname is not demo-vm", facts["hostname"], facts["hostname"] != "demo-vm")
        check("P0.rootfs", "M4", "ext4 or xfs", facts["rootfs"], facts["rootfs"] in ("ext4", "xfs"))
        return not CURRENT.failed


def phase_provision(_args):
    with Case("P1-provision", "packages, second user, launcher copy, netns, stub resolver", "setup") as case:
        env = dict(os.environ, DEBIAN_FRONTEND="noninteractive")
        pkgs = ["bpftool", "nftables", "polkitd", "libcap2-bin", "cron", "at", "systemd-resolved", "btrfs-progs", "curl", "wget", "iproute2", "dbus-user-session"]
        p = subprocess.run(["apt-get", "install", "-y", "--no-install-recommends"] + pkgs, env=env, capture_output=True, text=True, timeout=900)
        case.write(p.stdout[-4000:] + p.stderr[-2000:])
        if not check("P1.packages", "setup", "apt install rc 0", p.returncode, p.returncode == 0):
            return False
        run(["systemctl", "enable", "--now", "systemd-resolved", "cron", "atd"], timeout=60)
        uid = pwd.getpwnam(OWNER).pw_uid
        run(as_user(OWNER, ["/bin/sh", "-c", f"XDG_RUNTIME_DIR=/run/user/{uid} systemctl --user start dbus.socket"]), timeout=30)
        check("P1.user-bus", "harness", f"/run/user/{uid}/bus exists (for A10)", os.path.exists(f"/run/user/{uid}/bus"), os.path.exists(f"/run/user/{uid}/bus"))
        # Mirror valendebian's values (security's host facts); record any change.
        mirrored = {}
        for key, want in (("kernel.yama.ptrace_scope", "1"), ("kernel.unprivileged_bpf_disabled", "2"),
                          ("net.ipv4.ip_unprivileged_port_start", "1024")):
            have = run(["/usr/sbin/sysctl", "-n", key], timeout=5)[1].strip()
            if have != want:
                run(["/usr/sbin/sysctl", "-w", f"{key}={want}"], timeout=5)
                mirrored[key] = f"{have} -> {want}"
        record("P1.sysctl-mirror", "setup", "VM matches valendebian", mirrored or "no change", "OBSERVE")
        if run(["/usr/bin/id", OTHER], timeout=5)[0] != 0:
            run(["/usr/sbin/useradd", "--create-home", "--shell", "/bin/bash", OTHER], timeout=30, check=True)
        run(["/usr/bin/install", "-d", "-o", "root", "-g", "root", "-m", "0755", LAUNCH_DIR], check=True)
        run(["/usr/bin/install", "-o", "root", "-g", "root", "-m", "0755", "/usr/bin/setsid", LAUNCH_DIR + "/aft-launch"], check=True)
        for user in (OWNER, OTHER):
            d = f"{DROP}/{user}"
            os.makedirs(d, exist_ok=True)
            pw = pwd.getpwnam(user)
            os.chown(d, pw.pw_uid, pw.pw_gid)
            os.chmod(d, 0o700)
        netns_up()
        stub = os.path.realpath("/etc/resolv.conf")
        check("P1.stub", "M2", "/etc/resolv.conf is the resolved stub", stub, stub.endswith("stub-resolv.conf"))
        check("P1.netns", "harness", "netns answers on 9000", ns_reach := try_connect(socket.AF_INET, NS4, NS_TCP_PORT), ns_reach == "connected")
        return not case.failed


def phase_baseline(_args):
    with Case("P2-baseline", "BPF and listener state before setup", "test7") as case:
        _, data = trees()
        save("baseline-foreign.json", json.dumps(foreign(data["cgroup_tree"])))
        record("P2.cgroup-tree", "test7", "recorded", len(data["cgroup_tree"]), "OBSERVE", attachments=data["cgroup_tree"])
        check("P2.no-ours", "setup", "no bi_af_ program", data["bi_af_programs"], data["bi_af_programs"] == [])
        listeners = run(["/usr/bin/ss", "-ltnH", "sport >= :760 and sport <= :774"], timeout=15)[1].strip()
        check("P2.listeners", "setup", "nothing listens on 760-774", listeners, listeners == "")
        return not case.failed


def phase_setup(_args):
    with Case("P3-setup", "reviewed setup script with the reviewed hashes; no BPF at setup", "setup") as case:
        with open(CANDIDATE + "/hashes.env") as f:
            hashes = dict(line.strip().split("=", 1) for line in f if "=" in line)
        rc, out, err = run(["/bin/bash", CANDIDATE + "/scripts/linux-appfilter-setup.sh", OWNER, hashes["BUNDLE_SHA256"], hashes["BINARY_SHA256"]], timeout=300)
        if not check("P3.rc", "setup", 0, rc, rc == 0):
            return False
        limits = run(["systemctl", "show", UNIT, "-p", "Restart", "-p", "RestartUSec", "-p", "StartLimitBurst", "-p", "StartLimitIntervalUSec", "-p", "TasksMax"], timeout=10)[1]
        record("P3.unit-limits", "A3", "recorded (the harness resets the start counter before each deliberate kill)", dict(l.split("=", 1) for l in limits.split()), "OBSERVE")
        caps = run(["/usr/sbin/getcap", "/usr/local/libexec/blackice-linux-appfilter"], timeout=10)[1].strip()
        check("P3.no-file-caps", "setup", "", caps, caps == "")
        check("P3.socket-active", "setup", "active", run(["systemctl", "is-active", "blackice-appfilter.socket"])[1].strip(),
              run(["systemctl", "is-active", "--quiet", "blackice-appfilter.socket"])[0] == 0)
        clean_check("P3.after-setup")
        return not case.failed


def write_policy(path, apps):
    policy = {"version": "blackice.apps/v0", "applications": [
        {"executable": exe, "policy": {"version": "blackice.policy/v0", "network": {"mode": "allowlist", "allow": [host]}}}
        for exe, host in apps]}
    with open(path, "w") as f:
        json.dump(policy, f, indent=2)
    os.chmod(path, 0o644)


def write_policies():
    os.makedirs(ROOT + "/policies", exist_ok=True)
    write_policy(POLICY, [(exe, host) for _, exe, _, host in APPS])
    write_policy(POLICY_HOST, [("/usr/bin/curl", "example.com")])


def arm(name, policy=POLICY):
    since = time.time()
    rc, out, err = cli("on", "--policy", policy)
    journal(name, since)
    if rc == 0:
        with open(WORK + "/last-policy", "w") as f:
            f.write(policy)
    return rc, (out + err).strip()


def phase_arm(_args):
    with Case("P4-arm", "first arming: verifier accepts all programs; seven hooks; launchers are tagged", "test1/test6") as case:
        write_policies()
        # V1 precondition (security): arm only when no TIME_WAIT is left on 760-774 (from any earlier install), so
        # TIME_WAIT seen later comes from this build's own traffic.
        tw, waited = time_wait_on_listener_ports(), 0
        while tw and waited < 90:
            time.sleep(5)
            waited += 5
            tw = time_wait_on_listener_ports()
        save("P4-time-wait-precondition.txt", "ss -tanH state time-wait '( sport >= :760 and sport <= :774 )'\n"
             f"waited {waited} s\n" + "\n".join(tw) + "\n")
        if not check("P4.time-wait-precondition", "V1", "no TIME_WAIT on 760-774 before the first arm", {"waited_s": waited, "rows": tw}, not tw):
            return False
        rc, text = arm("arm")
        if not check("P4.arm", "test1", "OK armed", text, rc == 0 and text.startswith("OK armed")):
            return False
        armed_check("P4")
        unit = unit_show()
        check("P4.protect-control-groups", "test6", "yes (and arming worked)", unit.get("ProtectControlGroups"), unit.get("ProtectControlGroups") == "yes")
        check("P4.on-receipt", "test1", "app_filter_on receipt", count_receipts(event="app_filter_on"), count_receipts(event="app_filter_on") >= 1)
        for app in LAUNCHED:
            got = tagcheck(app)
            check(f"P4.tag-app{app}", "harness", "own listener connects, netns EPERM", got, got.get("own_port") == "connected" and got.get("netns") == "EPERM")
        got = tagcheck(1, tagged=False)
        check("P4.untagged", "harness", "listener EPERM, netns connects", got, got.get("own_port") == "EPERM" and got.get("netns") == "connected")
        return not case.failed


# ---------------------------------------------------------------------------------------------------------------
# A: the root-cgroup listener guard, for every spelling and port


def callers():
    """(case id, title, tag, command, cgroup that must appear)."""
    h1 = probe_cmd("h1")
    rows = [
        ("A01-cron-owner", "cron job of the owner (system.slice)", 0, ("cron", OWNER), "system.slice"),
        ("A02-cron-other-user", "cron job of another user (system.slice)", 0, ("cron", OTHER), "system.slice"),
        ("A03-at-owner", "at job of the owner (system.slice)", 0, ("at", OWNER), "system.slice"),
        ("A04-system-service-owner", "system service running as the owner", 0,
         ["systemd-run", "--quiet", "--wait", "--collect", "--pipe", "-p", f"User={OWNER}"] + h1, "system.slice"),
        ("A05-system-service-root", "system service running as root", 0, ["systemd-run", "--quiet", "--wait", "--collect", "--pipe"] + h1, "system.slice"),
        ("A06-other-user", "another user's session process (user.slice)", 0, as_user(OTHER, h1), "user.slice"),
        ("A07-other-user-listed-exec", "another user running a listed launcher stays untagged", 0, as_user(OTHER, launched(1, h1)), "user.slice"),
        ("A08-owner-untagged", "the owner's untagged process", 0, as_user(OWNER, h1), "user.slice"),
        ("A09-root-user-slice", "root inside user.slice", 0, h1, "user.slice"),
        ("A10-user-service-owner", "the owner's systemd --user service", 0,
         as_user(OWNER, ["/bin/sh", "-c", f"XDG_RUNTIME_DIR=/run/user/{pwd.getpwnam(OWNER).pw_uid} exec systemd-run --quiet --wait --collect --pipe --user "
                         + " ".join(h1)]), "user@"),
    ]
    rows += [(f"A1{i}-tagged-app{a}", f"tagged app {a}: own listener only", a, as_user(OWNER, launched(a, h1)), "user.slice")
             for i, a in enumerate(LAUNCHED, start=1)]
    return rows


def scheduled(kind, user):
    """Runs the H1 probe from cron or at as `user` and waits for its output."""
    out_path, once = f"{DROP}/{user}/h1-{kind}.jsonl", f"{DROP}/{user}/h1-{kind}.started"
    for path in (out_path, once):
        if os.path.isdir(path):
            os.rmdir(path)
        elif os.path.exists(path):
            os.remove(path)
    # mkdir is the once-guard: a second cron firing must not truncate the first run's output
    job = f"mkdir {once} 2>/dev/null && /usr/bin/python3 -I {SELF} probe h1 > {out_path} 2>&1\n"
    if kind == "cron":
        run(["/usr/bin/crontab", "-u", user, "-"], input="* * * * * " + job, check=True)
    else:
        run(as_user(user, ["/usr/bin/at", "now"]), input=job, check=True)
    end = time.time() + 150
    rows = []
    while time.time() < end:
        if os.path.exists(out_path):
            rows = json_lines(open(out_path).read())
            if any(r.get("event") == "done" for r in rows):
                break
        time.sleep(2)
    if kind == "cron":
        run(["/usr/bin/crontab", "-u", user, "-r"])
    note(f"  (job output: {len(rows)} lines from {out_path})\n")
    return rows


def phase_guard(_args):
    ok = True
    for cid, title, tag, cmd, cg in callers():
        with Case(cid, title, "H1") as case:
            if isinstance(cmd, tuple):
                rows = scheduled(*cmd)
            else:
                rc, out, err = run(cmd, timeout=600, quiet=True)
                with open(case.dir + "/probe.jsonl", "w") as f:
                    f.write(out + ("\n# stderr\n" + err if err.strip() else ""))
                rows = json_lines(out)
            evaluate_h1(cid, tag, rows, cg)
            ok &= not case.failed
    with Case("A20-mptcp-create-tagged", "tagged MPTCP sockets are refused at creation", "test5") as case:
        rows = json_lines(run(as_user(OWNER, launched(1, probe_cmd("mptcp-create"))), timeout=30)[1])
        outcomes = [r.get("outcome") for r in rows]
        if outcomes and all(o in ("EPROTONOSUPPORT", "ENOPROTOOPT") for o in outcomes):
            record("A20.mptcp", "test5", "EPERM", outcomes, "SKIP")
        else:
            check("A20.mptcp", "test5", "EPERM for inet and inet6", outcomes, len(rows) == 2 and all(o == "EPERM" for o in outcomes))
        record("A20.refusal-receipts", "H1", "listener_peer refusals receipted", sum(1 for r in receipts() if "listener_peer" in json.dumps(r)), "OBSERVE")
        ok &= not case.failed
    return ok


# ---------------------------------------------------------------------------------------------------------------
# B, C: tagged sockets stay on lo (M2)


def phase_inbound(_args):
    ok = True
    for cid, tag, bind, port, dst in (
        ("B01-inbound-v4-tagged", 1, "0.0.0.0", 18080, HOST4), ("B02-inbound-v6-tagged", 1, "::", 18082, HOST6),
        ("B03-inbound-autobind-tagged", 1, "none", 0, HOST4), ("B04-inbound-v4-control", 0, "0.0.0.0", 18081, HOST4),
        ("B05-inbound-v6-control", 0, "::", 18083, HOST6), ("B06-inbound-autobind-control", 0, "none", 0, HOST4),
    ):
        with Case(cid, f"connect from another netns to a {'tagged' if tag else 'untagged'} listener on {bind}", "M2") as case:
            cmd = probe_cmd("listen", "--bind", bind, "--port", str(port), "--seconds", "6")
            p, first = background(as_user(OWNER, launched(tag, cmd) if tag else cmd))
            res = ns_connect(dst, first["port"]) if "port" in first else "listen-failed"
            rows = finish(p)
            accepted = next((r.get("accepted") for r in rows if r.get("event") == "done"), None)
            if tag:
                check(cid, "M2", "netns cannot connect; listener bound to lo; nothing accepted", [res, first.get("bound_device"), accepted],
                      res != "connected" and first.get("bound_device") == "lo" and not accepted)
            else:
                check(cid, "M2 control", "netns connects", res, res == "connected")
            ok &= not case.failed
    with Case("B07-accepted-inherits-lo", "a tagged listener's accepted sockets are bound to lo", "M2") as case:
        p, first = background(as_user(OWNER, launched(1, probe_cmd("listen", "--bind", "127.0.0.1", "--port", "18084", "--seconds", "3"))))
        time.sleep(0.3)
        client = try_connect(socket.AF_INET, "127.0.0.1", 18084, timeout=2)
        rows = finish(p)
        accepted = next((r.get("accepted") for r in rows if r.get("event") == "done"), []) or []
        check("B07", "M2", "accepted socket bound to lo", [client, accepted], client == "connected" and bool(accepted) and all(a["bound_device"] == "lo" for a in accepted))
        ok &= not case.failed
    return ok


def phase_bind(_args):
    ok = True
    with Case("C01-bindtodevice-tagged", "tagged sockets start on lo; moving them gives EPERM", "M2") as case:
        for r in json_lines(run(as_user(OWNER, launched(1, probe_cmd("bindtodevice", "--iface", HOST_IF))), timeout=30)[1]):
            check(f"C01.{r['type']}", "M2", "initial lo; every change EPERM; still lo", r,
                  r["initial"] == "lo" and all(r[k] == "EPERM" for k in ("set_iface", "set_empty", "ifindex_iface", "ifindex_zero")) and r["final"] == "lo")
        ok &= not case.failed
    with Case("C02-bindtodevice-control", "untagged sockets are unbound and may bind", "M2 control") as case:
        for r in json_lines(run(as_user(OWNER, probe_cmd("bindtodevice", "--iface", HOST_IF)), timeout=30)[1]):
            check(f"C02.{r['type']}", "M2 control", "initial unbound; set_iface ok", [r["initial"], r["set_iface"]], r["initial"] == "" and r["set_iface"] == "ok")
        ok &= not case.failed
    with Case("C03-pktinfo", "IP_PKTINFO / IPV6_PKTINFO naming another interface reach nothing", "M2") as case:
        t0 = time.time()
        rows = json_lines(run(as_user(OWNER, launched(1, probe_cmd("pktinfo", "--iface", HOST_IF, "--dst4", "127.0.0.53", "--dst6", "::ffff:127.0.0.53", "--port", "53", "--token", "AFTEST-PKTINFO-T"))), timeout=30)[1])
        rows_c = json_lines(run(as_user(OWNER, probe_cmd("pktinfo", "--iface", HOST_IF, "--dst4", NS4, "--dst6", "::ffff:" + NS4, "--port", "9", "--token", "AFTEST-PKTINFO-C")), timeout=30)[1])
        time.sleep(1)
        seen = sniffed(t0) or []
        seen_t = [p for p in seen if p.get("token", "").startswith("AFTEST-PKTINFO-T")]
        seen_c = [p for p in seen if p.get("token", "").startswith("AFTEST-PKTINFO-C")]
        check("C03.tagged", "M2", "no packet with the tagged token on the veth", {"send": rows, "seen": len(seen_t)}, not seen_t)
        check("C03.control", "sniffer", "control token seen (the sniffer works)", {"send": rows_c, "seen": len(seen_c)}, bool(seen_c))
        ok &= not case.failed
    return ok


# ---------------------------------------------------------------------------------------------------------------
# D: segment routing header (M3)


def phase_srh(_args):
    ok = True
    with Case("D01-srh-control", "untagged SRH connect reaches its first hop (the path works)", "M3 control") as case:
        t0 = time.time()
        rows = json_lines(run(as_user(OWNER, probe_cmd("srh", "--segment", NS6, "--dst", "2001:db8::1", "--port", "9101")), timeout=30)[1])
        time.sleep(1)
        seen = [p for p in (sniffed(t0) or []) if p.get("dst") == NS6 and p.get("rthdr_type") == 4]
        check("D01", "sniffer", "SYN with a type-4 routing header seen at fd99::2", {"probe": rows, "seen": len(seen)}, bool(seen))
        ok &= not case.failed
    for (seg, port), cid in zip(zip(NS6_EXTRA, (443, 80, 9)), ("D02-srh-tagged-443", "D03-srh-tagged-80", "D04-srh-tagged-9")):
        with Case(cid, f"tagged SRH connect to port {port} fails and reaches nothing", "M3") as case:
            t0 = time.time()
            rows = json_lines(run(as_user(OWNER, launched(1, probe_cmd("srh", "--segment", seg, "--dst", "2001:db8::1", "--port", str(port)))), timeout=30)[1])
            time.sleep(1)
            seen = [p for p in (sniffed(t0) or []) if p.get("dst") == seg]
            r = rows[0] if rows else {}
            check(cid, "M3", "connect fails; nothing reaches the first hop", {"probe": r, "seen": len(seen)}, bool(r) and r.get("connect") != "connected" and not seen)
            ok &= not case.failed
    with Case("D05-ipv4-lsrr", "IPv4 source routing option (informational)", "M3") as case:
        rows = json_lines(run(as_user(OWNER, launched(1, probe_cmd("lsrr", "--hop", NS4))), timeout=30)[1])
        record("D05", "M3", "EPERM unprivileged on 6.12 (security's note)", rows, "OBSERVE")
    return ok


# ---------------------------------------------------------------------------------------------------------------
# E: stub DNS and both redirects


def phase_dns_redirect(_args):
    ok = True
    with Case("E01-stub-dns", "tagged UDP DNS to 127.0.0.53 and its mapped form", "M2") as case:
        rows = json_lines(run(as_user(OWNER, launched(1, probe_cmd("dns"))), timeout=30)[1])
        check("E01", "M2", "answered twice", [r.get("outcome") for r in rows], len(rows) == 2 and all(r.get("outcome") == "answered" for r in rows))
        ok &= not case.failed
    with Case("E02-redirect-sockets", "tagged TCP 443/80 to any address lands on the app's own listeners", "M2") as case:
        rows = json_lines(run(as_user(OWNER, launched(1, probe_cmd("redirect"))), timeout=60)[1])
        want = {(443, 4): ["127.0.0.1", 760], (80, 4): ["127.0.0.1", 761], (443, 6): ["::1", 760], (80, 6): ["::1", 761],
                (443, "m"): ["::ffff:127.0.0.1", 760], (80, "m"): ["::ffff:127.0.0.1", 761]}
        check("E02.count", "M2", 6, len(rows), len(rows) == 6)
        for r in rows:
            fam = "m" if r["dst"].startswith("::ffff:") else (6 if ":" in r["dst"] else 4)
            exp = want[(r["port"], fam)]
            check(f"E02.{r['dst']}:{r['port']}", "M2", ["connected", exp], [r.get("outcome"), r.get("peer")], r.get("outcome") == "connected" and r.get("peer") == exp)
        ok &= not case.failed
    curl = ["/usr/bin/curl", "-q", "--proxy", "", "--noproxy", "*", "-sS", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "20"]
    wget = ["/usr/bin/wget", "--no-config", "--no-proxy", "--tries=1", "--timeout=15", "-qO", "/dev/null"]
    with Case("E03-redirect-apps", "real HTTPS/HTTP through the proxy: allowed and refused names", "M2") as case:
        for label, cmd, expect_ok in (
            ("curl-https-allowed", curl + ["https://example.com/"], True), ("curl-http-allowed", curl + ["http://example.com/"], True),
            ("curl-https-refused", curl + ["https://example.org/"], False), ("wget-https-allowed", wget + ["https://example.org/"], True),
            ("wget-https-refused", wget + ["https://example.com/"], False),
        ):
            rc, out, err = run(as_user(OWNER, cmd), timeout=40)
            good = (rc == 0 and (out.strip() == "200" or not label.startswith("curl"))) if expect_ok else rc != 0
            check(f"E03.{label}", "M2", "succeeds" if expect_ok else "fails", [rc, out.strip(), err.strip()[:160]], good)
        rc, out, err = run(as_user(OWNER, curl + ["-6", "https://example.com/"]), timeout=40)
        record("E03.curl-ipv6", "M2", "200 if example.com has AAAA (the proxy dials the name itself)", [rc, out.strip(), err.strip()[:160]], "OBSERVE")
        rec = receipts()
        record("E03.receipts", "M2", "app_filter decisions for example.com/example.org",
               [{k: r.get(k) for k in ("event", "host", "app_id", "verdict", "reason")} for r in rec if r.get("point") == "app_filter" and r.get("host")][-12:], "OBSERVE")
        ok &= not case.failed
    return ok


# ---------------------------------------------------------------------------------------------------------------
# F, G: restart, kill-then-fork, off, kill at each arming phase, teardown


def phase_restart(_args):
    ok = True
    curl = ["/usr/bin/curl", "-q", "--proxy", "", "--noproxy", "*", "-sS", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "20", "https://example.com/"]
    with Case("F01-crash-restart", "SIGKILL the service: pins hold all seven hooks; systemd restarts it armed", "test7") as case:
        before = cgroup_attachments()
        reset_start_limit()
        pid = main_pid()
        tw = time_wait_on_listener_ports()
        record("F01.time-wait-before", "test7", "TIME_WAIT sockets on the listener ports at the kill", len(tw), "OBSERVE", sample=tw[:5])
        restarts, since = int(unit_show().get("NRestarts", "0")), time.time()
        run(["/usr/bin/kill", "-9", str(pid)])
        tagged = json_lines(run(as_user(OWNER, launched(1, probe_cmd("connect", "--addr", "1.1.1.1", "--port", "443", "--timeout", "1"))), timeout=20)[1])
        down = cgroup_attachments()
        check("F01.pins-hold", "test7", "same seven attachment ids while down", sorted(r["id"] for r in ours(down)),
              sorted(r["id"] for r in ours(down)) == sorted(r["id"] for r in ours(before)) and len(ours(down)) == 7)
        record("F01.tagged-while-down", "test7", "not connected while the listeners are gone (may race RestartSec=1)", tagged, "OBSERVE")
        active = wait_active()
        time.sleep(2)
        unit = unit_show()
        check("F01.restarted", "test7", "active and NRestarts+1", [unit.get("ActiveState"), unit.get("NRestarts")],
              active and int(unit.get("NRestarts", "0")) == restarts + 1)
        armed_check("F01")
        check("F01.restart-receipt", "test7", "app_filter_restart receipt", count_receipts(event="app_filter_restart"), count_receipts(event="app_filter_restart") >= 1)
        rc, out, _ = run(as_user(OWNER, curl), timeout=40)
        check("F01.works", "test7", "curl 200 after the restart", [rc, out.strip()], rc == 0 and out.strip() == "200")
        text = journal("crash", since)
        record("F01.restart-errors", "test7", "service errors after the kill (journal-crash.txt)",
               [l for l in text.splitlines() if "blackice app filter:" in l or "start-limit" in l or "Start request repeated" in l][:8], "OBSERVE")
        ok &= not case.failed
    with Case("F02-stop-start", "systemctl stop keeps the pins; the next control call starts it armed", "test7") as case:
        ensure_service("F02")
        before = cgroup_attachments()
        run(["systemctl", "stop", UNIT], timeout=60)
        down = cgroup_attachments()
        check("F02.pins-hold", "test7", "same seven attachment ids while stopped", sorted(r["id"] for r in ours(down)),
              sorted(r["id"] for r in ours(down)) == sorted(r["id"] for r in ours(before)) and len(ours(down)) == 7)
        armed_check("F02")  # the status call socket-activates the service
        ok &= not case.failed
    with Case("F02b-proxy-child-kill", "SIGKILL the proxy child: the service exits, pins hold, tagged traffic fails closed, the restart restores it", "M5") as case:
        ensure_service("F02b")
        reset_start_limit()
        child, kids = proxy_child()
        if check("F02b.child", "M5", "one proxy child", kids, child is not None):
            main, before = main_pid(), cgroup_attachments()
            tw = time_wait_on_listener_ports()
            record("F02b.time-wait-before", "M5", "TIME_WAIT sockets on the listener ports at the kill", len(tw), "OBSERVE", sample=tw[:5])
            restarts, receipts0, since = int(unit_show().get("NRestarts", "0")), count_receipts(event="app_filter_restart"), time.time()
            run(["/usr/bin/kill", "-9", str(child)])
            t0, exited = time.time(), False
            while time.time() - t0 < 5:
                if not os.path.exists(f"/proc/{main}"):
                    exited = True
                    break
                time.sleep(0.01)
            gone_after = round(time.time() - t0, 2)
            state_at_curl = unit_show().get("ActiveState")
            rc, out, err = run(as_user(OWNER, CURL + ["--max-time", "3", "https://example.com/"]), timeout=20)
            down = cgroup_attachments()
            check("F02b.service-exits", "M5", "the loader exits when its proxy child dies", {"exited": exited, "seconds": gone_after}, exited)
            check("F02b.pins-hold", "M5", "same seven attachment ids after the exit", sorted(r["id"] for r in ours(down)),
                  sorted(r["id"] for r in ours(down)) == sorted(r["id"] for r in ours(before)) and len(ours(down)) == 7)
            check("F02b.tagged-curl-fails-closed", "M5", "tagged curl fails while the service is down", [rc, out.strip(), err.strip()[:160], state_at_curl],
                  rc != 0 and state_at_curl != "active")
            active = wait_active()
            time.sleep(2)
            unit = unit_show()
            check("F02b.restarted", "M5", "active and NRestarts+1", [unit.get("ActiveState"), unit.get("NRestarts")], active and int(unit.get("NRestarts", "0")) == restarts + 1)
            armed_check("F02b")
            check("F02b.restart-receipt", "M5", "one more app_filter_restart receipt", [receipts0, count_receipts(event="app_filter_restart")],
                  count_receipts(event="app_filter_restart") >= receipts0 + 1)
            rc, out, _ = run(as_user(OWNER, CURL + ["https://example.com/"]), timeout=40)
            check("F02b.works", "M5", "curl 200 after the restart", [rc, out.strip()], rc == 0 and out.strip() == "200")
            journal("proxy-kill", since)
        ok &= not case.failed
    steps = int(unit_props(UNIT, "RestartSteps").get("RestartSteps", "0") or 0)
    if steps > 0:
        ok &= f02c_backoff(steps)
        ok &= f02d_collision_during_recovery()
        return ok
    with Case("F02c-start-limit", "crash restarts past the start limit: the unit fails, pins and filtering stay; reset-failed restores it", "A3") as case:
        limits = dict(l.split("=", 1) for l in run(["systemctl", "show", UNIT, "-p", "StartLimitBurst", "-p", "StartLimitIntervalUSec"], timeout=10)[1].split())
        burst = int(limits.get("StartLimitBurst", "5"))
        ensure_service("F02c")
        reset_start_limit()
        before, since, kills = cgroup_attachments(), time.time(), []
        for i in range(burst + 2):
            unit = unit_show()
            if unit.get("ActiveState") != "active" or unit.get("MainPID", "0") == "0":
                break
            pid = unit["MainPID"]
            run(["/usr/bin/kill", "-9", pid])
            outcome, t0 = "timeout", time.time()
            while time.time() - t0 < 20:
                u = unit_show()
                if u.get("ActiveState") == "active" and u.get("MainPID") not in (pid, "0"):
                    outcome = "restarted"
                    break
                if u.get("ActiveState") == "failed":
                    outcome = "failed"
                    break
                time.sleep(0.1)
            kills.append({"kill": i + 1, "pid": pid, "outcome": outcome, "seconds": round(time.time() - t0, 2)})
            if outcome != "restarted":
                break
            time.sleep(0.5)
        result = run(["systemctl", "show", UNIT, "-p", "ActiveState", "-p", "Result", "-p", "NRestarts"], timeout=10)[1].split()
        socket_state = run(["systemctl", "show", "blackice-appfilter.socket", "-p", "ActiveState", "-p", "Result"], timeout=10)[1].split()
        # The service's own Result is the reason of its last exit (signal); the refused start shows on the socket
        # (service-start-limit-hit) or, without socket activation, on the unit (start-limit-hit).
        refused = "Result=start-limit-hit" in result or "Result=service-start-limit-hit" in socket_state
        check("F02c.unit-failed", "A3", f"after {burst} restarts the next start is refused: unit failed, start-limit-hit on the unit or socket",
              {"kills": kills, "unit": result, "socket": socket_state}, "ActiveState=failed" in result and refused,
              limits=limits)
        check("F02c.restart-count", "A3", f"{burst} restarts before the refusal", [k["outcome"] for k in kills],
              sum(1 for k in kills if k["outcome"] == "restarted") == burst)
        down = cgroup_attachments()
        check("F02c.pins-hold", "A3", "same seven attachment ids", sorted(r["id"] for r in ours(down)),
              sorted(r["id"] for r in ours(down)) == sorted(r["id"] for r in ours(before)) and len(ours(down)) == 7)
        rc, out, err = run(as_user(OWNER, CURL + ["--max-time", "5", "https://example.com/"]), timeout=20)
        check("F02c.still-filtered", "A3", "tagged curl fails while the unit is failed", [rc, out.strip(), err.strip()[:160]], rc != 0)
        untagged = json_lines(run(as_user(OWNER, probe_cmd("connect", "--addr", "127.0.0.1", "--port", "760")), timeout=20)[1])
        check("F02c.guard-holds", "A3", "untagged 127.0.0.1:760 EPERM (root guard still attached)", untagged, bool(untagged) and untagged[0]["outcome"] == "EPERM")
        run(["systemctl", "reset-failed", UNIT, "blackice-appfilter.socket"], timeout=15)
        run(["systemctl", "start", "blackice-appfilter.socket"], timeout=30)
        armed_check("F02c.recovered")  # `app status` through the socket starts the service again
        rc, out, _ = run(as_user(OWNER, CURL + ["https://example.com/"]), timeout=40)
        check("F02c.works", "A3", "curl 200 after the recovery", [rc, out.strip()], rc == 0 and out.strip() == "200")
        journal("start-limit", since)
        ok &= not case.failed
    return ok


def ids(rows):
    return sorted(r["id"] for r in ours(rows))


def systemd_times(text, needle):
    """Timestamps (epoch seconds) of the journal lines that contain `needle`."""
    out = []
    for line in text.splitlines():
        if needle in line:
            try:
                out.append(datetime.fromisoformat(line.split(" ", 1)[0]).timestamp())
            except ValueError:
                pass
    return out


def wait_new_main(old, limit, t0=None):
    """Waits until the unit is active with a MainPID other than `old`. Returns (outcome, seconds since t0).
    Reads systemd only: a control-socket request would start the service at once and skip the backoff."""
    t0 = time.time() if t0 is None else t0
    while time.time() - t0 < limit:
        u = unit_show()
        if u.get("ActiveState") == "active" and u.get("MainPID") not in (str(old), "0"):
            return "restarted", round(time.time() - t0, 2)
        if u.get("ActiveState") == "failed":
            return "failed", round(time.time() - t0, 2)
        time.sleep(0.1)
    return "timeout", round(time.time() - t0, 2)


def f02c_backoff(steps):
    """A3-R1 fix: crash restarts back off (RestartSec -> RestartMaxDelaySec over RestartSteps) instead of
    stopping at a start limit. steps+1 kills: the delays rise to the maximum, the pins and the filtering stay in
    every gap, and it ends armed."""
    with Case("F02c-backoff", "a crash loop backs off instead of hitting the start limit; pins and filtering stay in every gap", "A3-R1") as case:
        limits = unit_props(UNIT, "Restart,RestartUSec,RestartSteps,RestartMaxDelayUSec,StartLimitBurst,StartLimitIntervalUSec")
        record("F02c.unit-limits", "A3-R1", "recorded", limits, "OBSERVE")
        ensure_service("F02c")
        reset_start_limit()
        before, since, kills = ids(cgroup_attachments()), time.time(), []
        for i in range(steps + 1):
            unit = unit_show()
            if unit.get("ActiveState") != "active" or unit.get("MainPID", "0") == "0":
                break
            pid = unit["MainPID"]
            t_kill = time.time()
            run(["/usr/bin/kill", "-9", pid])
            gap = {"ids_held": ids(cgroup_attachments()) == before and len(before) == 7, "tagcheck": tagcheck(1)}
            outcome, seconds = wait_new_main(pid, 150, t_kill)
            kills.append({"kill": i + 1, "pid": pid, "outcome": outcome, "seconds": seconds, **gap})
            if outcome != "restarted":
                break
            time.sleep(0.5)
        text = journal("backoff", since)
        with open(f"{case.dir}/kills.json", "w") as f:
            json.dump(kills, f, indent=1)
        secs = [k["seconds"] for k in kills]
        check("F02c.all-restarted", "A3-R1", f"{steps + 1} kills, each one restarted (never failed)", [k["outcome"] for k in kills],
              len(kills) == steps + 1 and all(k["outcome"] == "restarted" for k in kills))
        check("F02c.backoff", "A3-R1", "restart delays rise (non-decreasing within 0.5 s) and the last is at least 30 s", secs,
              len(secs) >= 2 and all(b >= a - 0.5 for a, b in zip(secs, secs[1:])) and secs[-1] >= 30)
        check("F02c.no-start-limit", "A3-R1", "no start-limit-hit in the journal", [l for l in text.splitlines() if "start-limit" in l or "repeated too quickly" in l][:4],
              "start-limit" not in text and "repeated too quickly" not in text)
        check("F02c.pins-hold", "A3-R1", "the same seven attachment ids in every gap", [k["ids_held"] for k in kills], bool(kills) and all(k["ids_held"] for k in kills))
        check("F02c.filtering-in-gaps", "A3-R1", "a tagged app gets EPERM to the netns in every gap", [k["tagcheck"].get("netns") for k in kills],
              bool(kills) and all(k["tagcheck"].get("netns") == "EPERM" for k in kills))
        armed_check("F02c")
        rc, out, _ = run(as_user(OWNER, CURL + ["https://example.com/"]), timeout=40)
        check("F02c.works", "A3-R1", "curl 200 after the last restart", [rc, out.strip()], rc == 0 and out.strip() == "200")
        return not case.failed


def f02d_collision_during_recovery():
    """Security's case: armed, the loader is killed, and root takes 127.0.0.1:765 before the restart. Each restart
    is refused (exit 125) and retried with rising delays while the pins and the filtering hold; once root releases
    the port, the next retry re-arms within 60 s."""
    with Case("F02d-collision-during-recovery", "a live listener on 127.0.0.1:765 during an armed crash recovery: retries back off, pins and filtering hold, re-armed within 60 s of the release", "A3-R1") as case:
        ensure_service("F02d")
        reset_start_limit()
        before, since, receipts0 = ids(cgroup_attachments()), time.time(), count_receipts(event="app_filter_restart")
        pid = main_pid()
        # The holder retries bind() until the service's listeners are gone (SO_REUSEADDR: TIME_WAIT may remain;
        # a live listener still refuses it).
        holder = subprocess.Popen(["/usr/bin/python3", "-I", "-c",
            "import socket,time,errno\n"
            "s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); t=time.time()\n"
            "while True:\n"
            "    try:\n        s.bind(('127.0.0.1', 765)); break\n"
            "    except OSError as e:\n"
            "        if e.errno != errno.EADDRINUSE or time.time()-t > 10: print('bind failed', e, flush=True); raise SystemExit(1)\n"
            "        time.sleep(0.002)\n"
            "s.listen(4); print('listening', round(time.time()-t, 3), flush=True); time.sleep(300)"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        time.sleep(0.3)
        run(["/usr/bin/kill", "-9", str(pid)])
        line = holder.stdout.readline().strip()
        check("F02d.holder", "harness", "root bound 127.0.0.1:765 after the loader died, before the restart", line, line.startswith("listening"))
        samples, t_hold = [], time.time()
        while time.time() - t_hold < 25:
            samples.append({"t": round(time.time() - t_hold, 1), "ids_held": ids(cgroup_attachments()) == before and len(before) == 7,
                            "netns": tagcheck(1).get("netns"), "unit": unit_show().get("ActiveState")})
            time.sleep(2)
        held_text = journal("held", since)
        refused = held_text.count("status=125")
        starts = systemd_times(held_text, "Started blackice-appfilter.service")
        gaps = [round(b - a, 2) for a, b in zip(starts, starts[1:])]
        holder.kill()
        holder.wait()
        t_release = time.time()
        with open(f"{case.dir}/samples.json", "w") as f:
            json.dump(samples, f, indent=1)
        check("F02d.retries", "A3-R1", "restarts refused (exit 125) and retried at least twice while the port was held", {"refused": refused, "starts": len(starts)}, refused >= 2)
        check("F02d.backoff", "A3-R1", "the gaps between retries rise", gaps, len(gaps) >= 2 and all(b >= a - 0.5 for a, b in zip(gaps, gaps[1:])) and gaps[-1] > gaps[0])
        check("F02d.pins-hold", "A3-R1", "the same seven attachment ids while the port was held", [x["ids_held"] for x in samples], all(x["ids_held"] for x in samples))
        check("F02d.filtering-holds", "A3-R1", "a tagged app gets EPERM to the netns while the port was held", [x["netns"] for x in samples], all(x["netns"] == "EPERM" for x in samples))
        # systemd only until it is back: an `app status` here would socket-start the service and skip the backoff.
        up, recovered = False, None
        while time.time() - t_release < 75:
            u = unit_show()
            if u.get("ActiveState") == "active" and u.get("SubState") == "running":
                recovered = round(time.time() - t_release, 1)
                time.sleep(1.5)
                again = unit_show()
                if again.get("ActiveState") == "active" and again.get("MainPID") == u.get("MainPID"):
                    up = True
                    break
            time.sleep(0.5)
        armed = up and status_label() == "armed"
        text = journal("recovery", since)
        check("F02d.recovered", "A3-R1", "armed again within 60 s of the release", {"armed": armed, "seconds_after_release": recovered}, armed and recovered <= 60)
        check("F02d.no-start-limit", "A3-R1", "no start-limit-hit", [l for l in text.splitlines() if "start-limit" in l][:4], "start-limit" not in text and "repeated too quickly" not in text)
        armed_check("F02d")
        check("F02d.restart-receipt", "A3-R1", "one more app_filter_restart receipt", [receipts0, count_receipts(event="app_filter_restart")], count_receipts(event="app_filter_restart") >= receipts0 + 1)
        rc, out, _ = run(as_user(OWNER, CURL + ["https://example.com/"]), timeout=40)
        check("F02d.works", "A3-R1", "curl 200 after the recovery", [rc, out.strip()], rc == 0 and out.strip() == "200")
        return not case.failed


LISTENER_TEST = ROOT + "/bin/listener-vm-test"  # Codex's VM socket test (63a38cc), built on the host without running it


def proxy_closed_connections(n=3, app=1):
    """Tagged connections to the app's own TLS listener that send nothing. The proxy closes them at its 5 s header
    deadline, so the proxy closes first and TIME_WAIT lands on the listener port (curl closes first, which leaves
    TIME_WAIT on its own ephemeral port instead)."""
    tls = app_ports(app)[0]
    procs = [subprocess.Popen(as_user(OWNER, launched(app, probe_cmd("header-timeout", "--addr", "127.0.0.1", "--port", str(tls), "--wait", "10"))),
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True) for _ in range(n)]
    rows = []
    for p in procs:
        try:
            out, _ = p.communicate(timeout=40)
        except subprocess.TimeoutExpired:
            p.kill()
            out, _ = p.communicate()
        rows += json_lines(out)
    return rows


def traffic(n=6):
    """Proxied TCP so the listener ports hold TIME_WAIT: proxy-closed idle connections, n allowed requests and
    one refused name."""
    out = [{"proxy_closed": proxy_closed_connections()}]
    for _ in range(n):
        rc, o, _ = run(as_user(OWNER, CURL + ["https://example.com/"]), timeout=40, quiet=True)
        out.append([rc, o.strip()])
    rc, o, _ = run(as_user(OWNER, CURL + ["https://example.org/"]), timeout=40, quiet=True)
    out.append([rc, o.strip()])
    return out


def listener_errors(since):
    text = journal("v1", since)
    return [l for l in text.splitlines() if "ListenerPortOccupied" in l or "listener_unavailable" in l or "Start request repeated" in l][:8]


def restart_under_load(cid, title, how):
    with Case(cid, title, "V1") as case:
        ensure_service(cid)
        reset_start_limit()
        made = traffic()
        tw_before = time_wait_on_listener_ports()
        save(f"cases/{cid}/time-wait-before.txt", "\n".join(tw_before) + "\n")
        check(f"{cid}.time-wait-present", "V1", "TIME_WAIT on 760-774 before the restart (else the case proves nothing)",
              len(tw_before), bool(tw_before), traffic=made)
        restarts, receipts0, since, main = int(unit_show().get("NRestarts", "0")), count_receipts(event="app_filter_restart"), time.time(), main_pid()
        if how == "proxy-child":
            child, kids = proxy_child()
            run(["/usr/bin/kill", "-9", str(child)])
        elif how == "loader":
            run(["/usr/bin/kill", "-9", str(main)])
        else:
            run(["systemctl", "restart", UNIT], timeout=60)
        active = wait_active()
        tw_rearm = time_wait_on_listener_ports()
        save(f"cases/{cid}/time-wait-at-rearm.txt", "\n".join(tw_rearm) + "\n")
        time.sleep(2)
        unit = unit_show()
        check(f"{cid}.time-wait-at-rearm", "V1", "ss state time-wait on 760-774 non-empty when it re-armed (saved)", len(tw_rearm), bool(tw_rearm))
        if how == "systemctl":
            check(f"{cid}.restarted", "V1", "active again with a new MainPID", [unit.get("ActiveState"), main, unit.get("MainPID")],
                  active and unit.get("MainPID") not in ("0", str(main)))
        else:
            check(f"{cid}.restarted", "V1", "active and NRestarts+1", [unit.get("ActiveState"), unit.get("NRestarts")],
                  active and int(unit.get("NRestarts", "0")) == restarts + 1)
        armed_check(cid)
        check(f"{cid}.restart-receipt", "V1", "one more app_filter_restart receipt", [receipts0, count_receipts(event="app_filter_restart")],
              count_receipts(event="app_filter_restart") >= receipts0 + 1)
        errors = listener_errors(since)
        check(f"{cid}.no-listener-errors", "V1", "no ListenerPortOccupied / listener_unavailable / start-limit in the journal", errors, not errors)
        curl_pair(cid, filtered=True)
        return not case.failed


def listener_table():
    rows = run(["/usr/bin/ss", "-ltnpH", "( sport >= :760 and sport <= :774 )"], timeout=10)[1].strip().splitlines()
    table = []
    for line in rows:
        parts = line.split()
        local = parts[3]
        addr, port = local.rsplit(":", 1)
        pids = re.findall(r"pid=(\d+)", line)
        table.append({"addr": addr, "port": int(port), "pids": pids, "line": line})
    return table


def phase_v1(_args):
    ok = True
    with Case("V1a-socket-test", "Codex's VM socket test: IPv4/IPv6 TIME_WAIT rebind and live-collision refusal (expects 2/2)", "V1") as case:
        if check("V1a.present", "harness", "listener-vm-test installed (built on the host from 63a38cc, sha recorded in provenance)",
                 os.path.exists(LISTENER_TEST), os.path.exists(LISTENER_TEST)):
            with open(LISTENER_TEST, "rb") as f:
                record("V1a.sha256", "V1", "ef9cebf2... (Codex's reproduced build)", hashlib.sha256(f.read()).hexdigest(), "OBSERVE")
            record("V1a.sys-vendor", "V1", "QEMU (the test refuses to run elsewhere)", open("/sys/class/dmi/id/sys_vendor").read().strip(), "OBSERVE")
            rc, out, err = run(as_user(OWNER, [LISTENER_TEST]), timeout=120)
            text = out + err
            check("V1a.result", "V1", "exit 0, 2 of 2 tests passed", [rc, text.strip()[-400:]], rc == 0 and ("2 passed" in text or "All 2 tests passed" in text))
        ok &= not case.failed
    ok &= restart_under_load("V1b1-proxy-kill-under-load", "kill the proxy child after TCP traffic: it re-arms with TIME_WAIT present", "proxy-child")
    ok &= restart_under_load("V1b2-loader-kill-under-load", "kill the loader after TCP traffic: it re-arms with TIME_WAIT present", "loader")
    ok &= restart_under_load("V1b3-systemctl-restart-under-load", "systemctl restart after TCP traffic: it re-arms with TIME_WAIT present", "systemctl")
    with Case("V1e-off-rearm-after-traffic", "authorized off right after TCP traffic, then arm again at once", "V1") as case:
        ensure_service("V1e")
        made = traffic()
        rc, text = authorized_off()
        check("V1e.off", "L10", "OK off", text, rc == 0 and text == "OK off")
        tw = time_wait_on_listener_ports()
        save("cases/V1e-off-rearm-after-traffic/time-wait-at-rearm.txt", "\n".join(tw) + "\n")
        check("V1e.time-wait-at-rearm", "V1", "TIME_WAIT on 760-774 when arming again (saved)", len(tw), bool(tw), traffic=made)
        since = time.time()
        rc, text = arm("v1e-rearm")
        check("V1e.rearm", "V1", "OK armed at once, no ListenerPortOccupied", text, rc == 0 and text.startswith("OK armed"))
        check("V1e.no-listener-errors", "V1", "no listener errors in the journal", listener_errors(since), not listener_errors(since))
        armed_check("V1e")
        curl_pair("V1e", filtered=True)
        ok &= not case.failed
    for fam, addr in (("v4", "127.0.0.1"), ("v6", "::1")):
        cid = f"V1c-live-collision-{fam}"
        with Case(cid, f"a live listener on {addr} port 765 still makes arming fail, fully rolled back", "V1") as case:
            ensure_service(cid)
            if status_label() == "armed":
                rc, text = authorized_off()
                check(f"{cid}.off", "L10", "OK off", text, rc == 0 and text == "OK off")
            _, before = trees()
            holder = subprocess.Popen(["/usr/bin/python3", "-I", "-c",
                "import socket,sys,time; f=socket.AF_INET6 if ':' in sys.argv[1] else socket.AF_INET; s=socket.socket(f); "
                "s.bind((sys.argv[1], 765)); s.listen(4); print('listening', flush=True); time.sleep(120)", addr],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            first = holder.stdout.readline().strip()
            check(f"{cid}.holder", "harness", f"root holds {addr}:765", first, first == "listening")
            failed0, since = count_receipts(event="app_filter_on_failed"), time.time()
            rc, text = arm(f"{cid}-arm")
            holder.kill()
            holder.wait()
            check(f"{cid}.refused", "V1", "app on refused", [rc, text], rc != 0 and not text.startswith("OK armed"))
            rows = [r for r in receipts() if r.get("event") == "app_filter_on_failed"][failed0:]
            check(f"{cid}.reason", "V1", "app_filter_on_failed with reason listener_unavailable", rows[-3:],
                  any(r.get("reason") == "listener_unavailable" for r in rows))
            status = cli_status()
            check(f"{cid}.status", "V1", "OK off", status, status_label(status) == "off")
            clean_check(cid)
            _, after = trees()
            check(f"{cid}.tree-unchanged", "V1", "bpftool cgroup tree equals the picture before `app on`",
                  {"before": foreign(before["cgroup_tree"]), "after": foreign(after["cgroup_tree"])},
                  foreign(after["cgroup_tree"]) == foreign(before["cgroup_tree"]) and not ours(after["cgroup_tree"]))
            ok &= not case.failed
    with Case("V1d-listener-count", "after arming again: one listener per port and family (30), all the service's", "V1") as case:
        rc, text = arm("v1d-arm")
        check("V1d.arm", "V1", "OK armed", text, rc == 0 and text.startswith("OK armed"))
        table = listener_table()
        save("cases/V1d-listener-count/ss-ltnp.txt", "\n".join(r["line"] for r in table) + "\n")
        service = set(open(f"/sys/fs/cgroup/system.slice/{UNIT}/cgroup.procs").read().split())
        keys = sorted((r["port"], "v6" if r["addr"].startswith("[") or ":" in r["addr"] else "v4") for r in table)
        want = sorted((p, f) for p in range(FIRST_PORT, LAST_PORT + 1) for f in ("v4", "v6"))
        check("V1d.count", "V1", "30 listeners, exactly one per port and family (no SO_REUSEPORT duplicates)",
              {"total": len(table), "duplicates": len(keys) - len(set(keys))}, keys == want)
        owners = sorted({p for r in table for p in r["pids"]})
        check("V1d.owners", "V1", "every listener owned by a process of the service", {"owners": owners, "service": sorted(service)},
              bool(owners) and all(p in service for p in owners) and all(r["pids"] for r in table))
        ok &= not case.failed
    return ok


def hold_port(addr, port=765):
    """Root holds a live listener on addr:port (a stand-in for another program owning a listener port)."""
    holder = subprocess.Popen(["/usr/bin/python3", "-I", "-c",
        "import socket,sys,time; f=socket.AF_INET6 if ':' in sys.argv[1] else socket.AF_INET; s=socket.socket(f); "
        "s.bind((sys.argv[1], int(sys.argv[2]))); s.listen(4); print('listening', flush=True); time.sleep(300)", addr, str(port)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return holder, holder.stdout.readline().strip()


def phase_startlimit(_args):
    """A3-R1: while off, the service is socket-activated once per control request and exits after answering, so
    every request is a start that counts against StartLimitBurst. Runs right after setup, before the first arm."""
    ok = True
    write_policies()
    with Case("A3R1a-status-calls-while-off", "30 `app status` calls by the owner while off; no reset-failed first", "A3-R1", reset=False) as case:
        since = time.time()
        svc0, sock0 = unit_props(UNIT, "ActiveState,Result,NRestarts"), unit_props(SOCKET_UNIT, "ActiveState,Result")
        boot = run(["journalctl", "--no-pager", "-b", "-u", UNIT, "-o", "cat"], timeout=30, quiet=True)[1]
        record("A3R1a.before", "A3-R1", "state before the calls (security: no reset-failed before them)",
               {"service": svc0, "socket": sock0, "service_starts_this_boot": boot.count("Started blackice-appfilter.service")}, "OBSERVE")
        calls, t0 = [], time.time()
        for n in range(1, 31):
            rc, out, err = cli("status")
            calls.append({"n": n, "rc": rc, "out": (out + err).strip()[:160], "t": round(time.time() - t0, 2)})
        with open(f"{case.dir}/calls.json", "w") as f:
            json.dump(calls, f, indent=1)
        bad = [c for c in calls if c["rc"] != 0 or not c["out"].startswith("OK ")]
        first = bad[0]["n"] if bad else None
        svc, sock = unit_props(UNIT, "ActiveState,Result,NRestarts"), unit_props(SOCKET_UNIT, "ActiveState,Result")
        text = journal("status-calls", since)
        check("A3R1a.thirty-calls", "A3-R1", "30 status calls by the owner while off all answer OK",
              {"first_failure": first, "failed_calls": len(bad), "seconds": calls[-1]["t"], "service": svc, "socket": sock,
               "starts_in_journal": text.count("Started blackice-appfilter.service")}, first is None)
        if first is not None:
            record("A3R1a.lockout", "A3-R1", "the first failing call, both units' Result, and systemd's lines",
                   {"call": bad[0], "service": svc, "socket": sock,
                    "systemd": [l for l in text.splitlines() if "repeated too quickly" in l or "start-limit" in l]}, "OBSERVE")
            rc, out, err = cli("on", "--policy", POLICY)
            record("A3R1a.owner-cannot-arm", "A3-R1", "the owner's `app on` while locked out", [rc, (out + err).strip()[:200]], "OBSERVE")
            run(["systemctl", "reset-failed", UNIT, SOCKET_UNIT], timeout=15)
            run(["systemctl", "start", SOCKET_UNIT], timeout=30)
            status = cli_status()
            check("A3R1a.root-recovers", "A3-R1", "root's reset-failed and starting the socket bring status back: OK off", status, status_label(status) == "off",
                  socket_after=unit_props(SOCKET_UNIT, "ActiveState,Result"))
        ok &= not case.failed
    with Case("A3R1b-refused-arm", "a refused arm (root holds 127.0.0.1:765): no start-limit, at most one automatic restart, the socket keeps answering", "A3-R1") as case:
        holder, first_line = hold_port("127.0.0.1")
        check("A3R1b.holder", "harness", "root holds 127.0.0.1:765", first_line, first_line == "listening")
        since, n0 = time.time(), unit_props(UNIT, "NRestarts").get("NRestarts")
        rc, text = arm("a3r1b-arm")
        holder.kill()
        holder.wait()
        check("A3R1b.refused", "V1", "app on refused with ListenerPortOccupied", [rc, text], rc != 0 and "ListenerPortOccupied" in text)
        time.sleep(6)  # RestartSec=1, plus a margin for one restart and its exit
        text_j = journal("refused-arm", since)
        svc, sock = unit_props(UNIT, "ActiveState,Result,NRestarts"), unit_props(SOCKET_UNIT, "ActiveState,Result")
        starts, scheduled = text_j.count("Started blackice-appfilter.service"), text_j.count("Scheduled restart job")
        record("A3R1b.starts", "A3-R1", "service starts and automatic restarts after the refused arm",
               {"starts": starts, "scheduled_restarts": scheduled, "nrestarts": [n0, svc.get("NRestarts")]}, "OBSERVE")
        check("A3R1b.restarts-low", "A3-R1", "at most one automatic restart", scheduled, scheduled <= 1)
        check("A3R1b.no-start-limit", "A3-R1", "no start-limit-hit; the service is not failed and the socket is listening",
              {"service": svc, "socket": sock}, "start-limit" not in text_j and svc.get("ActiveState") != "failed" and sock.get("ActiveState") == "active")
        status = cli_status()
        check("A3R1b.socket-answers", "A3-R1", "status answers OK off", status, status_label(status) == "off")
        ok &= not case.failed
    return ok


def phase_kill_fork(_args):
    trigger, out = f"{DROP}/{OWNER}/fork-trigger", f"{DROP}/{OWNER}/fork-out.jsonl"
    for path in (trigger, out):
        if os.path.exists(path):
            os.remove(path)
    with Case("G01-kill-then-fork", "with the service killed and stopped, forks and execs stay classified", "R2/test7") as case:
        ensure_service("G01")
        p = subprocess.Popen(as_user(OWNER, launched(1, probe_cmd("forker", "--app", "1", "--trigger", trigger, "--out", out))), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            return kill_then_fork(p, trigger, out)
        finally:
            with open(trigger + ".tmp", "w") as f:
                f.write("exit")
            os.chmod(trigger + ".tmp", 0o644)
            os.rename(trigger + ".tmp", trigger)
            try:
                p.communicate(timeout=20)
            except subprocess.TimeoutExpired:
                p.kill()


def kill_then_fork(p, trigger, out):
    """The steps of G01; the caller always stops the forker."""

    def fork_once(n):
        with open(trigger + ".tmp", "w") as f:
            f.write(str(n))
        os.chmod(trigger + ".tmp", 0o644)
        os.rename(trigger + ".tmp", trigger)
        if n == "exit":
            return {}
        end = time.time() + 20
        while time.time() < end:
            rows = json_lines(open(out).read()) if os.path.exists(out) else []
            got = [r for r in rows if r.get("n") == n]
            if got:
                note(f"  fork {n}: {got[0]}\n")
                return got[0]
            time.sleep(0.2)
        return {}

    time.sleep(1)
    up = fork_once(1)
    check("G01.fork-up", "R2", "tagged child: own listener connects, netns EPERM", up, up.get("own_port") == "connected" and up.get("netns") == "EPERM")
    before = cgroup_attachments()
    reset_start_limit()
    run(["/usr/bin/kill", "-9", str(main_pid())])
    run(["systemctl", "stop", UNIT], timeout=60)  # cancels the automatic restart
    check("G01.down", "test7", "unit not active", unit_show().get("ActiveState"), unit_show().get("ActiveState") != "active")
    down = cgroup_attachments()
    check("G01.pins-hold", "test7", "same seven attachment ids", sorted(r["id"] for r in ours(down)),
          sorted(r["id"] for r in ours(down)) == sorted(r["id"] for r in ours(before)) and len(ours(down)) == 7)
    d = fork_once(2)
    check("G01.fork-while-down", "R2", "child still tagged: netns EPERM, own port refused (no listener)", d,
          d.get("netns") == "EPERM" and d.get("own_port") == "ECONNREFUSED")
    e = tagcheck(1)
    check("G01.exec-while-down", "R2", "a new launch is tagged: netns EPERM, own port refused", e, e.get("netns") == "EPERM" and e.get("own_port") == "ECONNREFUSED")
    u = tagcheck(1, tagged=False)
    check("G01.untagged-while-down", "R2", "untagged: listener EPERM, netns connects", u, u.get("own_port") == "EPERM" and u.get("netns") == "connected")
    armed_check("G01.back")  # socket activation brings the service back
    b = fork_once(3)
    check("G01.fork-after", "R2", "tagged child after the restart: own listener connects", b, b.get("own_port") == "connected" and b.get("netns") == "EPERM")
    return not CURRENT.failed


def phase_off(_args):
    ok = True
    with Case("F03-off-authorization", "off is refused without authorization and from a tagged caller", "L10") as case:
        if os.path.exists(POLKIT_RULE):
            os.remove(POLKIT_RULE)
            time.sleep(2)
        ensure_service("F03")
        check("F03.no-rule", "L10", "no aftest rule in rules.d", rules_listing(), not os.path.exists(POLKIT_RULE))
        if not armed_check("F03.pre"):
            return False  # refusals from a dead service would prove nothing
        rc, out, err = cli("off")
        check("F03.unauthorized", "L10", "refused, still armed", [rc, (out + err).strip()], rc != 0)
        rc, out, err = cli("off", app=1)
        check("F03.tagged-caller", "L10", "refused, still armed", [rc, (out + err).strip()], rc != 0)
        write_polkit_rule()  # a tagged caller is refused even when polkit would say yes
        try:
            rc, out, err = cli("off", app=1)
        finally:
            os.remove(POLKIT_RULE)
            time.sleep(2)
        check("F03.tagged-caller-with-rule", "L10", "refused even with the rule, still armed", [rc, (out + err).strip()], rc != 0, rules_d_after=rules_listing())
        armed_check("F03")
        ok &= not case.failed
    with Case("F04-off-detaches-seven", "authorized off detaches exactly our seven hooks", "test7/L10") as case:
        since = time.time()
        rc, text = authorized_off()
        journal("off", since)
        check("F04.off", "L10", "OK off (needs the polkit owner annotation)", text, rc == 0 and text == "OK off")
        clean_check("F04")
        check("F04.off-receipt", "test7", "app_filter_off receipt", count_receipts(event="app_filter_off"), count_receipts(event="app_filter_off") >= 1)
        ok &= not case.failed
    with Case("F05-rearm", "arm again with the six-app policy", "test7") as case:
        rc, text = arm("rearm")
        check("F05.arm", "test7", "OK armed", text, rc == 0 and text.startswith("OK armed"))
        armed_check("F05")
        ok &= not case.failed
    return ok


def kill_at(target, run_slice):
    """Arms while single-stepping the service with SIGSTOP/SIGCONT and SIGKILLs it when the pinned phase equals
    the target. Each step lets the service run for about `run_slice` seconds. If a step jumps past the target, the
    service is let go and the attempt counts as missed (the caller turns it off and tries a shorter slice)."""
    want = PHASES_ARMING[target]
    reset_start_limit()
    pid = main_pid()
    p = subprocess.Popen(as_user(OWNER, [CLI, "app", "on", "--policy", POLICY]), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    fd, seen, last, killed = None, [], None, False
    end = time.time() + 180
    try:
        while time.time() < end:
            os.kill(pid, signal.SIGSTOP)
            time.sleep(0.0005)
            if fd is None and os.path.exists(PIN_ROOT + "/state"):
                fd = bpf_obj_get(PIN_ROOT + "/state")
            phase = read_phase(fd) if fd is not None else None
            if phase != last:
                seen.append(phase)
                last = phase
            if phase == want:
                os.kill(pid, signal.SIGKILL)
                killed = True
                break
            if (phase is not None and want < phase <= 5) or p.poll() is not None:
                break  # missed: the finally block lets it run on
            os.kill(pid, signal.SIGCONT)
            if run_slice:
                time.sleep(run_slice)
    finally:
        if fd is not None:
            os.close(fd)
        if not killed:
            try:
                os.kill(pid, signal.SIGCONT)
            except ProcessLookupError:
                pass
    out = p.communicate(timeout=60)[0]
    note(f"  phases seen while stepping: {seen}; killed={killed}; client: {out.strip()[:300]}\n")
    return killed, seen


def kill_at_free(target):
    """Arms without stopping the service and SIGKILLs it as soon as a tight loop reads the target phase from the
    pinned state map. Single-stepping cannot reach the phases after `maps`: every SIGSTOP/SIGCONT leaves a signal
    pending, and the kernel verifier then returns EAGAIN from BPF_PROG_LOAD, so `app on` fails (KernelFailure) and
    rolls back. The phase at the moment of death is read back from the pin before the restart (RestartSec=1); the
    attempt counts only if that phase is the target."""
    want = PHASES_ARMING[target]
    reset_start_limit()
    pid = main_pid()
    p = subprocess.Popen(as_user(OWNER, [CLI, "app", "on", "--policy", POLICY]), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    fd, seen, last, sent, at_death = None, [], None, False, None
    end = time.time() + 120
    try:
        while time.time() < end:
            if fd is None:
                if os.path.exists(PIN_ROOT + "/state"):
                    fd = bpf_obj_get(PIN_ROOT + "/state")
                if fd is None:
                    if p.poll() is not None:
                        break
                    continue
            phase = read_phase(fd)
            if phase != last:
                seen.append(phase)
                last = phase
            if phase == want:
                os.kill(pid, signal.SIGKILL)
                sent = True
                t0 = time.time()
                while os.path.exists(f"/proc/{pid}") and time.time() - t0 < 0.5:
                    time.sleep(0.001)
                at_death = read_phase(fd)
                break
            if (phase is not None and want < phase <= 5) or p.poll() is not None:
                break
    finally:
        if fd is not None:
            os.close(fd)
    out = p.communicate(timeout=60)[0]
    killed = sent and at_death == want
    note(f"  free-running: phases seen {seen}; SIGKILL sent={sent}; pinned phase after death={at_death}; client: {out.strip()[:300]}\n")
    return killed, seen + ([f"at death: {at_death}"] if sent else [])


def phase_kill_phases(_args):
    ok = True
    for target in ("maps", "cgroup", "listeners", "tracking", "armed"):
        with Case(f"G1{PHASES_ARMING[target]}-kill-at-{target}", f"SIGKILL while the pinned phase is '{target}'; the restart cleans up", "arming-recovery") as case:
            ensure_service(f"G.{target}")
            if status_label() != "off":
                rc, text = authorized_off()
                check(f"G.{target}.precondition-off", "harness", "OK off", text, rc == 0)
            run(["systemctl", "reset-failed", UNIT], timeout=15)
            failed_before = count_receipts(event="app_filter_on_failed", reason="interrupted_arming")
            attempts = []
            # Free-running first (no signals while the programs load), single-stepping as the fallback.
            for run_slice in (None, None, None, 0.0002, 0.00005):
                since = time.time()
                killed, seen = kill_at_free(target) if run_slice is None else kill_at(target, run_slice)
                attempts.append({"mode": "free" if run_slice is None else "step", "run_slice": run_slice, "phases": seen, "killed": killed})
                if killed:
                    break
                time.sleep(1)
                if status_label() == "armed":
                    authorized_off()
            check(f"G.{target}.reached", "harness", f"service killed at phase {PHASES_ARMING[target]}", attempts, killed)
            if not killed:
                ok = False
                continue
            time.sleep(1.5)  # RestartSec=1
            if not wait_active():
                cli_status()
                wait_active()
            time.sleep(1)
            journal("kill", since)
            if target == "armed":
                armed_check(f"G.{target}")
                check(f"G.{target}.restart-receipt", "test7", "app_filter_restart receipt", count_receipts(event="app_filter_restart"), count_receipts(event="app_filter_restart") >= 1)
            else:
                status = cli_status()
                check(f"G.{target}.status", "arming-recovery", "OK off", status, status_label(status) == "off")
                clean_check(f"G.{target}")
                failed_after = count_receipts(event="app_filter_on_failed", reason="interrupted_arming")
                check(f"G.{target}.receipt", "arming-recovery", "one more interrupted_arming receipt", [failed_before, failed_after], failed_after == failed_before + 1)
                rc, text = arm(f"rearm-after-{target}")
                check(f"G.{target}.rearm", "arming-recovery", "arming works again", text, rc == 0 and text.startswith("OK armed"))
            ok &= not case.failed
    return ok


def curl_pair(prefix, filtered):
    """example.com (allowed) and example.org (not in curl's allowlist) as the owner."""
    rc1, out1, err1 = run(as_user(OWNER, CURL + ["https://example.com/"]), timeout=40)
    rc2, out2, err2 = run(as_user(OWNER, CURL + ["https://example.org/"]), timeout=40)
    check(f"{prefix}.allowed", "host-like", "curl https://example.com/ -> 200", [rc1, out1.strip(), err1.strip()[:160]], rc1 == 0 and out1.strip() == "200")
    if filtered:
        check(f"{prefix}.refused", "host-like", "curl https://example.org/ fails (not in the allowlist)", [rc2, out2.strip(), err2.strip()[:160]], rc2 != 0)
    else:
        check(f"{prefix}.unfiltered", "host-like", "curl https://example.org/ -> 200 (no filter)", [rc2, out2.strip(), err2.strip()[:160]], rc2 == 0 and out2.strip() == "200")


def phase_host_like(_args):
    """The owner's host commands with a curl-only policy: on, off through polkit, on again (teardown follows)."""
    ok = True
    with Case("F06-host-arm-curl", "arm with the curl-only policy", "host-like") as case:
        ensure_service("F06")
        if status_label() == "armed":
            rc, text = authorized_off()
            check("F06.precondition-off", "harness", "OK off", text, rc == 0 and text == "OK off")
        rc, text = arm("host-arm", POLICY_HOST)
        check("F06.arm", "host-like", "OK armed", text, rc == 0 and text.startswith("OK armed"))
        armed_check("F06")
        curl_pair("F06", filtered=True)
        ok &= not case.failed
    with Case("F07-host-off-polkit", "blackice app off through polkit with the curl-only policy (REQUIRED)", "L10") as case:
        since = time.time()
        rc, text = authorized_off()
        journal("off", since)
        record("F07.polkit-journal", "L10", "polkitd log lines since the request",
               run(["journalctl", "--no-pager", "-o", "short-iso-precise", "--since", f"@{int(since)}", "-u", "polkit"], timeout=30, quiet=True)[1][-3000:], "OBSERVE")
        check("F07.off", "L10", "OK off", text, rc == 0 and text == "OK off")
        clean_check("F07")
        check("F07.off-receipt", "L10", "app_filter_off receipt, reason owner_authorized",
              count_receipts(event="app_filter_off", reason="owner_authorized"), count_receipts(event="app_filter_off", reason="owner_authorized") >= 1)
        curl_pair("F07", filtered=False)
        ok &= not case.failed
    with Case("F08-host-rearm-curl", "arm the curl-only policy again, for the teardown while armed", "host-like") as case:
        rc, text = arm("host-rearm", POLICY_HOST)
        check("F08.arm", "host-like", "OK armed", text, rc == 0 and text.startswith("OK armed"))
        armed_check("F08")
        curl_pair("F08", filtered=True)
        ok &= not case.failed
    return ok


AGENT_ASIDE = WORK + "/pkttyagent.aside"
ADMIN_RULE = "/etc/polkit-1/rules.d/49-blackice-appfilter-admin.rules"
ADMIN_RULE_SRC = ROOT + "/b9/49-blackice-appfilter-admin.rules.test"
STRACE_OUT = f"{DROP}/{OWNER}/b7-strace.txt"
# case id -> (title, expect with the agent, password prompt: yes/no/observe, typed command)
INTERACTIVE = {
    "B1-off-correct-password": ("ssh -t, app off, the correct password: the filter turns off", "off", "yes", "off"),
    "B2-off-wrong-password": ("ssh -t, app off, a wrong password: refused", "armed", "yes", "off"),
    "B3-off-ctrl-c": ("ssh -t, app off, Ctrl-C at the prompt: refused, terminal echo restored", "armed", "yes", "off"),
    "B4-off-no-answer": ("ssh -t, app off, no answer: refused at the 15 s polkit budget", "armed", "yes", "off"),
    "B5-off-no-tty": ("app off </dev/null without a tty: no agent, refused with no prompt", "armed", "no", "off"),
    "B7-off-agent-missing": ("pkttyagent moved aside: app off fails before contacting the service", "armed", "no", "off"),
    "B8-off-owner-not-admin": ("owner removed from group sudo (as on valendebian): the agent asks for root; first try refused", "armed", "observe", "off"),
    "B8a-off-root-password": ("owner not in sudo, no rule: root's password turns it off", "off", "yes", "off"),
    "B8b-off-root-wrong": ("owner not in sudo, no rule: a wrong root password is refused", "armed", "yes", "off"),
    "B9a-admin-rule-correct": ("security's admin rule, owner not in sudo: the owner's own password turns it off", "off", "yes", "off"),
    "B9b-admin-rule-wrong": ("security's admin rule: a wrong password is refused", "armed", "yes", "off"),
    "B9c-admin-rule-pkexec": ("security's admin rule: pkexec true with the owner's password is still refused", "armed", "observe", "pkexec"),
}


GPASSWD = "/usr/bin/gpasswd"  # Debian's passwd package; /usr/sbin/gpasswd does not exist


def agent_processes():
    return run(["/usr/bin/pgrep", "-a", "-u", OWNER, "pkttyagent"], timeout=10, quiet=True)[1].strip().splitlines()


def sudo_group():
    return run(["/usr/bin/getent", "group", "sudo"], timeout=10, quiet=True)[1].strip()


def file_facts(path):
    st = os.stat(path)
    with open(path, "rb") as f:
        return {"sha256": hashlib.sha256(f.read()).hexdigest(), "uid": st.st_uid, "gid": st.st_gid, "mode": oct(st.st_mode & 0o7777)}


def phase_interactive_setup(args):
    with Case("B00-interactive-setup", "what the real polkit path needs in this VM (security case B)", "L10") as case:
        groups = run(["/usr/bin/id", "-nG", OWNER], timeout=10)[1].split()
        check("B00.owner-in-sudo", "L10", "owner in group sudo (Debian's admin rule is unix-group:sudo)", groups, "sudo" in groups)
        agent = shutil.which("pkttyagent") or ""
        sha = ""
        if agent:
            with open(agent, "rb") as f:
                sha = hashlib.sha256(f.read()).hexdigest()
        check("B00.pkttyagent", "L10", "/usr/bin/pkttyagent present", {"path": agent, "sha256": sha}, agent == "/usr/bin/pkttyagent")
        with open("/usr/share/polkit-1/rules.d/50-default.rules") as f:
            record("B00.admin-rule", "L10", "Debian default admin rule", f.read(), "OBSERVE")
        status = run(["/usr/bin/passwd", "-S", OWNER], timeout=10)[1].split()
        check("B00.owner-password", "harness", "owner has a usable password (random, set by run.sh, never logged)",
              status[1] if len(status) > 1 else status, len(status) > 1 and status[1] == "P")
        check("B00.no-aftest-rule", "L10", "no aftest rule in rules.d", rules_listing(), not os.path.exists(POLKIT_RULE))
        record("B00.agent-mode", "harness", "run.sh --agent: yes = this commit should start pkttyagent", args.agent, "OBSERVE")
        return not case.failed


def phase_interactive_pre(args):
    cid = args.case
    with Case(cid, INTERACTIVE[cid][0], "L10", after=False) as case:
        ensure_service(cid)
        pre = {"t": time.time(), "agents_before": agent_processes()}
        if cid == "B7-off-agent-missing":
            pre["agent_file"] = file_facts("/usr/bin/pkttyagent")
            if os.path.exists(STRACE_OUT):
                os.remove(STRACE_OUT)
            os.rename("/usr/bin/pkttyagent", AGENT_ASIDE)
            check(f"{cid}.agent-aside", "L10", "/usr/bin/pkttyagent moved aside by root", os.path.exists("/usr/bin/pkttyagent"),
                  not os.path.exists("/usr/bin/pkttyagent"), facts=pre["agent_file"])
        if cid.startswith("B8"):
            pre["root_password_state"] = run(["/usr/bin/passwd", "-S", "root"], timeout=10, quiet=True)[1].split()[1:2]
            record(f"{cid}.root-password-state", "L10", "passwd -S root (P usable, L locked, NP none); run.sh sets a random one before B8a",
                   pre["root_password_state"], "OBSERVE")
        if cid == "B8-off-owner-not-admin":
            pre["sudo_group_before"] = sudo_group()
            run([GPASSWD, "-d", OWNER, "sudo"], timeout=10)
            pre["sudo_group_after"] = sudo_group()
            check(f"{cid}.owner-not-in-sudo", "L10", "getent group sudo has no owner", pre,
                  OWNER not in pre["sudo_group_after"].split(":")[-1].split(","))
        if cid == "B9a-admin-rule-correct":
            if OWNER in sudo_group().split(":")[-1].split(","):  # B8 did not run (targeted re-run)
                pre["sudo_group_before"] = sudo_group()
                run([GPASSWD, "-d", OWNER, "sudo"], timeout=10)
                pre["sudo_group_after"] = sudo_group()
            pre["rules_d_before"] = rules_listing()
            pre["rule_source"] = file_facts(ADMIN_RULE_SRC)
            run(["/usr/bin/install", "-o", "root", "-g", "root", "-m", "0644", ADMIN_RULE_SRC, ADMIN_RULE], timeout=10, check=True)
            time.sleep(2)  # polkitd reloads rules on inotify
            pre["rule_installed"] = file_facts(ADMIN_RULE)
            pre["rules_d_after_install"] = rules_listing()
            check(f"{cid}.rule-installed", "L10", "root:root 0644, sha256 0b943244... (security's file with valen->test)", pre["rule_installed"],
                  pre["rule_installed"] == {**pre["rule_installed"], "uid": 0, "gid": 0, "mode": "0o644",
                                            "sha256": "0b9432442412bac510fe4e56fc6d14964c179c00c6c932a57a89ef399b228cac"})
            check(f"{cid}.owner-not-in-sudo", "L10", "the owner is not in group sudo", sudo_group(), OWNER not in sudo_group().split(":")[-1].split(","))
        if status_label() != "armed":
            # An `off` right before leaves TIME_WAIT on 760-774. Since 63a38cc arming must work through it (V1),
            # so the harness does not wait; it records how many there were when it armed.
            tw = time_wait_on_listener_ports()
            record(f"{cid}.time-wait-at-arm", "V1", "TIME_WAIT sockets on 760-774 when re-arming for this case", len(tw), "OBSERVE")
            rc, text = arm(f"{cid}-arm", POLICY_HOST)
            check(f"{cid}.arm", "host-like", "OK armed (curl-only policy)", text, rc == 0 and text.startswith("OK armed"))
        armed_check(f"{cid}.pre")
        unit = unit_show()
        pre.update(main_pid=unit.get("MainPID"), restarts=unit.get("NRestarts"), off_receipts=count_receipts(event="app_filter_off"))
        save(f"cases/{cid}/pre.json", json.dumps(pre))
        note(f"  pre-state: {pre}\n  now the host runs the ssh session\n")
        return not case.failed


def phase_interactive_post(args):
    host = json.loads(base64.b64decode(args.host_result))
    cid = args.case
    title, expect_with_agent, prompt_rule, kind = INTERACTIVE[cid]
    expect = expect_with_agent if args.agent == "yes" else "armed"
    with Case(cid, title, "L10", before=False, resume=True) as case:
        with open(f"{case.dir}/pre.json") as f:
            pre = json.load(f)
        with open(f"{case.dir}/transcript.txt", "w") as f:
            f.write(host.pop("transcript", ""))
        record(f"{cid}.session", "L10", "what the ssh session showed (transcript.txt, password scrubbed)", host, "OBSERVE")
        if cid == "B7-off-agent-missing":
            if os.path.exists(AGENT_ASIDE) and not os.path.exists("/usr/bin/pkttyagent"):
                os.rename(AGENT_ASIDE, "/usr/bin/pkttyagent")
            restored = file_facts("/usr/bin/pkttyagent") if os.path.exists("/usr/bin/pkttyagent") else None
            check(f"{cid}.agent-restored", "L10", "same sha256, owner and mode as before", restored, restored == pre.get("agent_file"))
            trace = open(STRACE_OUT).read() if os.path.exists(STRACE_OUT) else ""
            with open(f"{case.dir}/strace.txt", "w") as f:
                f.write(trace)
            control = [l for l in trace.splitlines() if "connect(" in l and "/run/blackice-appfilter/control.sock" in l]
            check(f"{cid}.no-service-contact", "L10", "strace: no connect() to /run/blackice-appfilter/control.sock",
                  control, bool(trace) and not control, execve=[l for l in trace.splitlines() if "execve(" in l][:6])
            record(f"{cid}.error", "L10", "the CLI's error (a PolkitAgent... error expected)", host.get("output_tail", "")[-400:], "OBSERVE")
        if prompt_rule == "yes" and args.agent == "yes":
            check(f"{cid}.prompt", "L10", "pkttyagent password prompt in the ssh -t session", host.get("prompt_seen"), host.get("prompt_seen") is True)
        elif prompt_rule == "no" or args.agent == "no":
            check(f"{cid}.prompt", "L10", "no agent: refused with no prompt", host.get("prompt_seen"), host.get("prompt_seen") is False)
        else:
            record(f"{cid}.prompt", "L10", "what the agent showed (prompt, identity)", {"prompt_seen": host.get("prompt_seen"),
                   "events": host.get("events"), "sent": host.get("sent")}, "OBSERVE")
        out = host.get("output_tail", "")
        rc = host.get("exit_status")
        if kind == "pkexec":
            check(f"{cid}.pkexec-refused", "L10", "pkexec true is refused (different action, admin group empty)", [rc, out[-300:]],
                  isinstance(rc, int) and rc != 0)
            armed_check(cid)
        elif expect == "off":
            check(f"{cid}.cli", "L10", "exit 0 and OK off", [rc, out[-300:]], rc == 0 and "OK off" in out)
            status = cli_status()
            check(f"{cid}.status", "L10", "OK off", status, status_label(status) == "off")
            clean_check(cid)
            n = count_receipts(event="app_filter_off")
            check(f"{cid}.off-receipt", "L10", "one more app_filter_off receipt", [pre["off_receipts"], n], n == pre["off_receipts"] + 1)
            curl_pair(cid, filtered=False)
        else:
            check(f"{cid}.cli", "L10", "refused: non-zero exit, no OK off", [rc, out[-300:]], isinstance(rc, int) and rc != 0 and "OK off" not in out)
            armed_check(cid)
            n = count_receipts(event="app_filter_off")
            check(f"{cid}.no-off-receipt", "L10", "no new app_filter_off receipt", [pre["off_receipts"], n], n == pre["off_receipts"])
            curl_pair(cid, filtered=True)
        if "echo_restored" in host:
            check(f"{cid}.echo-restored", "L10", "terminal echo on afterwards: stty shows echo and the typed token shows",
                  {"stty_before": host.get("stty_before"), "stty_after": host.get("stty_after"), "typed_token_seen": host.get("echo_restored")},
                  host.get("stty_after") == "echo" and host.get("echo_restored") is True)
        if args.agent == "yes" and cid == "B4-off-no-answer":
            check(f"{cid}.budget", "L10/A2", "refused at about 15 s (one polkit budget for the whole exchange)", host.get("seconds"),
                  10 <= (host.get("seconds") or 0) <= 40, status_probe=host.get("status_probe_from_second_session"))
        if args.agent == "yes" and cid in ("B1-off-correct-password", "B9a-admin-rule-correct"):
            first = next((e["t"] for e in host.get("events", []) if e.get("event") == "password-prompt"), None)
            record(f"{cid}.timing", "L10/A2", "prompt and answer inside the 15 s budget", {"prompt_at": first, "command_seconds": host.get("seconds")}, "OBSERVE")
        agents = agent_processes()
        check(f"{cid}.no-agent-left", "L10", "pgrep -a -u owner pkttyagent: nothing after the session", {"before": pre.get("agents_before"), "after": agents}, not agents)
        unit = unit_show()
        served = [pre["main_pid"], unit.get("MainPID"), pre["restarts"], unit.get("NRestarts")]
        if expect == "off" and kind != "pkexec":
            # A successful off stops the service (MainPID 0); only a restart would be a finding here.
            record(f"{cid}.service-kept-serving", "L10", "off stops the service; NRestarts unchanged ([pre MainPID, MainPID, pre NRestarts, NRestarts])",
                   served, "OBSERVE")
            check(f"{cid}.no-restart", "L10", "NRestarts unchanged", [pre["restarts"], unit.get("NRestarts")], unit.get("NRestarts") == pre["restarts"])
        else:
            check(f"{cid}.service-kept-serving", "L10", "same MainPID and NRestarts as before the session", served,
                  unit.get("MainPID") == pre["main_pid"] and unit.get("NRestarts") == pre["restarts"])
        if cid == "B8b-off-root-wrong" and OWNER not in sudo_group().split(":")[-1].split(","):
            before = sudo_group()
            run([GPASSWD, "-a", OWNER, "sudo"], timeout=10)
            record(f"{cid}.sudo-restored", "harness", "owner put back in group sudo after the B8 cases", {"before": before, "after": sudo_group()}, "OBSERVE")
        if cid == "B9c-admin-rule-pkexec":
            os.remove(ADMIN_RULE)
            time.sleep(2)
            check(f"{cid}.rule-removed", "L10", "admin rule removed", rules_listing(), not os.path.exists(ADMIN_RULE))
            before = sudo_group()
            run([GPASSWD, "-a", OWNER, "sudo"], timeout=10)
            record(f"{cid}.sudo-restored", "harness", "owner put back in group sudo for the rest of the run", {"before": before, "after": sudo_group()}, "OBSERVE")
        journal(cid, pre["t"])
        polkit_log = run(["journalctl", "--no-pager", "-o", "short-iso-precise", "--since", f"@{int(pre['t'])}", "-u", "polkit"], timeout=30, quiet=True)[1]
        with open(f"{case.dir}/journal-polkit.txt", "w") as f:
            f.write(polkit_log)
        return not case.failed


def phase_teardown(_args):
    with Case("F09-teardown-armed", "teardown script while all seven hooks are attached", "test7/N2") as case:
        ensure_service("F09")
        armed_check("F09.before")
        rc, out, err = run(["/bin/bash", CANDIDATE + "/scripts/linux-appfilter-teardown.sh"], timeout=300)
        check("F09.rc", "test7", 0, rc, rc == 0)
        clean_check("F09")
        gone = {p: os.path.exists(p) for p in (
            "/etc/blackice-appfilter", "/run/blackice-appfilter", "/usr/local/libexec/blackice-linux-appfilter",
            "/usr/local/libexec/blackice-appfilter-bpffs", "/usr/local/libexec/blackice-appfilter-stage",
            "/etc/systemd/system/blackice-appfilter.service", "/etc/systemd/system/blackice-appfilter.socket",
            "/etc/systemd/system/blackice-appfilter-bpffs.service", "/usr/share/polkit-1/actions/org.blackice.appfilter.policy")}
        check("F09.files-removed", "test7", "all false", gone, not any(gone.values()))
        units = run(["systemctl", "list-unit-files", "blackice*", "--no-legend"], timeout=15)[1].strip()
        check("F09.units-removed", "test7", "no blackice unit files", units, units == "")
        check("F09.account-removed", "test7", "no blackice-appfilter account", run(["/usr/bin/getent", "passwd", "blackice-appfilter"])[1].strip(),
              run(["/usr/bin/getent", "passwd", "blackice-appfilter"])[0] != 0)
        st = os.stat(STATE_DIR) if os.path.isdir(STATE_DIR) else None
        check("F09.receipts-preserved", "test7", "kept, root:root, no group/other access (exact mode recorded)",
              None if st is None else [st.st_uid, st.st_gid, oct(st.st_mode & 0o7777)],
              st is not None and st.st_uid == 0 and st.st_gid == 0 and st.st_mode & 0o077 == 0)
        if st is not None:
            owners = sorted({(os.stat(os.path.join(STATE_DIR, n)).st_uid, os.stat(os.path.join(STATE_DIR, n)).st_gid) for n in os.listdir(STATE_DIR)})
            record("F09.receipt-file-owners", "test7", "noted in run-3fbd215: files keep the deleted service UID", owners, "OBSERVE",
                   mode=oct(st.st_mode & 0o7777))
        rows = json_lines(run(as_user(OWNER, probe_cmd("connect", "--addr", "127.0.0.1", "--port", "760")), timeout=20)[1])
        check("F09.no-hooks-left", "test7", "untagged 127.0.0.1:760 ECONNREFUSED (no hook, no listener)", rows, bool(rows) and rows[0]["outcome"] == "ECONNREFUSED")
        if os.path.exists(POLKIT_RULE):
            os.remove(POLKIT_RULE)
        return not case.failed


# ---------------------------------------------------------------------------------------------------------------
# extras (run.sh --extra): earlier review items outside the fixed list


def phase_extra_m4(_args):
    """M4, before the first arming: listed files on tmpfs, overlayfs and a btrfs subvolume are refused."""
    with Case("X01-m4-filesystems", "policies naming files off ext4/xfs are refused while off", "M4") as case:
        os.makedirs(ROOT + "/policies", exist_ok=True)
        mounts, cases = [], []
        os.makedirs("/opt/aftest-tmpfs", exist_ok=True)
        run(["/usr/bin/mount", "-t", "tmpfs", "-o", "mode=0755", "aftest", "/opt/aftest-tmpfs"], check=True)
        mounts.append("/opt/aftest-tmpfs")
        run(["/usr/bin/install", "-m", "0755", "/usr/bin/true", "/opt/aftest-tmpfs/aft-true"], check=True)
        cases.append(("tmpfs", "/opt/aftest-tmpfs/aft-true"))
        for d in ("/opt/aftest-lower", "/opt/aftest-upper", "/opt/aftest-work", "/opt/aftest-ovl"):
            os.makedirs(d, exist_ok=True)
        run(["/usr/bin/install", "-m", "0755", "/usr/bin/true", "/opt/aftest-lower/aft-true"], check=True)
        if run(["/usr/bin/mount", "-t", "overlay", "overlay", "-o", "lowerdir=/opt/aftest-lower,upperdir=/opt/aftest-upper,workdir=/opt/aftest-work", "/opt/aftest-ovl"])[0] == 0:
            mounts.append("/opt/aftest-ovl")
            cases.append(("overlayfs", "/opt/aftest-ovl/aft-true"))
        if shutil.which("mkfs.btrfs"):
            img = WORK + "/btrfs.img"
            run(["/usr/bin/truncate", "-s", "300M", img], check=True)
            run(["/usr/sbin/mkfs.btrfs", "-q", "-f", img], check=True)
            os.makedirs("/opt/aftest-btrfs", exist_ok=True)
            run(["/usr/bin/mount", "-o", "loop", img, "/opt/aftest-btrfs"], check=True)
            mounts.append("/opt/aftest-btrfs")
            run(["/usr/bin/btrfs", "subvolume", "create", "/opt/aftest-btrfs/sv"], check=True)
            os.chmod("/opt/aftest-btrfs", 0o755)
            os.chmod("/opt/aftest-btrfs/sv", 0o755)
            run(["/usr/bin/install", "-m", "0755", "/usr/bin/true", "/opt/aftest-btrfs/sv/aft-true"], check=True)
            cases.append(("btrfs-subvolume", "/opt/aftest-btrfs/sv/aft-true"))
        for label, exe in cases:
            path = f"{ROOT}/policies/m4-{label}.json"
            write_policy(path, [(exe, "example.com")])
            rc, out, err = cli("on", "--policy", path)
            text = (out + err).strip()
            check(f"X01.{label}", "M4", "refused, naming the file", text, rc != 0 and exe in text)
            if status_label() == "armed":
                authorized_off()  # an unexpected arm must not block the rest of the run
        clean_check("X01")
        for m in reversed(mounts):
            run(["/usr/bin/umount", m])
        return not case.failed


def phase_extra_uring(_args):
    ok = True
    with Case("X10-io-uring", "io_uring socket/connect, exit race and SQPOLL handover", "test4") as case:
        if run(["/usr/sbin/sysctl", "-n", "kernel.io_uring_disabled"])[1].strip() != "0":
            record("X10.io_uring", "test4", "io_uring enabled", "disabled", "SKIP")
            return True
        t0 = time.time()
        rows = json_lines(run(as_user(OWNER, launched(1, [URING, "basic", NS4, "9201"])), timeout=60)[1])
        check("X10.basic-tagged", "test4", "socket ok, connect PERM (inline and io-wq)", rows,
              len(rows) == 2 and all(r.get("socket") == "ok" and r.get("connect") == "PERM" for r in rows))
        rows = json_lines(run(as_user(OWNER, [URING, "basic", NS4, str(NS_TCP_PORT)]), timeout=60)[1])
        check("X10.basic-control", "test4 control", "untagged connects", rows, len(rows) == 2 and all(r.get("connect") == "ok" for r in rows))
        rows = json_lines(run(as_user(OWNER, launched(1, [URING, "exitrace", NS4, "9202", "200"])), timeout=300)[1])
        time.sleep(2)
        seen = sniffed(t0, dport=9202) or []
        check("X10.worker-after-exit", "test4", "no packet to 9202 from 200 exiting rings", {"probe": rows, "seen": len(seen)}, rows != [] and not seen)
        for mode, port in (("own-socket", 9204), ("ring-socket", 9203)):
            t1 = time.time()
            rows = json_lines(run(as_user(OWNER, [URING, "sqpoll-server", mode, NS4, str(port)] + APPS[0][2]), timeout=60)[1])
            time.sleep(1)
            seen = sniffed(t1, dport=port) or []
            client = next((r for r in rows if r.get("probe") == "uring-sqpoll-client"), {})
            if mode == "own-socket":
                check("X10.sqpoll-own-socket", "test4/M2", "the tagged socket stays on lo: connect fails, nothing seen",
                      {"client": client, "seen": len(seen)}, bool(client) and client.get("connect") != "ok" and not seen)
            else:
                record("X10.sqpoll-ring-socket", "test4", "observe: socket+connect run as the untagged SQPOLL owner (delegation)",
                       {"client": client, "seen": len(seen)}, "OBSERVE")
        rows = json_lines(run(as_user(OWNER, [URING, "sqpoll-server", "own-socket", "127.0.0.1", "762"] + APPS[0][2]), timeout=60)[1])
        client = next((r for r in rows if r.get("probe") == "uring-sqpoll-client"), {})
        check("X10.sqpoll-listener", "test4/H1", "another app's listener through an untagged ring: PERM", client, client.get("connect") == "PERM")
        ok &= not case.failed
    return ok


def proc_status(path):
    """Fields of /proc/<path>/status, for a pid or "pid/task/tid"."""
    out = {}
    with open(f"/proc/{path}/status") as f:
        for line in f:
            k, _, v = line.partition(":")
            out[k] = v.strip()
    return out


def children_of(pid):
    kids = []
    for entry in os.listdir("/proc"):
        if entry.isdigit():
            try:
                if proc_status(entry).get("PPid") == str(pid):
                    kids.append(int(entry))
            except OSError:
                pass
    return kids


def listener_inodes():
    """Socket inode -> local address of every TCP listener on 760-774 (this netns)."""
    found = {}
    for path in ("/proc/net/tcp", "/proc/net/tcp6"):
        with open(path) as f:
            for line in f.readlines()[1:]:
                cols = line.split()
                port = int(cols[1].rsplit(":", 1)[1], 16)
                if cols[3] == "0A" and FIRST_PORT <= port <= LAST_PORT:
                    found[cols[9]] = cols[1]
    return found


def fd_inventory(pid):
    rows = []
    for fd in sorted(os.listdir(f"/proc/{pid}/fd"), key=int):
        try:
            rows.append([int(fd), os.readlink(f"/proc/{pid}/fd/{fd}")])
        except OSError:
            rows.append([int(fd), "?"])
    return rows


def caps_report(pid):
    rows = []
    for tid in sorted(os.listdir(f"/proc/{pid}/task"), key=int):
        st = proc_status(f"{pid}/task/{tid}")
        rows.append({"tid": int(tid), **{k: st.get(k) for k in ("CapInh", "CapPrm", "CapEff", "CapBnd", "CapAmb", "NoNewPrivs", "Seccomp", "Seccomp_filters")}})
    return rows


def proxy_child():
    kids = children_of(main_pid())  # main_pid() raises rather than return 0
    return kids[0] if len(kids) == 1 else None, kids


def phase_service(_args):
    """Security's 5517189 list, items 1, 2, 4, 5, 7, 8 (item 3 is F02b, item 6 is R01, item 9 is B1-B4)."""
    ok = True
    with Case("S01-proxy-child-sandbox", "proxy child: no capabilities, NoNewPrivs, seccomp, only its own fds", "M5") as case:
        child, kids = proxy_child()
        check("S01.one-child", "M5", "the service has exactly one child (the proxy)", kids, child is not None)
        if child is not None:
            threads = caps_report(child)
            bad = [t for t in threads if any(int(t[k] or "1", 16) != 0 for k in ("CapEff", "CapPrm", "CapInh", "CapAmb"))
                   or t["NoNewPrivs"] != "1" or t["Seccomp"] != "2"]
            check("S01.caps-nnp-seccomp", "M5", "every thread: CapEff/CapPrm/CapInh/CapAmb 0, NoNewPrivs 1, Seccomp 2",
                  {"threads": len(threads), "bad": bad}, not bad, threads=threads)
            inventory, listeners = fd_inventory(child), listener_inodes()
            held, unexpected = set(), []
            for fd, target in inventory:
                m = re.fullmatch(r"socket:\[(\d+)\]", target)
                if m and m.group(1) in listeners:
                    held.add(m.group(1))
                elif target.startswith(STATE_DIR + "/") and "proxy" in os.path.basename(target):
                    pass
                elif fd in (1, 2):
                    pass
                else:
                    unexpected.append([fd, target])
            check("S01.fds", "M5", "only the listeners, the proxy receipt files and fds 1/2", unexpected, not unexpected, fds=inventory)
            check("S01.listeners-in-child", "M5", "the child holds every listener on 760-773", sorted(set(listeners) - held),
                  bool(listeners) and set(listeners) <= held, listeners=len(listeners))
            record("S01.ls-fd", "M5", "ls -l /proc/<child>/fd", run(["/usr/bin/ls", "-l", f"/proc/{child}/fd"], timeout=10, quiet=True)[1], "OBSERVE")
        ok &= not case.failed
    with Case("S02-loader-caps", "loader after arming: CapEff 0, CapPrm exactly cap_net_admin", "M5") as case:
        pid = main_pid()
        threads = caps_report(pid)
        bad = [t for t in threads if int(t["CapEff"], 16) != 0 or int(t["CapPrm"], 16) != 1 << CAP_NET_ADMIN or int(t["CapAmb"], 16) != 0]
        check("S02.caps", "M5", "every thread: CapEff 0, CapPrm = cap_net_admin (0x1000), CapAmb 0", {"threads": len(threads), "bad": bad}, not bad, threads=threads)
        record("S02.loader-fds", "M5", "inventory", fd_inventory(pid), "OBSERVE")
        ok &= not case.failed
    tls = app_ports(1)[0]
    with Case("S03-header-timeout", "a tagged client that sends nothing is closed at about 5 s", "M7") as case:
        before = count_receipts(event="header_timeout")
        rows = json_lines(run(as_user(OWNER, launched(1, probe_cmd("header-timeout", "--addr", "127.0.0.1", "--port", str(tls), "--wait", "15"))), timeout=60)[1])
        r = rows[0] if rows else {}
        check("S03.closed", "M7", "closed by the server after 4-7 s", r, r.get("how") in ("eof", "ECONNRESET") and 4.0 <= r.get("closed_after", 0) <= 7.0)
        time.sleep(1)
        after = count_receipts(event="header_timeout")
        check("S03.receipt", "M7", "one more header_timeout receipt", [before, after], after >= before + 1,
              last=[x for x in receipts() if x.get("event") == "header_timeout"][-1:])
        ok &= not case.failed
    with Case("S04-connection-limit", "the 17th concurrent tagged connection is closed", "M7") as case:
        before = count_receipts(event="connection_limit")
        rows = json_lines(run(as_user(OWNER, launched(1, probe_cmd("conn-limit", "--app", "1"))), timeout=60)[1])
        r = rows[0] if rows else {}
        check("S04.first-16", "M7", "16 connections stay open", r, r.get("first16_connected") == 16 and r.get("first16_open_before") == 16)
        check("S04.seventeenth", "M7", "the 17th is closed without a reply within 2 s", r.get("seventeenth"),
              (r.get("seventeenth") or {}).get("how") in ("eof", "ECONNRESET") and (r.get("seventeenth") or {}).get("closed_after", 9) <= 2.0)
        time.sleep(1)
        after = count_receipts(event="connection_limit")
        check("S04.receipt", "M7", "a connection_limit receipt", [before, after], after >= before + 1,
              last=[x for x in receipts() if x.get("event") == "connection_limit"][-1:])
        ok &= not case.failed
    with Case("S05-replacement", "a listed executable replaced during a refresh: the new inode is tagged", "M8") as case:
        misses, immediate = [], []
        for i in range(50):
            for _ in range(2 if i >= 20 else 1):
                run(["/usr/bin/install", "-m", "0755", "/usr/bin/setsid", LAUNCH_DIR + "/.aft-launch.new"], check=True, quiet=True)
                os.rename(LAUNCH_DIR + "/.aft-launch.new", LAUNCH_DIR + "/aft-launch")
            time.sleep(0.5)
            got = tagcheck(6)
            if got.get("own_port") != "connected":
                misses.append({"iteration": i, "double": i >= 20, "probe": got})
        check("S05.after-refresh", "M8", "50/50 launches 0.5 s after a replacement are tagged", f"{50 - len(misses)}/50", not misses, misses=misses[:10])
        for i in range(10):
            run(["/usr/bin/install", "-m", "0755", "/usr/bin/setsid", LAUNCH_DIR + "/.aft-launch.new"], check=True, quiet=True)
            os.rename(LAUNCH_DIR + "/.aft-launch.new", LAUNCH_DIR + "/aft-launch")
            immediate.append(tagcheck(6).get("own_port"))
        record("S05.immediate", "M8", "launches with no pause after a replacement (race with the refresh)", immediate, "OBSERVE")
        ok &= not case.failed
    with Case("S06-receipt-file-limit", "a receipt file stops at 8 MiB and status counts write_dropped", "M9") as case:
        def files():
            return {n: os.path.getsize(os.path.join(STATE_DIR, n)) for n in os.listdir(STATE_DIR) if n.startswith("receipt-")}
        status0 = cli_status()
        dropped0 = int(status_fields(status0).get("write_dropped", "0"))
        sizes0, chunks, probe_rows = files(), 0, []
        limit = int(status_fields(status0).get("receipt_file_limit", "8388608"))
        while chunks < 15:
            chunks += 1
            probe_rows += json_lines(run(as_user(OWNER, launched(1, probe_cmd("tcp-flood", "--dst", NS4, "--port", "9", "--count", "40000"))), timeout=300, quiet=True)[1])
            time.sleep(1)
            if int(status_fields(cli_status()).get("write_dropped", "0")) > dropped0:
                break
        time.sleep(2)
        status1, sizes1 = cli_status(), files()
        dropped1 = int(status_fields(status1).get("write_dropped", "0"))
        biggest = max(sizes1.items(), key=lambda kv: kv[1]) if sizes1 else ("", 0)
        check("S06.write-dropped", "M9", "write_dropped rises in status", [status0, status1], dropped1 > dropped0, chunks=chunks)
        check("S06.file-at-limit", "M9", f"the largest file reached the limit and did not pass it ({limit})", biggest,
              limit - 65536 <= biggest[1] <= limit, grew={n: [sizes0.get(n, 0), v] for n, v in sizes1.items() if v != sizes0.get(n, 0)})
        record("S06.loss-receipts", "M9", "receipt_loss lines in the service log", [x for x in receipts() if x.get("event") == "receipt_loss"][-3:], "OBSERVE",
               probe=probe_rows[-3:], ring_dropped=status_fields(status1).get("ring_dropped"))
        ok &= not case.failed
    return ok


def phase_extra_flood(_args):
    with Case("X22-m9-refusal-flood", "200k refused UDP sends: the service stays up and losses are counted", "M9") as case:
        before, before_bytes = unit_show(), receipt_bytes()
        rows = json_lines(run(as_user(OWNER, launched(1, probe_cmd("udp-flood", "--dst", NS4, "--port", "9", "--count", "200000"))), timeout=600)[1])
        time.sleep(3)
        after, after_bytes = unit_show(), receipt_bytes()
        check("X22.service-up", "M9", "same MainPID and NRestarts", [before.get("MainPID"), after.get("MainPID"), after.get("NRestarts")],
              before.get("MainPID") == after.get("MainPID") and before.get("NRestarts") == after.get("NRestarts"))
        record("X22.accounting", "M9", "losses counted (receipt_loss and/or status)", {"probe": rows, "bytes_before": before_bytes, "bytes_after": after_bytes,
               "loss_receipts": [r for r in receipts() if r.get("event") == "receipt_loss"][-3:], "status": cli_status()}, "OBSERVE")
        return not case.failed


def phase_reboot_check(_args):
    with Case("R01-after-reboot", "after a VM reboot: disarmed_by_reboot; a different policy needs an authorized off", "M6") as case:
        _, data = trees()
        status = cli_status()
        check("R01.status", "M6", "OK disarmed_by_reboot", status, status_label(status) == "disarmed_by_reboot")
        check("R01.no-hooks", "M6", "no bi_af_ attachment after the reboot (nothing re-arms by itself)",
              [r["name"] for r in ours(data["cgroup_tree"])], not ours(data["cgroup_tree"]))
        try:
            with open(WORK + "/last-policy") as f:
                last = f.read().strip()
        except OSError:
            last = POLICY_HOST
        other = POLICY if last == POLICY_HOST else POLICY_HOST
        rc, out, err = cli("on", "--policy", other)
        text = (out + err).strip()
        check("R01.different-policy-refused", "M6", f"app on {os.path.basename(other)} refused before an authorized off", [rc, text],
              rc != 0 and "OK armed" not in text, armed_before_reboot=last)
        status = cli_status()
        check("R01.still-disarmed", "M6", "still disarmed_by_reboot, no hooks", status,
              status_label(status) == "disarmed_by_reboot" and not ours(cgroup_attachments()))
        rc, text = authorized_off()
        check("R01.authorized-off", "M6", "OK off", text, rc == 0 and text == "OK off")
        check("R01.status-off", "M6", "OK off", cli_status(), status_label() == "off")
        rc, text = arm("after-reboot", other)
        check("R01.rearm-different", "M6", "the different policy arms after the authorized off", text, rc == 0 and text.startswith("OK armed"))
        armed_check("R01")
        return not case.failed


def phase_summary(_args):
    rows = [json.loads(l) for l in open(RESULTS + "/results.jsonl")] if os.path.exists(RESULTS + "/results.jsonl") else []
    counts, cases = {}, {}
    for r in rows:
        counts[r["verdict"]] = counts.get(r["verdict"], 0) + 1
        c = cases.setdefault(r["case"], {"PASS": 0, "FAIL": 0, "OBSERVE": 0, "SKIP": 0})
        c[r["verdict"]] += 1
    lines = [json.dumps(counts, sort_keys=True), ""]
    for cid in sorted(cases):
        c = cases[cid]
        lines.append(f"{'FAIL' if c['FAIL'] else 'ok':4}  {cid:34} pass={c['PASS']} fail={c['FAIL']} observe={c['OBSERVE']} skip={c['SKIP']}")
    lines.append("")
    for r in rows:
        if r["verdict"] in ("FAIL", "OBSERVE", "SKIP"):
            lines.append(f"{r['verdict']:7} {r['id']} ({r['finding']}): got {json.dumps(r['got'], default=str)[:300]}")
    text = "\n".join(lines) + "\n"
    save("summary.txt", text)
    print(text)
    return counts.get("FAIL", 0) == 0


PHASES = {
    "preflight": phase_preflight, "provision": phase_provision, "baseline": phase_baseline, "setup": phase_setup,
    "arm": phase_arm, "guard": phase_guard, "inbound": phase_inbound, "bind": phase_bind, "srh": phase_srh,
    "dns-redirect": phase_dns_redirect, "restart": phase_restart, "kill-fork": phase_kill_fork, "off": phase_off,
    "kill-phases": phase_kill_phases, "v1": phase_v1, "startlimit": phase_startlimit, "host-like": phase_host_like, "teardown": phase_teardown, "summary": phase_summary,
    "interactive-setup": phase_interactive_setup, "interactive-pre": phase_interactive_pre, "interactive-post": phase_interactive_post,
    "service": phase_service, "reboot-check": phase_reboot_check,
    "extra-m4": phase_extra_m4, "extra-uring": phase_extra_uring, "extra-flood": phase_extra_flood,
}


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    ph = sub.add_parser("phase")
    ph.add_argument("name", choices=sorted(PHASES))
    ph.add_argument("--case", choices=sorted(INTERACTIVE))
    ph.add_argument("--expect", choices=["off", "armed"])
    ph.add_argument("--agent", choices=["yes", "no"], default="yes")
    ph.add_argument("--host-result")
    sub.add_parser("nsserver")
    sn = sub.add_parser("sniff")
    sn.add_argument("--iface", required=True)
    sn.add_argument("--out", required=True)
    pr = sub.add_parser("probe")
    ps = pr.add_subparsers(dest="probe", required=True)
    for name in ("h1", "whoami", "dns", "redirect", "mptcp-create"):
        ps.add_parser(name)
    p = ps.add_parser("connect")
    p.add_argument("--addr", required=True)
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--timeout", type=float, default=2)
    p = ps.add_parser("listen")
    p.add_argument("--bind", required=True)
    p.add_argument("--port", type=int, default=0)
    p.add_argument("--seconds", type=float, default=6)
    p = ps.add_parser("bindtodevice")
    p.add_argument("--iface", required=True)
    p = ps.add_parser("pktinfo")
    for k in ("--iface", "--dst4", "--dst6", "--token"):
        p.add_argument(k, required=True)
    p.add_argument("--port", type=int, required=True)
    p = ps.add_parser("srh")
    p.add_argument("--segment", required=True)
    p.add_argument("--dst", required=True)
    p.add_argument("--port", type=int, required=True)
    p = ps.add_parser("lsrr")
    p.add_argument("--hop", required=True)
    p = ps.add_parser("idle-flood")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--count", type=int, required=True)
    p.add_argument("--marks", type=float, nargs="+", required=True)
    p = ps.add_parser("udp-flood")
    p.add_argument("--dst", required=True)
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--count", type=int, required=True)
    p = ps.add_parser("tagcheck")
    p.add_argument("--app", type=int, required=True)
    p = ps.add_parser("header-timeout")
    p.add_argument("--addr", required=True)
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--wait", type=float, default=15)
    p = ps.add_parser("conn-limit")
    p.add_argument("--app", type=int, required=True)
    p = ps.add_parser("tcp-flood")
    p.add_argument("--dst", required=True)
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--count", type=int, required=True)
    p = ps.add_parser("forker")
    p.add_argument("--app", type=int, default=1)
    p.add_argument("--trigger", required=True)
    p.add_argument("--out", required=True)
    args = ap.parse_args()
    if args.cmd == "nsserver":
        return ns_server(args)
    if args.cmd == "sniff":
        return sniff(args)
    if args.cmd == "probe":
        fn = {"h1": probe_h1, "whoami": lambda a: whoami(), "dns": probe_dns, "redirect": probe_redirect, "connect": probe_connect,
              "listen": probe_listen, "bindtodevice": probe_bindtodevice, "pktinfo": probe_pktinfo, "srh": probe_srh,
              "lsrr": probe_lsrr, "idle-flood": probe_idle_flood, "udp-flood": probe_udp_flood, "tagcheck": probe_tagcheck,
              "mptcp-create": probe_mptcp_create, "forker": probe_forker,
              "header-timeout": probe_header_timeout, "conn-limit": probe_conn_limit, "tcp-flood": probe_tcp_flood}[args.probe]
        return fn(args)
    if os.geteuid() != 0:
        sys.exit("phases run as root inside the test VM")
    os.chdir("/")  # probes run as other users, who cannot read the caller's home
    os.makedirs(RESULTS + "/cases", exist_ok=True)
    print(f"== phase {args.name} ({LABEL_TEXT}, commit {CONF.get('commit', '?')})", flush=True)
    sys.exit(0 if PHASES[args.name](args) else 1)


if __name__ == "__main__":
    main()
