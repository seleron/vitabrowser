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
# ...with the Vita's FreeType release, so text measures as on the device,
# and its curl + mbedTLS and CA bundle, so HTTPS verifies as on the device.
WORK="$WORK" "$ROOT/tools/build-host-freetype.sh"
WORK="$WORK" "$ROOT/tools/build-host-curl.sh"
WORK="$WORK" "$ROOT/tools/fetch-certs.sh"
# ...and QuickJS-ng (tools/build-quickjs.sh), whose probe the autotest runs.
WORK="$WORK" "$ROOT/tools/build-quickjs.sh" host
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
export PKG_CONFIG_PATH="$WORK/host-curl/lib/pkgconfig:$WORK/host-freetype/lib/pkgconfig:$OV/lib/pkgconfig:$P/lib/pkgconfig"
export CFLAGS="-I$P/include/libutf8proc -I$ROOT/compat \
-include macsurf_core_decls.h -Wno-error=unused-variable -Wno-error=comment -Wno-error=nested-externs -Wno-error=redundant-decls -Wno-error=missing-prototypes -Wno-error=implicit-function-declaration -Wno-error=int-conversion -DVITABROWSER_ENGINE_TRACE"
rm -f "$NS/nsvita-sim"	# the overlay changed under it; force the relink
( cd "$NS" && make TARGET=vita VITA_HOST_SIM=YES \
	VITA_SIM_INCLUDE="$ROOT/tools/vita-stub" VITA_SIM_LIB="$OUT/libvitasim.a" \
	VITA_SIM_QUICKJS="$WORK/host-quickjs" \
	-j4 > "$OUT/build.log" 2>&1 ) \
  || { echo "  build FAILED"; grep -m8 -E 'error|undefined' "$OUT/build.log"; exit 1; }
echo "  nsvita-sim ok"

echo "== app0: bundle =="
A="$OUT/run/app0:"
rm -rf "$A"
mkdir -p "$A/res" "$A/testpages"
rm -rf "$OUT/run/ux0:data"
mkdir -p "$OUT/run/ux0:data/VitaBrowser"
# No network mirror for the screenshot run (and it tests netlog.cfg "off").
echo off > "$OUT/run/ux0:data/VitaBrowser/netlog.cfg"
for f in default.css quirks.css adblock.css internal.css Messages \
	 welcome.html credits.html licence.html; do
	cp -L "$NS/frontends/vita/res/$f" "$A/res/$f"
done
cp "$ROOT"/testpages/pages/* "$A/testpages/"

# The network pages' servers (tools/vita-sim/httpd.py): a throwaway test CA,
# a certificate for 127.0.0.1 signed by it, and a rogue self-signed one.
# The simulator's ca-bundle.pem is Mozilla's plus the test CA.
T="$OUT/tls"
rm -rf "$T"; mkdir -p "$T"
( cd "$T" && \
  openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem \
    -days 30 -subj "/CN=VitaBrowser simulator test CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" && \
  openssl req -newkey rsa:2048 -nodes -keyout leaf.key -out leaf.csr \
    -subj "/CN=127.0.0.1" && \
  printf 'subjectAltName=IP:127.0.0.1\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n' > leaf.ext && \
  openssl x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
    -out leaf.pem -days 30 -extfile leaf.ext && \
  openssl req -x509 -newkey rsa:2048 -nodes -keyout rogue.key -out rogue.pem \
    -days 30 -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1" \
  ) > "$OUT/tls.log" 2>&1 || { echo "  test certificates FAILED"; cat "$OUT/tls.log"; exit 1; }
cat "$WORK/certs/ca-bundle.pem" "$T/ca.pem" > "$A/res/ca-bundle.pem"
mkdir -p "$A/res/fonts"
cp "$WORK"/fonts/*.ttf "$WORK"/fonts/LICENSE-*.txt "$A/res/fonts/"

echo "== run: $PAGES pages =="
( cd "$OUT/run" && VITA_SIM_OUT="$OUT/shots" VITA_SIM_PAGES="$PAGES" \
	timeout 300 "$NS/nsvita-sim" )
ls "$OUT"/shots

echo "== autotest run (reference dumps) =="
rm -rf "$OUT/run/ux0:data/VitaBrowser" "$OUT/reference" "$OUT/snaps" "$OUT/net"
mkdir -p "$OUT/snaps" "$OUT/run/ux0:data/VitaBrowser"
# The network mirror (frontends/vita/netlog.c) goes to a receiver on this
# machine: the same code path as on the Vita after a receiver answers.
NETLOG_PORT="${NETLOG_PORT:-45199}"
echo "127.0.0.1:$NETLOG_PORT" > "$OUT/run/ux0:data/VitaBrowser/netlog.cfg"
# Pass N's network pages: the same page as 01 over http, over https with a
# trusted certificate, and over https with a rogue one.
HP="${HTTPD_PORT:-45280}"
cat > "$OUT/run/ux0:data/VitaBrowser/nettest.txt" <<NET
NET-http-local http://127.0.0.1:$HP/L1-layout-basics.html
NET-https-local https://127.0.0.1:$((HP + 1))/L1-layout-basics.html
NET-https-rogue https://127.0.0.1:$((HP + 2))/L1-layout-basics.html
NET
python3 "$ROOT/tools/vita-sim/httpd.py" --dir "$ROOT/testpages/pages" \
	--http "$HP" --https $((HP + 1)) "$T/leaf.pem" "$T/leaf.key" \
	--https-bad $((HP + 2)) "$T/rogue.pem" "$T/rogue.key" \
	> "$OUT/httpd.log" 2>&1 &
HTTPD=$!
# The receiver starts LATE, as it did not start at all in hardware run 6:
# 15 s into the autotest, with log lines and dumps already sent to nobody.
# When it answers the next hello, the frontend re-sends this launch's files
# (vita/diag.c catch_up), so the mirror must still come out complete.
( sleep "${NETLOG_LATE:-15}"; exec python3 "$ROOT/tools/vita-netlog.py" \
	--port "$NETLOG_PORT" --bind 127.0.0.1 --out "$OUT/net" --quiet \
	--exit-when-done --timeout 1000 ) > "$OUT/netlog-receiver.log" 2>&1 &
RX=$!
( cd "$OUT/run" && VITA_SIM_AUTOTEST=1 VITA_SIM_SNAP="$OUT/snaps" \
	timeout 900 "$NS/nsvita-sim" )
wait $RX || true
kill $HTTPD 2>/dev/null || true
cp -r "$OUT/run/ux0:data/VitaBrowser" "$OUT/reference"
rm -f "$OUT/reference/netlog.cfg" "$OUT/reference/nettest.txt"
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

# Every file the frontend wrote must have arrived over the network,
# byte for byte, with no datagram lost.
echo "== network mirror (netlog) =="
NET=$(ls -d "$OUT"/net/net-* 2>/dev/null | tail -1)
[ -n "$NET" ] || { echo "  no boot reached the receiver"; cat "$OUT/netlog-receiver.log"; exit 1; }
same=0; bad=0
for f in "$OUT"/reference/*; do
	n=${f##*/}
	if cmp -s "$f" "$NET/$n"; then same=$((same + 1))
	else bad=$((bad + 1)); echo "  DIFFERS or missing: $n"; fi
