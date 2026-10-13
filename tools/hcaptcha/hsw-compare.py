#!/usr/bin/env python3
"""Compare two hsw records (hsw-record.js: Chromium's, or the simulator's
via sim-rec.py) call by call. hsw's control flow is deterministic given
its import answers -- two Chromium runs make the same 17580 calls in the
same order -- so the first call that differs is where the engines' answers
first made hsw do something else. Shown: every import answer that differs
before that point (with the Reflect.has / get notes made inside it), then
the fork itself with the calls leading to it.

Usage: hsw-compare.py A.rec B.rec [--all]   (--all: also answers that are
clock readings, performance.now() / Date.now(), which always differ)"""
import re, sys


def load(path):
    lines = open(path, errors="replace").read().split("\n")
    mods, inst_mod, count = {}, {}, {}
    for l in lines:
        if l.startswith("M "):
            _, n, body = l.split(" ", 2)
            if body.startswith("len"):
                mods[n] = body
            else:
                b = bytes.fromhex(body)
                h = 0x811c9dc5
                for x in b:
                    h = ((h ^ x) * 16777619) & 0xffffffff
                mods[n] = "len%d:%x" % (len(b), h)
            continue
        m = re.match(r"^(\d+) (\S+) ?(.*)$", l)
        if not m:
            continue
        if m.group(2) == "INSTANCE":
            inst_mod[m.group(1)] = m.group(3)
        elif m.group(2) == "X":
            count[m.group(1)] = count.get(m.group(1), 0) + 1
    inst = max(count, key=count.get)
    evs = []
    for l in lines:
        m = re.match(r"^(\d+) ([XRIiEtK]) (.*)$", l)
        if m and m.group(1) == inst:
            evs.append((m.group(2), m.group(3)))
    return mods.get(inst_mod.get(inst), "?"), evs


def calls(evs):
    """[call, [notes], answer] for each X and I; an answer goes to the
    open call of its kind (R / E to the export call, i / t to the import)"""
    out, last = [], {}
    for k, t in evs:
        if k in "XI":
            c = [k + " " + re.sub(r" \|.*$", "", t), [], None]
            out.append(c)
            last[k] = last["K"] = c
        elif k == "K" and "K" in last:
            last["K"][1].append(t)
        elif k in "RE" and "X" in last:
            last["X"][2] = k + " " + re.sub(r" \| H.*$", "", t)
        elif k in "it" and "I" in last:
            last["I"][2] = k + " " + t
    return out


NUM = re.compile(r"^n(-?\d+(\.\d+)?)$")


def clock(x, y):
    """two tokens that differ only as clock readings do: epoch ms or s,
    or fractional milliseconds since the page started"""
    a, b = NUM.match(x), NUM.match(y)
    if not (a and b):
        return False
    u, v = float(a.group(1)), float(b.group(1))
    return (u > 1e9 and v > 1e9) or ("." in x + y and u > 50 and v > 50)


def same(x, y, masked):
    if x == y:
        return True
    if not masked or x is None or y is None:
        return False
    p, q = x.split(" "), y.split(" ")
    return len(p) == len(q) and all(s == t or clock(s, t) for s, t in zip(p, q))


def name(c):
    return " ".join(c[0].split(" ")[:2])


def main():
    a_mod, a = load(sys.argv[1])
    b_mod, b = load(sys.argv[2])
    show_all = "--all" in sys.argv
    print("A %s: module %s, %d events" % (sys.argv[1], a_mod, len(a)))
    print("B %s: module %s, %d events" % (sys.argv[2], b_mod, len(b)))
    if a_mod != b_mod:
        print("different hsw builds: the comparison means nothing")
        return 1
    ca, cb = calls(a), calls(b)
    n = min(len(ca), len(cb))
    fork = None
    for i in range(n):
        if name(ca[i]) != name(cb[i]):
            fork = i
            break
        m = not show_all
        if same(ca[i][0], cb[i][0], m) and same(ca[i][2], cb[i][2], m) and ca[i][1] == cb[i][1]:
            continue
        print("\ncall %d" % i)
        print("   A: %s -> %s" % (ca[i][0][:140], ca[i][2]))
        print("   B: %s -> %s" % (cb[i][0][:140], cb[i][2]))
        for na, nb in zip(ca[i][1] + [""] * len(cb[i][1]), cb[i][1] + [""] * len(ca[i][1])):
            if na or nb:
                print("     %s" % na[:120] if na == nb else "   ! A %s\n   ! B %s" % (na[:120], nb[:120]))
    if fork is None:
        print("\nsame %d calls%s" % (n, "" if len(ca) == len(cb) else
              " -- then %s ends (A %d calls, B %d)" % ("A" if len(ca) < len(cb) else "B", len(ca), len(cb))))
        return 0
    print("\nFORK at call %d:" % fork)
    for j in range(max(0, fork - 6), min(fork + 4, n)):
        for side, c in (("A", ca), ("B", cb)):
            if j < len(c):
                print("  %d %s %s -> %s %s" % (j, side, c[j][0][:90], c[j][2], " ".join(c[j][1])[:120]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
