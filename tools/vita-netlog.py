#!/usr/bin/env python3
"""Receive VitaBrowser's diagnostics over the LAN (frontends/vita/netlog.c).

The Vita sends everything it writes under ux0:data/VitaBrowser/ -- log.txt,
netsurf.log, the plot dumps, autotest.done -- as it writes it. This rebuilds
those files on the PC, one folder per launch of the app:

    <out>/net-<date>-<time>-<boot id>/log.txt, netsurf.log, NN-page.plot, ...
    <out>/net-.../receiver.txt   what arrived, what is missing, what matched

so a result is never an old copy (hardware runs 2, 4 and 5 lost theirs in
the manual copy). Every file the Vita finishes (a plot dump, a marker, the
logs at the end) arrives with its length and CRC-32 and is checked; lost
datagrams are counted from their sequence numbers.

With --reference DIR (the simulator's dumps for the same build), each plot
dump is compared with DIR's file of the same name as it completes: SAME or
DIFF with the first differing line. The simulator runs the same frontend
code with the same fonts and FreeType release, so a DIFF is a real
difference between the device and the host.

Usage:
    py -3 vita-netlog.py [--out results] [--reference reference-dumps]
    python3 tools/vita-netlog.py --out /tmp/net --exit-when-done

Windows asks once whether Python may receive on the network: allow it for
private networks. Stdlib only (Python 3.8+). Protocol: vita/netlog.h.
"""

import argparse
import datetime
import os
import socket
import sys
import time
import zlib

PORT = 45100


def ranges_add(ranges, start, end):
    """Merge [start, end) into a sorted list of disjoint ranges."""
    out = []
    placed = False
    for a, b in ranges:
        if b < start:
            out.append((a, b))
        elif end < a:
            if not placed:
                out.append((start, end))
                placed = True
            out.append((a, b))
        else:
            start, end = min(a, start), max(b, end)
    if not placed:
        out.append((start, end))
    return sorted(out)


def missing_bytes(ranges, total):
    have = sum(min(b, total) - min(a, total) for a, b in ranges)
    return total - have


class Boot:
    """One launch of the app on the Vita."""

    def __init__(self, out, boot, hello, addr, reference, quiet):
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        self.dir = os.path.join(out, "net-%s-%s" % (stamp, boot))
        os.makedirs(self.dir, exist_ok=True)
        self.boot = boot
        self.hello = hello
        self.addr = addr
        self.reference = reference
        self.quiet = quiet
        self.seqs = set()
        self.max_seq = -1
        self.ranges = {}    # file -> [(start, end)]
        self.ends = {}      # file -> (total, crc, verdict)
        self.compared = {}  # file -> verdict against --reference
        self.log_printed = 0
        self.bye = False
        self.last = time.time()

    def path(self, name):
        # Names come from the network: keep them inside our folder.
        safe = os.path.basename(name.replace("\\", "/"))
        if safe in ("", ".", "..", "receiver.txt"):
            raise ValueError("bad file name %r" % name)
        return os.path.join(self.dir, safe)

    def data(self, name, off, payload):
        p = self.path(name)
        mode = "r+b" if os.path.exists(p) else "wb"
        with open(p, mode) as f:
            f.seek(off)
            f.write(payload)
        self.ranges[name] = ranges_add(self.ranges.get(name, []), off,
                                       off + len(payload))
        if name == "log.txt" and not self.quiet:
            self.echo_log()

    def echo_log(self):
        """Print log.txt as far as it has arrived without holes."""
        r = self.ranges.get("log.txt", [])
        if not r or r[0][0] != 0 or r[0][1] <= self.log_printed:
            return
        with open(self.path("log.txt"), "rb") as f:
            f.seek(self.log_printed)
            chunk = f.read(r[0][1] - self.log_printed)
        cut = chunk.rfind(b"\n") + 1
        if cut:
            sys.stdout.write(chunk[:cut].decode("utf-8", "replace"))
            sys.stdout.flush()
            self.log_printed += cut

    def end(self, name, total, crc_hex):
        p = self.path(name)
        if not os.path.exists(p):
            open(p, "wb").close()
        size = os.path.getsize(p)
        miss = missing_bytes(self.ranges.get(name, []), total)
        with open(p, "rb") as f:
            got = f.read(total)
        crc = "%08x" % (zlib.crc32(got) & 0xffffffff)
        # size > total is fine: a checkpoint (log.txt at autotest.done)
        # with more logged after it.
        if miss == 0 and crc == crc_hex and size >= total:
            verdict = "OK"
        elif miss:
            verdict = "INCOMPLETE (%d of %d bytes missing)" % (miss, total)
        else:
            verdict = "CRC MISMATCH (got %s, sent %s)" % (crc, crc_hex)
        self.ends[name] = (total, crc_hex, verdict)
        line = "  %-32s %8d bytes  %s" % (name, total, verdict)
        if self.reference and name.endswith(".plot"):
            line += "   vs reference: " + self.compare(name)
        print(line, flush=True)

    def compare(self, name):
        ref = os.path.join(self.reference, name)
        if not os.path.exists(ref):
            v = "no reference"
        else:
            with open(ref, "rb") as f:
                a = f.read().splitlines()
            with open(self.path(name), "rb") as f:
                b = f.read().splitlines()
            if a == b:
                v = "SAME"
            else:
                i = next((k for k in range(min(len(a), len(b)))
                          if a[k] != b[k]), min(len(a), len(b)))
                ndiff = sum(1 for x, y in zip(a, b) if x != y) + \
                    abs(len(a) - len(b))
                v = "DIFF (%d lines; first at line %d: ref %r / vita %r)" % (
                    ndiff, i + 1,
                    a[i].decode("utf-8", "replace") if i < len(a) else "<end>",
                    b[i].decode("utf-8", "replace") if i < len(b) else "<end>")
        self.compared[name] = v
        return v

    def lost(self):
        if self.max_seq < 0:
            return 0
        return self.max_seq + 1 - len(self.seqs)

    def summary(self):
        lines = [
            "VitaBrowser netlog receiver",
            "boot      %s from %s:%d" % (self.boot, self.addr[0], self.addr[1]),
            "hello     %s" % self.hello,
            "datagrams %d received, %d lost (by sequence number)%s" % (
                len(self.seqs), self.lost(),
                ", clean exit (bye)" if self.bye else ""),
            "",
            "files:",
        ]
        for name in sorted(set(self.ranges) | set(self.ends)):
            size = os.path.getsize(self.path(name))
            if name in self.ends:
                total, crc, verdict = self.ends[name]
                v = "%s (end mark: %d bytes, crc %s)" % (verdict, total, crc)
            else:
                v = "no end mark yet (%d bytes missing below %d)" % (
                    missing_bytes(self.ranges[name], size), size)
            cmpv = self.compared.get(name)
            lines.append("  %-32s %8d  %s%s" % (
                name, size, v, ("; reference: " + cmpv) if cmpv else ""))
        if self.compared:
            same = sum(1 for v in self.compared.values() if v == "SAME")
            lines += ["", "plot dumps vs reference: %d SAME, %d other" % (
                same, len(self.compared) - same)]
        with open(os.path.join(self.dir, "receiver.txt"), "w") as f:
            f.write("\n".join(lines) + "\n")
        return lines


