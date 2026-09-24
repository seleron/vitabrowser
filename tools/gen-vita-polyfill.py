#!/usr/bin/env python3
"""Turn the bridge's JavaScript polyfill into a C string for macsurf_qjs.c.

content/handlers/javascript/quickjs/vita_polyfill.js is the source (patched
into NetSurf by patches/vitabrowser); vita_polyfill.inc beside it is what the
bridge #includes, so a build needs no Python. Run after editing the .js, then
regenerate the patch.

Usage: tools/gen-vita-polyfill.py [netsurf-tree]  (default: applytest's)
"""
import os
import sys

ns = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser(
    "<WORK>/vitabrowser-work/applytest/upstream/netsurf")
d = os.path.join(ns, "content/handlers/javascript/quickjs")
src = open(os.path.join(d, "vita_polyfill.js"), encoding="utf-8").read()
out = ["/* Generated from vita_polyfill.js by tools/gen-vita-polyfill.py;"
       " do not edit. */"]
for line in src.split("\n"):
    esc = (line.replace("\\", "\\\\").replace('"', '\\"')
           .replace("\t", "\\t").replace("??", "?\\?"))
    if any(ord(c) >= 128 for c in line):
        sys.exit("vita_polyfill.js: non-ASCII text; write \\uXXXX: " + line)
    out.append('"%s\\n"' % esc)
open(os.path.join(d, "vita_polyfill.inc"), "w").write("\n".join(out) + "\n")
print("vita_polyfill.inc: %d lines" % len(out))