done
grep -E '^datagrams' "$NET/receiver.txt" | sed 's/^/  /'
echo "  mirror vs memory card: $same identical, $bad differ"
[ "$bad" -eq 0 ] && grep -q 'received, 0 lost' "$NET/receiver.txt" && \
	! grep -qE 'INCOMPLETE|MISMATCH' "$NET/receiver.txt"

# curl + mbedTLS: the page fetched over http and over https (trusted
# certificate) must plot exactly as the bundled file does; the rogue
# certificate must be refused.
echo "== network pages (curl + mbedTLS) =="
R="$OUT/reference"
body() { tail -n +2 "$1"; }	# line 1 names the dump
body "$R/01-L1-layout-basics.plot" > "$OUT/l1.body"
nbad=0
for n in 16-NET-http-local 17-NET-https-local; do
	if [ -f "$R/$n.plot" ] && body "$R/$n.plot" | cmp -s - "$OUT/l1.body"; then
		echo "  $n: plots as 01-L1-layout-basics"
	else
		echo "  $n: DIFFERS from 01-L1-layout-basics (or missing)"; nbad=$((nbad + 1))
	fi
done
# NetSurf's refusal is its certificate query page, titled "Privacy error".
rogue_title=$(sed -n '/page 18\/18 NET-https-rogue: navigate/,/NET-https-rogue settled/p' \
	"$R/log.txt" | sed -n 's/.*gw title: //p' | tail -1)
if [ -f "$R/18-NET-https-rogue.plot" ] && [ "$rogue_title" = "Privacy error" ] && \
   ! body "$R/18-NET-https-rogue.plot" | cmp -s - "$OUT/l1.body"; then
	echo "  18-NET-https-rogue: refused (\"$rogue_title\" page)"
else
	echo "  18-NET-https-rogue: LOADED OR MISSING"; nbad=$((nbad + 1))
fi
grep -E 'pass N summary' "$R/log.txt" | sed 's/^/  /'
grep -m1 'curl_version' "$R/netsurf.log" | sed 's/.*curl_version /  libcurl: /'
[ "$nbad" -eq 0 ]

# The QuickJS engine probe (frontends/vita/jsprobe.c) at the autotest's end.
echo "== QuickJS engine probe =="
grep -E 'js: (QuickJS|FAIL|engine|probe took)' "$R/log.txt" | sed 's/^\[[^]]*\] /  /'
grep -q 'js: probe took .*: \([0-9]*\)/\1 checks' "$R/log.txt" && \
	! grep -q 'js: FAIL' "$R/log.txt"