def parse(pkt):
    """-> (boot, seq, type, name, off, length, payload) or None."""
    nl = pkt.find(b"\n")
    if nl < 0:
        return None
    head = pkt[:nl].decode("ascii", "replace").split(" ")
    if len(head) != 7 or head[0] != "VBL1":
        return None
    try:
        boot, seq, typ, name = head[1], int(head[2]), head[3], head[4]
        off, length = int(head[5]), int(head[6])
    except ValueError:
        return None
    payload = pkt[nl + 1:]
    if len(payload) != length:
        return None
    return boot, seq, typ, name, off, length, payload


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--out", default="results")
    ap.add_argument("--reference", help="folder of expected .plot dumps")
    ap.add_argument("--quiet", action="store_true",
                    help="do not print log.txt as it arrives")
    ap.add_argument("--exit-when-done", action="store_true",
                    help="exit once a boot has sent autotest.done and bye, "
                         "or gone quiet for 5 s after autotest.done")
    ap.add_argument("--timeout", type=float, default=0,
                    help="exit after this many seconds (0: never)")
    a = ap.parse_args()

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    # Room for bursts while a file is written. Windows grants 4 MB;
    # Linux caps it at net.core.rmem_max (the Vita paces itself anyway).
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
    except OSError:
        pass
    s.bind((a.bind, a.port))
    s.settimeout(0.5)
    os.makedirs(a.out, exist_ok=True)
    print("listening on UDP %s:%d; files go to %s" % (
        a.bind, a.port, os.path.abspath(a.out)), flush=True)

    boots = {}
    t_start = time.time()
    bad = 0
    try:
        while True:
            now = time.time()
            if a.timeout and now - t_start > a.timeout:
                print("timeout", flush=True)
                break
            done = [b for b in boots.values() if "autotest.done" in b.ends]
            if a.exit_when_done and done and all(
                    b.bye or now - b.last > 5 for b in done):
                break
            try:
                pkt, addr = s.recvfrom(65536)
            except socket.timeout:
                continue
            p = parse(pkt)
            if p is None:
                bad += 1
                continue
            boot, seq, typ, name, off, length, payload = p
            b = boots.get(boot)
            if b is None:
                hello = payload.decode("utf-8", "replace") if typ == "H" else "?"
                b = boots[boot] = Boot(a.out, boot, hello, addr, a.reference,
                                       a.quiet)
                print("== boot %s from %s: %s -> %s" % (
                    boot, addr[0], hello, b.dir), flush=True)
            b.last = now
            b.seqs.add(seq)
            b.max_seq = max(b.max_seq, seq)
            try:
                if typ == "H":
                    b.hello = payload.decode("utf-8", "replace")
                    s.sendto(("VBL1 ACK %s\n" % boot).encode(), addr)
                elif typ == "D":
                    b.data(name, off, payload)
                elif typ == "E":
                    b.end(name, off, payload.decode("ascii", "replace"))
                    b.summary()
                elif typ == "B":
                    b.bye = True
                    print("== boot %s said goodbye" % boot, flush=True)
            except (OSError, ValueError) as e:
                print("  %s: %s" % (name, e), flush=True)
    except KeyboardInterrupt:
        pass
    for b in boots.values():
        print("\n" + "\n".join(b.summary()))
    if bad:
        print("%d datagrams were not VitaBrowser's" % bad)
    return 0 if boots else 1


if __name__ == "__main__":
    sys.exit(main())
