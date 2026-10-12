#!/usr/bin/env python3
"""Print the RGB of pixels in a PNG (8-bit RGB or RGBA, the simulator's
snapshots), without PIL: `png-pixel.py file.png X,Y [X,Y ...]` prints one
`X,Y R G B` line per point."""
import struct
import sys
import zlib


def decode(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        sys.exit("%s: not a PNG" % path)
    pos, idat, w = 8, b"", 0
    while pos < len(data):
        n, typ = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if typ == b"IHDR":
            w, h, depth, ctype = struct.unpack(">IIBB", body[:10])
            if depth != 8 or ctype not in (2, 6):
                sys.exit("%s: only 8-bit RGB/RGBA" % path)
            bpp = 3 if ctype == 2 else 4
        elif typ == b"IDAT":
            idat += body
        pos += 12 + n
    raw, stride, rows, prev = zlib.decompress(idat), w * bpp, [], None
    for y in range(h):
        f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i] if prev else 0
            c = prev[i - bpp] if prev and i >= bpp else 0
            if f == 1:
                line[i] = (line[i] + a) & 255
            elif f == 2:
                line[i] = (line[i] + b) & 255
            elif f == 3:
                line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line)
        prev = line
    return rows, bpp


rows, bpp = decode(sys.argv[1])
for pt in sys.argv[2:]:
    x, y = (int(v) for v in pt.split(","))
    px = rows[y][x * bpp:x * bpp + 3]
    print("%d,%d %d %d %d" % (x, y, px[0], px[1], px[2]))
