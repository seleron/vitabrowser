#!/bin/sh
# Patch 251's canvas raster (quickjs/macsurf_canvas.c) under ASan + UBSan:
# the real file and the real QuickJS-ng, the engine's hooks stubbed
# (tools/canvas-fuzz/harness.c), driven by a seeded fuzzer that calls every
# __cv native with hostile input -- NaN / Infinity / 1e12 coordinates,
# counts that overrun the points, bad paints, zero and oversized canvases,
# deep save/restore (tools/canvas-fuzz/fuzz.js). Any sanitizer report or a
# missing "ok" fails it.
#
# Usage: WORK=<WORK>/vitabrowser-work tools/test-canvas-raster.sh [seeds...]
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK="${WORK:-$HOME/vitabrowser-work}"
NS="$WORK/applytest/upstream/netsurf"
Q="$NS/content/handlers/javascript/quickjs"
P="$WORK/applytest/prefix"
QJ="$WORK/host-quickjs"
OUT="${OUT:-$WORK/canvas-fuzz}"
[ -f "$Q/macsurf_canvas.c" ] || { echo "no $Q/macsurf_canvas.c (patch 251 not staged)"; exit 2; }
[ -f "$QJ/lib/libquickjs.a" ] || WORK="$WORK" "$ROOT/tools/build-quickjs.sh" host
mkdir -p "$OUT"
gcc -g -O1 -fsanitize=address,undefined -fno-sanitize-recover=all \
	-fno-omit-frame-pointer -no-pie -DWITH_QUICKJS -D_GNU_SOURCE \
	-I"$Q" -I"$NS" -I"$NS/include" -I"$NS/content/handlers" -I"$NS/frontends" \
	-I"$P/include" -I"$QJ/include/quickjs" -I"$ROOT/compat" \
	-include macsurf_core_decls.h \
	"$ROOT/tools/canvas-fuzz/harness.c" "$Q/macsurf_canvas.c" \
	"$QJ/lib/libquickjs.a" -lm -lpthread -o "$OUT/harness" 2> "$OUT/build.log" \
	|| { grep -m8 error "$OUT/build.log"; exit 1; }
bad=0
for seed in ${*:-1 7 99 12345 424242 31337 2026 555 8080 4096}; do
	sed "s/var seed = [0-9]*;/var seed = $seed;/" "$ROOT/tools/canvas-fuzz/fuzz.js" > "$OUT/fuzz-$seed.js"
	r=$("$OUT/harness" "$OUT/fuzz-$seed.js" 2>&1 | tail -1)
	echo "  seed $seed: $r"
	case "$r" in "ok "*) ;; *) bad=$((bad + 1)) ;; esac
done
[ "$bad" -eq 0 ] && echo "canvas raster: ASan + UBSan clean" || { echo "canvas raster: $bad seed(s) FAILED"; exit 1; }
