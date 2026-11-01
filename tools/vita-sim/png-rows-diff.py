#!/usr/bin/env python3
"""Count the pixel rows two simulator snapshots differ in, between y0 and y1
(default 20-520: below the HUD's title bar, above its status line).
Patch 365: a page a script changed must render as the same DOM written
statically. Usage: png-rows-diff.py A.png B.png [y0 y1]; prints the count."""
import struct
import sys
import zlib


def rows(path):
    d = open(path, 'rb').read()
    i, idat, h = 8, b'', 0
    while i < len(d):
        n = struct.unpack('>I', d[i:i + 4])[0]
        t, c = d[i + 4:i + 8], d[i + 8:i + 8 + n]
        if t == b'IHDR':
            h = struct.unpack('>II', c[:8])[1]
        elif t == b'IDAT':
            idat += c
        i += 12 + n
    raw = zlib.decompress(idat)
    st = len(raw) // h
    return [raw[r * st:(r + 1) * st] for r in range(h)]


a, b = rows(sys.argv[1]), rows(sys.argv[2])
y0 = int(sys.argv[3]) if len(sys.argv) > 3 else 20
y1 = int(sys.argv[4]) if len(sys.argv) > 4 else 520
print(sum(1 for r in range(y0, min(y1, len(a), len(b))) if a[r] != b[r]) +
      abs(len(a) - len(b)))
