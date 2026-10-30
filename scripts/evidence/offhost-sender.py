#!/usr/bin/env python3
"""Sends one TCP connection and one UDP datagram per address family to the receiver. Usage: sender.py V4 V6 LABEL"""
import socket, sys
v4, v6, label = sys.argv[1], sys.argv[2], sys.argv[3]
for name, fam, typ, addr, port in [("tcp4", socket.AF_INET, socket.SOCK_STREAM, v4, 47121), ("tcp6", socket.AF_INET6, socket.SOCK_STREAM, v6, 47122),
                                   ("udp4", socket.AF_INET, socket.SOCK_DGRAM, v4, 47123), ("udp6", socket.AF_INET6, socket.SOCK_DGRAM, v6, 47124)]:
    s = socket.socket(fam, typ)
    s.settimeout(3)
    try:
        if typ == socket.SOCK_STREAM:
            s.connect((addr, port)); s.sendall(("%s-%s" % (label, name)).encode())
        else:
            s.sendto(("%s-%s" % (label, name)).encode(), (addr, port))
        print("%s %s: sent" % (label, name))
    except OSError as e:
        print("%s %s: %s" % (label, name, e.strerror or e))
    finally:
        s.close()
