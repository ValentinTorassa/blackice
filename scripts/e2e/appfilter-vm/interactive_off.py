#!/usr/bin/python3 -I
"""Host side of security's case B: `blackice app off` typed into an interactive `ssh -t` login shell on the test
VM, under a pty, answering the polkit text agent the way a person would (correct password, wrong password,
Ctrl-C, or nothing). After the command returns, the same shell records `stty` and types a token to show whether
terminal echo was restored. Also a no-tty variant (`app off </dev/null` without -t).

Prints one JSON object (also written to --out). The password never reaches the output: it is read from a 0600
file and scrubbed from the transcript. Runs on the host and talks to the VM only through its ssh wrapper.
run.sh calls it between the VM phases `interactive-pre` and `interactive-post`.
"""
import argparse
import json
import os
import pty
import re
import secrets
import select
import signal
import subprocess
import threading
import time

PROMPT = re.compile(rb"password[^\n]*:\s*$", re.I)
IDENTITY = re.compile(rb"Choose identity to authenticate as \(1-(\d+)\):\s*$")
IDENTITY_ROW = re.compile(rb"^\s*(\d+)\.\s+(.*?)\s*$", re.M)
CSI = re.compile(rb"\x1b\[[0-9;?]*[A-Za-z]")
# The typed form of every marker differs from its output (`ST""TY` prints `STTY`), so the terminal's echo of a
# typed line, even when it wraps, can never match an output line.
STTY = "stty -a | tr ' ;' '\\n\\n' | grep -x -e echo -e -echo | sed \"s/^/{head}\"\"{tail}=/\""


def stty_cmd(tag):
    return STTY.format(head=tag[:-2], tail=tag[-2:])


def typed(tag):
    return f'{tag[:-1]}""{tag[-1]}'


def clean(data):
    return CSI.sub(b"", data)


def line(tag, value=rb"[^\r\n]*"):
    """An output line `TAG` or `TAG=value`, at the start of a line (after removing terminal escapes)."""
    return re.compile(rb"(?:^|[\r\n])" + re.escape(tag.encode()) + rb"(?:=(" + value + rb"))?\r?\n")


class Pty:
    def __init__(self, argv):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.execv(argv[0], argv)
        self.buf, self.eof, self.t0 = b"", False, time.time()

    def pump(self, wait):
        r, _, _ = select.select([self.fd], [], [], wait)
        if self.fd in r:
            try:
                chunk = os.read(self.fd, 4096)
            except OSError:
                chunk = b""
            if not chunk:
                self.eof = True
            self.buf += chunk

    def until(self, regex, start, timeout):
        end = time.time() + timeout
        while time.time() < end and not self.eof:
            m = regex.search(clean(self.buf[start:]))
            if m:
                return m
            self.pump(0.2)
        return regex.search(clean(self.buf[start:]))

    def send(self, data):
        os.write(self.fd, data)

    def close(self):
        end = time.time() + 5
        while time.time() < end and not self.eof:
            self.pump(0.2)
        done, status = os.waitpid(self.pid, os.WNOHANG)
        if not done:
            os.kill(self.pid, signal.SIGKILL)  # our own pty child (the local ssh client)
            _, status = os.waitpid(self.pid, 0)
        return os.waitstatus_to_exitcode(status)


def vm_wrapper(path):
    """Refuses anything that could run on this host. The wrapper must be a test VM's vssh (never the demo VM's),
    its only command must exec ssh (so nothing can fall back to a local shell or the local PATH), and the VM must
    answer `hostname` with test-vm. Returns the resolved path, which is the only one used afterwards."""
    real = os.path.realpath(path)
    if not re.fullmatch(r"/var/tmp/blackice-vm[0-9]+/vssh", real):
        raise SystemExit(f"refusing {path}: not a test VM wrapper (/var/tmp/blackice-vmN/vssh)")
    with open(real) as f:
        body = [l for l in f.read().splitlines() if l.strip() and not l.lstrip().startswith("#")]
    if len(body) != 1 or not body[0].startswith("exec ssh ") or not body[0].rstrip().endswith('"$@"'):
        raise SystemExit(f"refusing {real}: it must be one `exec ssh ... \"$@\"` line")
    host = subprocess.run([real, "hostname"], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30).stdout.strip()
    if host != "test-vm":
        raise SystemExit(f"refusing {real}: hostname is {host!r}, not test-vm")
    return real


