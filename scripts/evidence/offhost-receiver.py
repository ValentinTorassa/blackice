#!/usr/bin/env python3
"""Off-host receiver for the P0-02 deny evidence: logs every TCP connection and UDP datagram it gets.
Usage: receiver.py V4_ADDR V6_ADDR LOGFILE SECONDS"""
import json, select, socket, sys, time
PORTS = {"tcp4": 47121, "tcp6": 47122, "udp4": 47123, "udp6": 47124}
v4, v6, logpath, seconds = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
socks = []
for name, port in PORTS.items():
    fam = socket.AF_INET if name.endswith("4") else socket.AF_INET6
    typ = socket.SOCK_STREAM if name.startswith("tcp") else socket.SOCK_DGRAM
    s = socket.socket(fam, typ)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((v4 if fam == socket.AF_INET else v6, port))
    if typ == socket.SOCK_STREAM:
        s.listen(16)
    socks.append((name, s))
with open(logpath, "a") as out:
    out.write(json.dumps({"t": time.time(), "event": "listening", "v4": v4, "v6": v6, "ports": PORTS}) + "\n"); out.flush()
    end = time.time() + seconds
    while time.time() < end:
        ready, _, _ = select.select([s for _, s in socks], [], [], 0.5)
        for s in ready:
            name = next(n for n, x in socks if x is s)
            if name.startswith("tcp"):
                c, addr = s.accept()
                c.settimeout(1)
                try:
                    data = c.recv(256)
                except Exception:
                    data = b""
                c.close()
            else:
                data, addr = s.recvfrom(256)
            out.write(json.dumps({"t": time.time(), "proto": name, "from": addr[0], "data": data.decode(errors="replace")}) + "\n"); out.flush()
