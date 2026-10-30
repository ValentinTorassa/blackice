#!/usr/bin/python3 -I
"""Host side of security's case B: `blackice app off` in a fresh `ssh -t` session to the test VM, under a pty,
answering the polkit text agent's prompt the way a person would (correct password, wrong password, Ctrl-C, or
nothing). Prints one JSON object (also written to --out). The password never reaches the output: it is read
from a 0600 file and scrubbed from the transcript.

Runs on the host and talks only to the VM through its ssh wrapper. run.sh calls it between the VM phases
`interactive-pre` and `interactive-post`, which record the state before and after.
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


def status_probe(vssh, cli, result):
    """Times one `app status` from a second ssh session while the first one waits at the prompt."""
    t0 = time.time()
    try:
        p = subprocess.run([vssh, f"{cli} app status"], capture_output=True, text=True, timeout=150)
        result.update(rc=p.returncode, output=(p.stdout + p.stderr).strip()[-300:])
    except subprocess.TimeoutExpired:
        result.update(rc=None, output="[no answer within 150 s]")
    result["seconds"] = round(time.time() - t0, 2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vssh", required=True)
    ap.add_argument("--cli", required=True)
    ap.add_argument("--owner", required=True)
    ap.add_argument("--attempt", required=True, choices=["correct", "wrong", "ctrl-c", "no-answer"])
    ap.add_argument("--password-file", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--status-probe-after", type=float, default=20.0, help="no-answer only")
    ap.add_argument("--limit", type=float, default=200.0)
    args = ap.parse_args()

    st = os.stat(args.password_file)
    if st.st_mode & 0o077:
        raise SystemExit("password file must be 0600")
    with open(args.password_file) as f:
        password = f.read().strip()
    wrong = "wrong-" + secrets.token_urlsafe(12)
    secrets_out = [password.encode(), wrong.encode()]

    cmd = [args.vssh, "-t", f"{args.cli} app off"]
    t0 = time.time()
    pid, fd = pty.fork()
    if pid == 0:
        os.execv(cmd[0], cmd)
    buf, mark = b"", 0  # mark: everything before it has been answered
    events, prompts, sent = [], 0, []
    probe, probe_thread = {}, None
    status = None
    while True:
        if time.time() - t0 > args.limit:
            os.kill(pid, signal.SIGKILL)  # our own pty child (the local ssh client)
            events.append({"t": round(time.time() - t0, 2), "event": f"killed the local ssh after {args.limit} s"})
            break
        r, _, _ = select.select([fd], [], [], 0.5)
        if fd in r:
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                chunk = b""
            if not chunk:
                break
            buf += chunk
            tail = buf[mark:]
            m = IDENTITY.search(tail)
            if m:
                rows = {int(n): name.decode(errors="replace") for n, name in IDENTITY_ROW.findall(tail)}
                choice = next((n for n, name in rows.items() if args.owner in name.split()), 1)
                events.append({"t": round(time.time() - t0, 2), "event": "identity-prompt", "rows": rows, "chose": choice})
                os.write(fd, f"{choice}\n".encode())
                mark = len(buf)
                continue
            if PROMPT.search(tail):
                prompts += 1
                mark = len(buf)
                events.append({"t": round(time.time() - t0, 2), "event": "password-prompt", "n": prompts})
                if args.attempt == "correct":
                    os.write(fd, password.encode() + b"\n")
                    sent.append("correct password")
                elif args.attempt == "wrong":
                    if prompts <= 3:
                        os.write(fd, wrong.encode() + b"\n")
                        sent.append("wrong password")
                    else:
                        os.write(fd, b"\x03")
                        sent.append("Ctrl-C after three wrong passwords")
                elif args.attempt == "ctrl-c":
                    time.sleep(1)
                    os.write(fd, b"\x03")
                    sent.append("Ctrl-C")
                else:
                    sent.append("nothing")
                    if probe_thread is None:
                        def later():
                            time.sleep(args.status_probe_after)
                            status_probe(args.vssh, args.cli, probe)
                        probe_thread = threading.Thread(target=later, daemon=True)
                        probe_thread.start()
        done, wstatus = os.waitpid(pid, os.WNOHANG)
        if done:
            status = wstatus
            # drain what is left
            while True:
                r, _, _ = select.select([fd], [], [], 0.3)
                if fd not in r:
                    break
                try:
                    chunk = os.read(fd, 4096)
                except OSError:
                    break
                if not chunk:
                    break
                buf += chunk
            break
    if status is None:
        _, status = os.waitpid(pid, 0)
    duration = round(time.time() - t0, 2)
    if probe_thread is not None:
        probe_thread.join(timeout=160)
    text = buf
    for s in secrets_out:
        text = text.replace(s, b"[scrubbed]")
    text = text.decode(errors="replace")
    result = {
        "attempt": args.attempt, "command": f"ssh -t {args.owner}@<vm> '{args.cli} app off'",
        "prompt_seen": prompts > 0, "password_prompts": prompts, "sent": sent, "events": events,
        "exit_status": os.waitstatus_to_exitcode(status), "seconds": duration,
        "output_tail": text[-3000:], "transcript": text,
    }
    if probe:
        result["status_probe_from_second_session"] = probe
    with open(args.out, "w") as f:
        json.dump(result, f, indent=1)
    summary = {k: v for k, v in result.items() if k != "transcript"}
    print(json.dumps(summary, indent=1))


if __name__ == "__main__":
    main()