def status_probe(vssh, cli, result):
    """Times one `app status` from a second ssh session while the first one waits at the prompt."""
    t0 = time.time()
    try:
        p = subprocess.run([vssh, f"{cli} app status"], capture_output=True, text=True, timeout=150)
        result.update(rc=p.returncode, output=(p.stdout + p.stderr).strip()[-300:])
    except subprocess.TimeoutExpired:
        result.update(rc=None, output="[no answer within 150 s]")
    result["seconds"] = round(time.time() - t0, 2)


def no_tty(args):
    t0 = time.time()
    p = subprocess.run([args.vssh, f"{args.cli} app off </dev/null; echo AFTEST-RC=$?"], stdin=subprocess.DEVNULL,
                       capture_output=True, timeout=120)
    text = (p.stdout + p.stderr).decode(errors="replace")
    m = re.search(r"(?m)^AFTEST-RC=(\d+)", text)
    return {"attempt": "no-tty", "command": f"ssh {args.owner}@<vm> '{args.cli} app off </dev/null' (no -t)",
            "prompt_seen": bool(PROMPT.search(text.encode())) or "AUTHENTICATING" in text, "password_prompts": 0, "sent": [],
            "events": [], "exit_status": int(m.group(1)) if m else None, "seconds": round(time.time() - t0, 2),
            "output_tail": text[-3000:], "transcript": text}


