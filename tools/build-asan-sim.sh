#!/bin/sh
# Build an AddressSanitizer copy of the host simulator (nsvita-sim) from the
# current applytest tree, without touching applytest itself.
#
# Usage: WORK=<WORK>/vitabrowser-work tools/build-asan-sim.sh <dest-dir>
#        (after tools/run-vita-sim.sh: needs its overlay + libvitasim.a)
# Result: <dest-dir>/netsurf/nsvita-sim, instrumented netsurf code only
# (libcss/libdom/libhubbub/QuickJS/curl come from the uninstrumented prefix).
# Drive it with tools/scorecard/asan_sweep.py. Patch 395/396 entry, doc 10.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK="${WORK:-$HOME/vitabrowser-work}"
DEST="${1:?usage: build-asan-sim.sh <dest-dir>}"
P="$WORK/applytest/prefix"; OUT="$WORK/vita-sim"; OV="$OUT/overlay"
[ -f "$OUT/libvitasim.a" ] || { echo "no $OUT/libvitasim.a: run tools/run-vita-sim.sh first"; exit 1; }
mkdir -p "$DEST"
rm -rf "$DEST/netsurf"
cp -a "$WORK/applytest/upstream/netsurf" "$DEST/netsurf"
rm -rf "$DEST/netsurf/build/"*vita* "$DEST/netsurf/nsvita-sim"
export PKG_CONFIG_PATH="$WORK/host-curl/lib/pkgconfig:$WORK/host-freetype/lib/pkgconfig:$OV/lib/pkgconfig:$P/lib/pkgconfig"
# run-vita-sim.sh's flags, plus ASan; GCC's -O2 stringop/array-bounds
# warnings fire under ASan instrumentation, so they are not errors here.
export CFLAGS="-I$P/include/libutf8proc -I$ROOT/compat \
-include macsurf_core_decls.h -Wno-error=unused-variable -Wno-error=comment -Wno-error=nested-externs -Wno-error=redundant-decls -Wno-error=missing-prototypes -Wno-error=implicit-function-declaration -Wno-error=int-conversion -DVITABROWSER_ENGINE_TRACE \
-fsanitize=address -fno-omit-frame-pointer -g -Wno-error=stringop-overread -Wno-error=array-bounds -Wno-error=stringop-overflow -Wno-error=maybe-uninitialized"
export LDFLAGS="-L$OV/lib -fsanitize=address"
cd "$DEST/netsurf"
make TARGET=vita VITA_HOST_SIM=YES \
	VITA_SIM_INCLUDE="$ROOT/tools/vita-stub" VITA_SIM_LIB="$OUT/libvitasim.a" \
	VITA_SIM_QUICKJS="$WORK/host-quickjs" -j4 > "$DEST/asan-build.log" 2>&1 \
  || { grep -m8 -E 'error|undefined' "$DEST/asan-build.log"; exit 1; }
echo "ASan sim: $DEST/netsurf/nsvita-sim"
