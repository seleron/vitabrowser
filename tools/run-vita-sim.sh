#!/bin/sh
# Run the Vita frontend on the build machine (no Vita hardware).
#
# Builds frontends/vita with VITA_HOST_SIM=YES -- the same sources as the
# cross build, host compiler, against the host-built patched engine -- and
# links it to tools/vita-sim/vitasim.c, a stand-in vitaSDK that rasterises
# vita2d calls in software and scripts the pad. The real device paths are
# kept: the run directory holds a directory literally named "app0:", so
# "app0:/testpages/L1-layout-basics.html" resolves on Linux exactly as it
# will on the Vita, through the frontend's own file-path table.
#
# Each bundled test page is opened in turn (the frontend's R-trigger
# handler) and its settled frame is written to $OUT/shots/page-NN.png, in
# the order of vita_test_pages[] in frontends/vita/main.c. A second run
# drives the frontend's own autotest (SQUARE), which writes the same
# ux0:data/VitaBrowser/ log and plot dumps as a Vita does; they are copied
# to $OUT/reference/ for diffing against a device run.
# See docs/phase-0/09-vita-frontend.md.
#
# Usage: WORK=<WORK>/vitabrowser-work tools/run-vita-sim.sh
#        (after tools/build-patched.sh: needs its host engine prefix)
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK="${WORK:-$HOME/vitabrowser-work}"
NS="$WORK/applytest/upstream/netsurf"
P="$WORK/applytest/prefix"
OUT="${OUT:-$WORK/vita-sim}"
PAGES="${PAGES:-15}"

[ -f "$NS/frontends/vita/main.c" ] || { echo "no $NS/frontends/vita -- run tools/build-patched.sh"; exit 2; }
[ -f "$P/lib/pkgconfig/libcss.pc" ] || { echo "no host engine at $P -- run tools/build-patched.sh"; exit 2; }