def interactive(args, password, wrong):
    tok = "AFTEST-T-" + secrets.token_hex(6)
    s = Pty([args.vssh, "-t"])  # an interactive login shell, as a person would get
    s.send(("export LC_ALL=C; " + stty_cmd("AFTEST-STTY0") + f"; echo {typed('AFTEST-READY')}\n").encode())
    ready = s.until(line("AFTEST-READY"), 0, 30)
    events, sent, prompts, probe, probe_thread = [], [], 0, {}, None
    if not ready:
        events.append({"event": "shell not ready"})
    mark = len(s.buf)
    target = "pkexec true" if args.attempt == "pkexec" else f"{args.prefix}{args.cli} app off"
    command = f"{target}; echo {typed('AFTEST-RC')}=$?"
    s.send((command + "\n").encode())
    t_cmd = time.time()
    rc_re = line("AFTEST-RC", rb"\d+")
    rc = None
    while time.time() - t_cmd < args.limit and not s.eof:
        m = rc_re.search(clean(s.buf[mark:]))
        if m:
            rc = int(m.group(1))
            break
        s.pump(0.3)
        tail = s.buf[mark:]
        if IDENTITY.search(tail):
            rows = {int(n): name.decode(errors="replace") for n, name in IDENTITY_ROW.findall(tail)}
            choice = next((n for n, name in rows.items() if args.owner in name.split()), 1)
            events.append({"t": round(time.time() - t_cmd, 2), "event": "identity-prompt", "rows": rows, "chose": choice})
            s.send(f"{choice}\n".encode())
            mark = len(s.buf)
        elif PROMPT.search(tail):
            prompts += 1
            mark = len(s.buf)
            events.append({"t": round(time.time() - t_cmd, 2), "event": "password-prompt", "n": prompts})
            if args.attempt in ("correct", "pkexec"):
                if prompts <= 3:
                    s.send(password.encode() + b"\n")
                    sent.append("the owner's password")
                else:
                    s.send(b"\x03")
                    sent.append("Ctrl-C after three prompts")
            elif args.attempt == "wrong":
                s.send((wrong if prompts <= 3 else "\x03").encode() + (b"\n" if prompts <= 3 else b""))
                sent.append("wrong password" if prompts <= 3 else "Ctrl-C after three wrong passwords")
            elif args.attempt == "ctrl-c":
                time.sleep(1)
                s.send(b"\x03")
                sent.append("Ctrl-C")
            else:
                sent.append("nothing")
                if probe_thread is None:
                    def later():
                        time.sleep(args.status_probe_after)
                        status_probe(args.vssh, args.cli, probe)
                    probe_thread = threading.Thread(target=later, daemon=True)
                    probe_thread.start()
    seconds = round(time.time() - t_cmd, 2)
    if rc is None:
        events.append({"t": seconds, "event": f"no AFTEST-RC within {args.limit} s; sending Ctrl-C to reach the shell"})
        s.send(b"\x03")
        time.sleep(1)
    after = len(s.buf)
    s.send((stty_cmd("AFTEST-STTY") + "\n").encode())
    s.send(f"true {tok}\n".encode())
    s.send(f"echo {typed('AFTEST-END')}\n".encode())
    s.until(line("AFTEST-END"), after, 20)
    s.send(b"exit\n")
    session_exit = s.close()
    if probe_thread is not None:
        probe_thread.join(timeout=160)
    text = s.buf
    for secret in (password.encode(), wrong.encode()):
        text = text.replace(secret, b"[scrubbed]")
    stty0 = line("AFTEST-STTY0", rb"-?echo").search(clean(text))
    stty1 = line("AFTEST-STTY", rb"-?echo").search(clean(text[after:]))
    text_after = text[after:]
    result = {
        "attempt": args.attempt, "command": f"ssh -t {args.owner}@<vm>, then typed: {command}",
        "prompt_seen": prompts > 0, "password_prompts": prompts, "sent": sent, "events": events,
        "exit_status": rc, "seconds": seconds, "session_exit": session_exit,
        "stty_before": stty0.group(1).decode() if stty0 else None, "stty_after": stty1.group(1).decode() if stty1 else None,
        "echo_restored": tok.encode() in text_after, "echo_token": tok,
        "output_tail": text[max(0, after - 3000):after].decode(errors="replace"), "transcript": text.decode(errors="replace"),
    }
    if probe:
        result["status_probe_from_second_session"] = probe
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vssh", required=True)
    ap.add_argument("--cli", required=True)
    ap.add_argument("--owner", required=True)
    ap.add_argument("--attempt", required=True, choices=["correct", "wrong", "ctrl-c", "no-answer", "no-tty", "agent-missing", "pkexec"])
    ap.add_argument("--prefix", default="", help="typed before the CLI, e.g. an strace wrapper")
    ap.add_argument("--password-file", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--status-probe-after", type=float, default=8.0, help="no-answer only")
    ap.add_argument("--limit", type=float, default=150.0)
    args = ap.parse_args()
    args.vssh = vm_wrapper(args.vssh)
    if not args.cli.startswith("/opt/aftest/"):
        raise SystemExit("refusing: the CLI must be the VM kit's /opt/aftest/bin/blackice")

    if os.stat(args.password_file).st_mode & 0o077:
        raise SystemExit("password file must be 0600")
    with open(args.password_file) as f:
        password = f.read().strip()
    wrong = "wrong-" + secrets.token_urlsafe(12)
    if args.attempt == "no-tty":
        result = no_tty(args)
    else:
        if args.attempt == "agent-missing":
            args.attempt = "correct"  # answer a prompt if one appears anyway; none should
            result = interactive(args, password, wrong)
            result["attempt"] = "agent-missing"
        else:
            result = interactive(args, password, wrong)
    for key in ("transcript", "output_tail"):
        result[key] = result[key].replace(password, "[scrubbed]").replace(wrong, "[scrubbed]")
    with open(args.out, "w") as f:
        json.dump(result, f, indent=1)
    print(json.dumps({k: v for k, v in result.items() if k != "transcript"}, indent=1))


if __name__ == "__main__":
    main()
