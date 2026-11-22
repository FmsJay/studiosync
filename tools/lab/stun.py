#!/usr/bin/env python3
"""StudioSync lab: a STUN binding responder (RFC 5389: XOR-MAPPED-ADDRESS and MAPPED-ADDRESS) for the lab's "internet" side, so the
connection without Tailscale can tell the router VM's NAT kinds apart with no real internet (docs/rt/rt-nat3.md round 2). Run two, on two
ports, and set the test studio's band.json "nat_stun" to "<ip>:3478 <ip>:3479": a NAT that maps each destination to its own port (strict)
shows two different answers. Standard library only; answers binding requests and nothing else.

  python3 stun.py --port 3478 [--bind 0.0.0.0]      (Ctrl+C stops it)
  python3 stun.py --check HOST:PORT                  (one request from here: prints the address it saw)
"""
import argparse, os, socket, struct, sys

MAGIC = 0x2112A442


def answer(req, addr):
    """A binding request's answer for a sender at addr (ip, port), or None when req isn't one."""
    if len(req) < 20:
        return None
    typ, length, magic = struct.unpack("!HHI", req[:8])
    if typ != 0x0001 or magic != MAGIC or length != len(req) - 20:
        return None
    tx = req[8:20]
    ip = socket.inet_aton(addr[0])
    xip = bytes(a ^ b for a, b in zip(ip, struct.pack("!I", MAGIC)))
    xor = struct.pack("!HHBBH", 0x0020, 8, 0, 1, addr[1] ^ (MAGIC >> 16)) + xip
    plain = struct.pack("!HHBBH", 0x0001, 8, 0, 1, addr[1]) + ip
    body = xor + plain
    return struct.pack("!HHI", 0x0101, len(body), MAGIC) + tx + body


def mapped(resp):
    """The address in an answer: (ip, port), or None."""
    if len(resp) < 20 or struct.unpack("!H", resp[:2])[0] != 0x0101:
        return None
    i = 20
    while i + 4 <= len(resp):
        t, n = struct.unpack("!HH", resp[i:i + 4])
        v = resp[i + 4:i + 4 + n]
        if t == 0x0020 and n >= 8:
            port = struct.unpack("!H", v[2:4])[0] ^ (MAGIC >> 16)
            ip = bytes(a ^ b for a, b in zip(v[4:8], struct.pack("!I", MAGIC)))
            return socket.inet_ntoa(ip), port
        i += 4 + ((n + 3) & ~3)
    return None


def check(target):
    host, port = target.rsplit(":", 1)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(2)
    req = struct.pack("!HHI", 0x0001, 0, MAGIC) + os.urandom(12)
    s.sendto(req, (host, int(port)))
    data, _ = s.recvfrom(1500)
    return mapped(data)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=3478)
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--check")
    a = ap.parse_args()
    if a.check:
        print(check(a.check))
        return 0
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind((a.bind, a.port))
    print("STUN on %s:%d" % (a.bind, a.port), flush=True)
    while True:
        data, addr = s.recvfrom(1500)
        out = answer(data, addr)
        if out:
            s.sendto(out, addr)


if __name__ == "__main__":
    sys.exit(main())