mkdir -p "$OUT/shots" "$OUT/run"
# The frontend draws text with FreeType from app0:/res/fonts (vita/text.c).
[ -f "$WORK/fonts/DejaVuSans.ttf" ] || WORK="$WORK" "$ROOT/tools/fetch-fonts.sh"
rm -f "$OUT"/shots/*.png

echo "== stand-in SDK =="
gcc -std=c99 -D_DEFAULT_SOURCE -O2 -g -Wall -Wextra -Wno-unused-parameter -Werror \
	-I"$ROOT/tools/vita-stub" \
	-c "$ROOT/tools/vita-sim/vitasim.c" -o "$OUT/vitasim.o"
rm -f "$OUT/libvitasim.a"
ar rcs "$OUT/libvitasim.a" "$OUT/vitasim.o"

# libparserutils as the Vita builds it (tools/build-vita.sh): without the
# iconv input filter, since the stand-in libc has no iconv either. Kept in
# its own prefix, searched first, so the host nsmonkey build is untouched.
# If this overlay ever stops being linked, no page can load in the
# simulator -- the run below fails loudly rather than passing by accident.
echo "== libparserutils overlay (WITHOUT_ICONV_FILTER) =="
OV="$OUT/overlay"
rm -rf "$OV"
# Built from a private copy: the staged tree's object directory belongs to
# the host nsmonkey build, and make would happily reinstall its iconv objects.
rm -rf "$OUT/src-parserutils"
cp -r "$WORK/applytest/upstream/libparserutils" "$OUT/src-parserutils"
rm -rf "$OUT"/src-parserutils/build-*
( cd "$OUT/src-parserutils" && \
  CFLAGS="-I$ROOT/compat -include macsurf_lib_decls.h -DWITHOUT_ICONV_FILTER" \
  PKG_CONFIG_PATH="$P/lib/pkgconfig" \
  make install PREFIX="$OV" NSSHARED="$P/share/netsurf-buildsystem" \
    WARNFLAGS=-Wall > "$OUT/overlay.log" 2>&1 ) \
  || { echo "  overlay FAILED"; grep -m3 error "$OUT/overlay.log"; exit 1; }
if nm "$OV/lib/libparserutils.a" | grep -q " U iconv_open"; then
	echo "  overlay still uses iconv"; exit 1
fi

echo "== frontends/vita, host simulator build =="
# Same core flags as tools/build-patched.sh's nsmonkey build.
export PKG_CONFIG_PATH="$OV/lib/pkgconfig:$P/lib/pkgconfig"
export CFLAGS="-I$P/include/libutf8proc -I$ROOT/compat \
-include macsurf_core_decls.h -Wno-error=unused-variable -Wno-error=comment -Wno-error=nested-externs -Wno-error=redundant-decls -Wno-error=missing-prototypes -Wno-error=implicit-function-declaration -Wno-error=int-conversion -DVITABROWSER_ENGINE_TRACE"
rm -f "$NS/nsvita-sim"	# the overlay changed under it; force the relink
( cd "$NS" && make TARGET=vita VITA_HOST_SIM=YES \
	VITA_SIM_INCLUDE="$ROOT/tools/vita-stub" VITA_SIM_LIB="$OUT/libvitasim.a" \
	-j4 > "$OUT/build.log" 2>&1 ) \
  || { echo "  build FAILED"; grep -m8 -E 'error|undefined' "$OUT/build.log"; exit 1; }
echo "  nsvita-sim ok"

echo "== app0: bundle =="
A="$OUT/run/app0:"
rm -rf "$A"
mkdir -p "$A/res" "$A/testpages"
rm -rf "$OUT/run/ux0:data"
mkdir -p "$OUT/run/ux0:data"
for f in default.css quirks.css adblock.css internal.css Messages \
	 welcome.html credits.html licence.html; do
	cp -L "$NS/frontends/vita/res/$f" "$A/res/$f"
done
cp "$ROOT"/testpages/pages/* "$A/testpages/"
mkdir -p "$A/res/fonts"
cp "$WORK"/fonts/*.ttf "$WORK"/fonts/LICENSE-*.txt "$A/res/fonts/"

echo "== run: $PAGES pages =="
( cd "$OUT/run" && VITA_SIM_OUT="$OUT/shots" VITA_SIM_PAGES="$PAGES" \
	timeout 300 "$NS/nsvita-sim" )
ls "$OUT"/shots

echo "== autotest run (reference dumps) =="
rm -rf "$OUT/run/ux0:data/VitaBrowser" "$OUT/reference" "$OUT/snaps"
mkdir -p "$OUT/snaps"
( cd "$OUT/run" && VITA_SIM_AUTOTEST=1 VITA_SIM_SNAP="$OUT/snaps" \
	timeout 900 "$NS/nsvita-sim" )
cp -r "$OUT/run/ux0:data/VitaBrowser" "$OUT/reference"
ls "$OUT/reference" | head -40

# The autotest renders every page once per pass (frontends/vita/main.c
# vita_passes[]). Clocks do nothing here, but the clip modes must not change
# a pixel: pass C (CPU clipping) against pass A (the stencil per clip).
# A page whose frames differ even between A and B -- the same clip mode;
# clocks do nothing here -- changes over time by itself (PM-animation's
# rotation is driven by the animation clock), so it cannot be compared and
# is reported as such.
echo "== clip modes, pixel for pixel =="
same=0; diff=0; timed=0
for a in "$OUT"/snaps/A-*.png; do
	page=${a##*/A-}
	if ! cmp -s "$a" "$OUT/snaps/B-$page"; then
		timed=$((timed + 1)); echo "  time-varying, skipped: $page"
	elif cmp -s "$a" "$OUT/snaps/C-$page"; then same=$((same + 1))
	else diff=$((diff + 1)); echo "  DIFFERS: $page"; fi
done
echo "  CPU clip vs stencil clip: $same identical, $diff differ, $timed time-varying"
[ "$diff" -eq 0 ] && [ "$same" -gt 0 ]
