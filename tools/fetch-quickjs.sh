#!/bin/sh
# Fetch the QuickJS engine the Vita build uses: QuickJS-ng 0.15.1 as MacSurf
# ships it (mplsllc/macsurf, quickjs-macos9/, pinned to commit 55e64fa --
# the same MacSurf revision as every other finding, pre-phase-0 §1).
#
# Why this copy (docs/phase-0/01 §5.3): browser/libquickjs/ in MacSurf's
# tree lacks the generated headers (quickjs-c-atomics.h,
# builtin-array-fromasync.h, builtin-iterator-zip*.h); quickjs-macos9/ is
# complete. The two quickjs.c differ in one Mac OS 9-only line
# (performance.now() via Microseconds(), fixes529). The Mac OS 9 parts are
# all behind MAC_OS_9 / __MWERKS__, which neither build defines.
#
# MacSurf keeps classic-Mac CR line endings; they are converted to LF so
# compiler diagnostics carry real line numbers. Then patches/quickjs/*.patch
# are applied (portability fixes, each explained in its header).
# Licence: MIT (QuickJS, QuickJS-ng), copied beside the sources.
#
# Usage: WORK=<WORK>/vitabrowser-work tools/fetch-quickjs.sh   (writes $WORK/quickjs)
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK="${WORK:-$HOME/vitabrowser-work}"
REV=55e64fac
# The import is redone when the pinned revision or our patches change.
STAMP="$REV $(cat "$ROOT"/patches/quickjs/*.patch | sha256sum | cut -c1-12)"
CLONE="$WORK/macsurf-src"
OUT="$WORK/quickjs"
FILES="quickjs.c quickjs.h quickjs-atom.h quickjs-opcode.h quickjs-c-atomics.h
libregexp.c libregexp.h libregexp-opcode.h libunicode.c libunicode.h
libunicode-table.h dtoa.c dtoa.h cutils.h list.h qjs_list.h
builtin-array-fromasync.h builtin-iterator-zip.h builtin-iterator-zip-keyed.h
LICENSE"

if [ -f "$OUT/.rev" ] && [ "$(cat "$OUT/.rev")" = "$STAMP" ]; then
	echo "== QuickJS-ng (MacSurf $REV): $OUT =="
	exit 0
fi
if [ ! -d "$CLONE/.git" ]; then
	git clone -q --no-checkout --filter=blob:none \
		https://github.com/mplsllc/macsurf "$CLONE"
	git -C "$CLONE" sparse-checkout init --cone
	git -C "$CLONE" sparse-checkout set quickjs-macos9
fi
git -C "$CLONE" checkout -q "$REV"
[ "$(git -C "$CLONE" rev-parse --short=8 HEAD)" = "$REV" ] || \
	{ echo "  MacSurf checkout is not $REV"; exit 1; }
rm -rf "$OUT"; mkdir -p "$OUT"
for f in $FILES; do
	tr '\r' '\n' < "$CLONE/quickjs-macos9/$f" > "$OUT/$f"
done
for p in "$ROOT"/patches/quickjs/*.patch; do
	patch -s -p1 -d "$OUT" < "$p" || { echo "  $p does not apply"; exit 1; }
	echo "  applied $(basename "$p")"
done
echo "$STAMP" > "$OUT/.rev"
echo "== QuickJS-ng $(sed -n 's/#define QJS_VERSION_\(MAJOR\|MINOR\|PATCH\) //p' "$OUT/quickjs.h" | tr '\n' '.' | sed 's/\.$//') (MacSurf $REV) -> $OUT =="
