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
# Under set -e a failing `a && b` list only stops the script when its LAST
# command fails, so a multi-part check that fails early would pass silently:
# every such check ends in `|| fail`.
fail() { echo "  FAILED: $*"; exit 1; }
# The local servers and the netlog receiver run in the background; a run
# that stops early (a crash, a failed check) must not leave them behind, or
# the next run's frontend finds a stale receiver on its port and mirrors
# to it instead.
HTTPD=; RX=
trap 'kill $HTTPD $RX 2>/dev/null || true' EXIT
# The Vita's LAN listener (vita/remote.c) takes 8080 on the device; here
# that port may be taken, so the simulator's listener moves.
export VITA_SIM_REMOTE_PORT="${REMOTE_PORT:-45180}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK="${WORK:-$HOME/vitabrowser-work}"
NS="$WORK/applytest/upstream/netsurf"
P="$WORK/applytest/prefix"
OUT="${OUT:-$WORK/vita-sim}"
PAGES="${PAGES:-18}"

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
# The overlay's -L must come first on the link line. PKG_CONFIG_PATH order
# is not enough: pkgconf (1.8, Ubuntu 24.04) emits the engine prefix's -L
# before the overlay's, so the link took the prefix's iconv libparserutils,
# whose iconv_open always fails against the stand-in libc -- every page
# died with BADENCODING and the L1-vs-NET comparisons below passed on two
# blank pages. LDFLAGS from the environment is kept by the frontend
# Makefile's `+=`, ahead of everything pkg-config adds.
export LDFLAGS="-L$OV/lib${LDFLAGS:+ $LDFLAGS}"
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
	 welcome.html credits.html licence.html blocklist.txt; do
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
# Started on the first test page (the Vita starts on its home page), so
# page-00.png is L1 as before.
( cd "$OUT/run" && VITA_SIM_OUT="$OUT/shots" VITA_SIM_PAGES="$PAGES" \
	timeout 300 "$NS/nsvita-sim" file:///app0:/testpages/L1-layout-basics.html )
ls "$OUT"/shots
# Every page must have parsed. With the wrong libparserutils linked (see
# LDFLAGS above) each one fails with BADENCODING and draws nothing, and
# the later comparisons of blank against blank would pass. (A symbol
# check cannot tell: NetSurf's utils/utf8.c references iconv itself.)
NSLOG="$OUT/run/ux0:data/VitaBrowser/netsurf.log"
[ -f "$NSLOG" ] || fail "no netsurf.log from the page run"
nfail=$(grep -c 'hlcache content create FAILED' "$NSLOG" || true)
[ "$nfail" -eq 0 ] || fail "$nfail contents failed to create (parser/charset?)"

echo "== autotest run (reference dumps) =="
rm -rf "$OUT/run/ux0:data/VitaBrowser" "$OUT/reference" "$OUT/snaps" "$OUT/net"
if ss -Hlun 2>/dev/null | grep -q ":${NETLOG_PORT:-45199} "; then
	fail "something already listens on UDP ${NETLOG_PORT:-45199} (a stale receiver?)"
fi
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
NET-js-fetch-http http://127.0.0.1:$HP/JS-fetch.html
NET-js-fetch-https https://127.0.0.1:$((HP + 1))/JS-fetch.html
NET-dns-name http://localhost:$HP/L1-layout-basics.html
NET-dns-hang http://dead.sim-hang:$HP/L1-layout-basics.html
CSS-ovf file:///app0:/testpages/CSS-overflow-viewport.html
CSS-space file:///app0:/testpages/CSS-inline-space.html
IMG-svg file:///app0:/testpages/IMG-svg.html
CSS-mask file:///app0:/testpages/CSS-mask-icon.html
CSS-bgsizepct file:///app0:/testpages/CSS-background-size-pct.html
CSS-iswhere file:///app0:/testpages/CSS-is-where.html
CSS-bigsheet file:///app0:/testpages/CSS-rewrite-bigsheet.html
CSS-shadow file:///app0:/testpages/CSS-box-shadow.html
CSS-color file:///app0:/testpages/CSS-modern-color.html
CSS-spacing file:///app0:/testpages/CSS-spacing.html
CSS-overflow-x file:///app0:/testpages/CSS-overflow-x.html
JS-apis file:///app0:/testpages/JS-apis.html
JS-module file:///app0:/testpages/JS-module.html
JS-module-http http://127.0.0.1:$HP/JS-module.html
JS-xrealm file:///app0:/testpages/JS-xrealm.html
JS-popup file:///app0:/testpages/JS-popup.html
JS-scriptload file:///app0:/testpages/JS-scriptload.html
NET-js-streaming http://127.0.0.1:$HP/JS-streaming.html
NET-js-streaming-https https://127.0.0.1:$((HP + 1))/JS-streaming.html
NET-js-fetch-stream http://127.0.0.1:$HP/JS-fetch-stream.html
NET-js-fetch-stream-https https://127.0.0.1:$((HP + 1))/JS-fetch-stream.html
NET-js-fetch-headers http://127.0.0.1:$HP/JS-fetch-headers.html
NET-js-fetch-headers-https https://127.0.0.1:$((HP + 1))/JS-fetch-headers.html
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
	VITA_SETTLE_EXTRA_MS="${VITA_SETTLE_EXTRA_MS:-7000}" \
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
[ "$diff" -eq 0 ] && [ "$same" -gt 0 ] || fail "clip modes"

# Every file the frontend wrote must have arrived over the network,
# byte for byte, with no datagram lost.
echo "== network mirror (netlog) =="
NET=$(ls -d "$OUT"/net/net-* 2>/dev/null | tail -1)
[ -n "$NET" ] || { echo "  no boot reached the receiver"; cat "$OUT/netlog-receiver.log"; exit 1; }
same=0; bad=0
for f in "$OUT"/reference/*; do
	n=${f##*/}
	# What the mirror carries: dumps, logs, markers (not LocalStorage/,
	# the home page, bookmarks or the cookie jar).
	case "$n" in *.plot|log.txt|netsurf.log|autotest.done) ;; *) continue ;; esac
	if cmp -s "$f" "$NET/$n"; then same=$((same + 1))
	# netsurf.log is mirrored up to 4 MiB (diag.c ENGINE_NET_CAP) while
	# the card goes on to 16: past that, the mirror must be its start.
	elif [ "$n" = netsurf.log ] && [ -f "$NET/$n" ] && \
		[ "$(stat -c %s "$NET/$n")" -ge 4194304 ] && \
		cmp -s -n "$(stat -c %s "$NET/$n")" "$f" "$NET/$n"; then
		same=$((same + 1))
		echo "  netsurf.log: first $(stat -c %s "$NET/$n") of $(stat -c %s "$f") bytes mirrored (the 4 MiB cap)"
	else bad=$((bad + 1)); echo "  DIFFERS or missing: $n"; fi
done
grep -E '^datagrams' "$NET/receiver.txt" | sed 's/^/  /'
echo "  mirror vs memory card: $same identical, $bad differ"
[ "$bad" -eq 0 ] && grep -q 'received, 0 lost' "$NET/receiver.txt" && \
	! grep -qE 'INCOMPLETE|MISMATCH' "$NET/receiver.txt" || fail "network mirror"

# curl + mbedTLS: the page fetched over http and over https (trusted
# certificate) must plot exactly as the bundled file does; the rogue
# certificate must be refused.
echo "== network pages (curl + mbedTLS) =="
R="$OUT/reference"
body() { tail -n +2 "$1"; }	# line 1 names the dump
body "$R/01-L1-layout-basics.plot" > "$OUT/l1.body"
nbad=0
for n in 19-NET-http-local 20-NET-https-local; do
	if [ -f "$R/$n.plot" ] && body "$R/$n.plot" | cmp -s - "$OUT/l1.body"; then
		echo "  $n: plots as 01-L1-layout-basics"
	else
		echo "  $n: DIFFERS from 01-L1-layout-basics (or missing)"; nbad=$((nbad + 1))
	fi
done
# NetSurf's refusal is its certificate query page, titled "Privacy error".
rogue_title=$(sed -n '/page 21\/[0-9]* NET-https-rogue: navigate/,/NET-https-rogue settled/p' \
	"$R/log.txt" | sed -n 's/.*gw title: //p' | tail -1)
if [ -f "$R/21-NET-https-rogue.plot" ] && [ "$rogue_title" = "Privacy error" ] && \
   ! body "$R/21-NET-https-rogue.plot" | cmp -s - "$OUT/l1.body"; then
	echo "  21-NET-https-rogue: refused (\"$rogue_title\" page)"
else
	echo "  21-NET-https-rogue: LOADED OR MISSING"; nbad=$((nbad + 1))
fi
grep -E 'pass N summary' "$R/log.txt" | sed 's/^/  /'
grep -m1 'curl_version' "$R/netsurf.log" | sed 's/.*curl_version /  libcurl: /'
[ "$nbad" -eq 0 ]

# Scripts on a page (testpages/pages/JS-dom.html, through MacSurf's DOM
# bridge): every row turns PASS only if its script ran and the result was
# laid out, so the dump must carry the full count.
echo "== JavaScript on a page (JS-dom) =="
js_sum=$(sed -n 's/.*STR \(JS: [0-9]*\/[0-9]* passed\).*/\1/p' "$R/16-JS-dom.plot" | head -1)
echo "  16-JS-dom: ${js_sum:-no summary line (script did not run?)}"
grep -o 'STR [0-9]* [^:]*: waiting' "$R/16-JS-dom.plot" | sed 's/^STR /  still waiting: /'
[ "$js_sum" = "JS: 13/13 passed" ]

# fetch() and XMLHttpRequest (MacSurf's macos9_js_fetch.c on NetSurf's fetch
# layer): the same page over file: (bundled), http and https (curl +
# mbedTLS), each 5/5 only with real response bodies, and the local server
# must have seen the requests.
echo "== fetch() / XMLHttpRequest (JS-fetch) =="
jsf_bad=0
for n in 17-JS-fetch 22-NET-js-fetch-http 23-NET-js-fetch-https; do
	r=$(sed -n 's/.*STR \(JS fetch: [0-9]*\/[0-9]* passed\).*/\1/p' "$R/$n.plot" 2>/dev/null | head -1)
	echo "  $n: ${r:-no summary line}"
	[ "$r" = "JS fetch: 5/5 passed" ] || jsf_bad=$((jsf_bad + 1))
done
for port in "$HP" $((HP + 1)); do
	c=$(grep -c "httpd $port \"GET /fetch-data.json" "$OUT/httpd.log")
	echo "  server :$port saw $c fetch-data.json requests"
	[ "$c" -ge 4 ] || jsf_bad=$((jsf_bad + 1))
done
[ "$jsf_bad" -eq 0 ]

# Streaming transport (Patch 131, S5/B1): XHR progress (readyState 2/3,
# onprogress) and a real EventSource over the local server's /sse and
# /progress-stream endpoints. Each row of JS-streaming.html turns PASS only
# on real mid-transfer delivery / real SSE events.
echo "== streaming: XHR progress + EventSource (JS-streaming) =="
jss_bad=0
for f in "$R"/*NET-js-streaming*.plot; do
	[ -f "$f" ] || { echo "  missing: $f"; jss_bad=$((jss_bad + 1)); continue; }
	n=${f##*/}
	r=$(sed -n 's/.*STR \(JS streaming: [0-9]*\/[0-9]* passed\).*/\1/p' "$f" | head -1)
	echo "  $n: ${r:-no summary line (script did not run?)}"
	grep -o 'STR [0-9]* [^:]*: \(waiting\|FAIL\).*' "$f" | sed 's/^STR /  /'
	[ "$r" = "JS streaming: 7/7 passed" ] || jss_bad=$((jss_bad + 1))
done
[ "$(ls "$R"/*NET-js-streaming*.plot 2>/dev/null | wc -l)" -eq 2 ] || jss_bad=$((jss_bad + 1))
[ "$jss_bad" -eq 0 ]

# Streaming fetch() bodies (Patch 132, B1 part 2): Response.body as a
# ReadableStream fed while the response arrives -- getReader, for await,
# a character split across chunks, SSE parsed from a body, pipeThrough a
# TextDecoderStream, abort mid-stream, clone/json/arrayBuffer.
echo "== streaming fetch() bodies (JS-fetch-stream) =="
jfs_bad=0
for f in "$R"/*NET-js-fetch-stream*.plot; do
	[ -f "$f" ] || { echo "  missing: $f"; jfs_bad=$((jfs_bad + 1)); continue; }
	n=${f##*/}
	r=$(sed -n 's/.*STR \(JS fetch stream: [0-9]*\/[0-9]* passed\).*/\1/p' "$f" | head -1)
	echo "  $n: ${r:-no summary line (script did not run?)}"
	grep -o 'STR [0-9]* [^:]*: \(waiting\|FAIL\).*' "$f" | sed 's/^STR /  /'
	[ "$r" = "JS fetch stream: 8/8 passed" ] || jfs_bad=$((jfs_bad + 1))
done
[ "$(ls "$R"/*NET-js-fetch-stream*.plot 2>/dev/null | wc -l)" -eq 2 ] || jfs_bad=$((jfs_bad + 1))
[ "$jfs_bad" -eq 0 ]

# fetch() resolves at the header block (Patch 135): /slow-headers sends a
# complete header block, waits 2 s, then the body. The page asserts the
# promise resolved >= 1 s before the first body byte, that status/headers
# were available at resolve time, and that the body reader stayed pending
# until bytes arrived.
echo "== fetch() resolves at headers (JS-fetch-headers) =="
jfh_bad=0
for f in "$R"/*NET-js-fetch-headers*.plot; do
	[ -f "$f" ] || { echo "  missing: $f"; jfh_bad=$((jfh_bad + 1)); continue; }
	n=${f##*/}
	r=$(sed -n 's/.*STR \(JS fetch headers: [0-9]*\/[0-9]* passed\).*/\1/p' "$f" | head -1)
	echo "  $n: ${r:-no summary line (script did not run?)}"
	grep -o 'STR [0-9]* [^:]*: \(waiting\|FAIL\).*' "$f" | sed 's/^STR /  /'
	[ "$r" = "JS fetch headers: 3/3 passed" ] || jfh_bad=$((jfh_bad + 1))
done
[ "$(ls "$R"/*NET-js-fetch-headers*.plot 2>/dev/null | wc -l)" -eq 2 ] || jfh_bad=$((jfh_bad + 1))
[ "$jfh_bad" -eq 0 ]

# The bridge's window services (MACSURF_WINDOW_SERVICES, vita/js_platform.c):
# JS-window navigates itself three times (relative location.href,
# location.replace, history.back) carrying its state in localStorage, then
# checks scrolling, the viewport, title and dialogs. It only reaches its
# summary if all of that works, in every one of the autotest's passes.
echo "== window services (JS-window) =="
jsw=$(sed -n 's/.*STR \(JS window: [0-9]*\/[0-9]* passed\).*/\1/p' "$R/18-JS-window.plot" | head -1)
echo "  18-JS-window: ${jsw:-no summary line}"
grep -o 'STR [0-9]* [^:]*: \(waiting\|FAIL\).*' "$R/18-JS-window.plot" | sed 's/^STR /  /'
grep -E 'js nav: ' "$R/log.txt" | head -4 | sed 's/^\[[^]]*\] /  /'
ls "$R/LocalStorage/" 2>/dev/null | sed 's/^/  storage file: /'
[ "$jsw" = "JS window: 11/11 passed" ] && \
	[ "$(grep -c 'JS-window row 7 passed' "$R/netsurf.log")" -ge 4 ] && \
	ls "$R"/LocalStorage/l_*.json > /dev/null || fail "JS-window"

# Name lookup off the main thread (vita/resolve.c, curl_resolve.h). Hardware
# run 11: with a DNS server that never answered, curl's blocking lookup froze
# the whole browser for 30 s per page. localhost goes through the worker and
# CURLOPT_RESOLVE and must plot as the file does; a *.sim-hang name takes the
# Vita's worst case (2 s x 2) and fails -- meanwhile the main loop must keep
# running (its once-a-second load status lines), and the page must end.
echo "== name lookup off the main thread =="
dbad=0
if [ -f "$R/24-NET-dns-name.plot" ] && body "$R/24-NET-dns-name.plot" | cmp -s - "$OUT/l1.body"; then
	echo "  24-NET-dns-name: plots as 01-L1-layout-basics"
else
	echo "  24-NET-dns-name: DIFFERS (or missing)"; dbad=$((dbad + 1))
fi
grep -E 'dns: (localhost|dead\.sim-hang)' "$R/log.txt" | sed 's/^\[[^]]*\] /  /'
nstat=$(grep -c 'load status NET-dns-hang' "$R/log.txt")
echo "  main loop ran through the hanging lookup: $nstat status lines"
grep -E 'page NET-dns-hang (settled|did not settle)' "$R/log.txt" | sed 's/^\[[^]]*\] /  /' | cut -c1-120
grep -q 'dns: localhost -> 127.0.0.1' "$R/log.txt" || dbad=$((dbad + 1))
grep -q 'dns: dead\.sim-hang -> FAILED' "$R/log.txt" || dbad=$((dbad + 1))
[ "$nstat" -ge 3 ] || dbad=$((dbad + 1))
grep -q 'page NET-dns-hang settled' "$R/log.txt" || dbad=$((dbad + 1))
[ "$dbad" -eq 0 ] || fail "name lookup"

# The controls, scripted (vita/interact.c, after pass N): taps, the
# pointer, back / forward, drag scrolling, zoom, blocked hosts, a form
# filled in, a typed URL, a URL pushed to the LAN listener, the cookie jar,
# home. Every step is checked by the frontend itself.
echo "== interaction pass (browsing controls) =="
grep -E 'interact: [0-9]+ .*: (PASS|FAIL)' "$R/log.txt" | sed 's/^\[[^]]*\] /  /' | cut -c1-140
isum=$(sed -n 's/.*interact: \([0-9]*\/[0-9]*\) passed.*/\1/p' "$R/log.txt" | tail -1)
echo "  interaction: ${isum:-no summary} passed"
iblk=$(sed -n 's/.*STR \(IN block: [0-9]*\/[0-9]* passed\).*/\1/p' "$R/IN-block.plot" 2>/dev/null | head -1)
echo "  IN-block dump: ${iblk:-missing}"
grep -h 'font: .* batched draws' "$R/log.txt" | tail -1 | sed 's/^\[[^]]*\] /  /'
grep -c '<a href="https://' "$R/home.html" | sed 's/^/  home page bookmarks: /'
[ -n "$isum" ] && [ "${isum%/*}" = "${isum#*/}" ] && \
	[ "$iblk" = "IN block: 2/2 passed" ] && [ -f "$R/IN-zoom125.plot" ] && \
	[ -f "$R/IN-form-sent.plot" ] && \
	[ "$(grep -c '<a href="https://' "$R/home.html")" -ge 5 ] || fail "interaction pass"

# Layout found on real sites (docs/phase-0/11), as regression pages among
# pass N's: body's overflow goes to the viewport (patch 56: the page must be
# far taller than the screen), and a space leading an inline's text keeps
# its width (patch 57: each word lands where its space-outside twin does).
echo "== real-site layout regressions =="
ext=$(sed -n 's/.*page CSS-ovf settled: .*extent 960x\([0-9]*\).*/\1/p' "$R/log.txt" | head -1)
echo "  CSS-ovf: page height ${ext:-?} (the screen is 544)"
sp=$(ls "$R"/*-CSS-space.plot 2>/dev/null | head -1)
xpos() { sed -n "s/^PLOT TEXT X \([0-9]*\) Y [0-9]* STR $1\$/\1/p" "$sp" | head -1; }
b1=$(xpos BRAVO1); b2=$(xpos BRAVO2); c1=$(xpos CHARLIE1); c2=$(xpos CHARLIE2)
echo "  CSS-space: BRAVO at x $b1 / $b2, CHARLIE at x $c1 / $c2"
# SVG (libsvgtiny + libdom's expat binding): the logo and the CSS icon draw
# as paths, and the logo's alt text -- drawn only if the image is refused --
# never appears.
sv=$(ls "$R"/*-IMG-svg.plot 2>/dev/null | head -1)
npath=$(grep -c '^PLOT PATH' "$sv" 2>/dev/null || true)
echo "  IMG-svg: ${npath:-0} paths drawn$(grep -q LOGO-NOT-DRAWN "$sv" 2>/dev/null && echo ', ALT TEXT SHOWN')"
# mask-image icons (patch 60): the two masked spans draw their SVG icon,
# not a 24x24 block; only the two unmasked ones (-webkit-mask with a size,
# which the background shorthand cannot take, and mask-image: none) do.
mk=$(ls "$R"/*-CSS-mask.plot 2>/dev/null | head -1)
# PLOT RECT X0 x0 Y0 y0 X1 x1 Y1 y1
nblk=$(awk '/^PLOT RECT/ { if ($8 - $4 == 24 && $10 - $6 == 24) n++ } END { print n + 0 }' "$mk" 2>/dev/null)
echo "  CSS-mask: $nblk solid 24x24 blocks (2 expected: the unmasked spans)"
[ "$nblk" = 2 ] || fail "mask-image icons"
# background-size percentages (patches 89, 90): each of the five 300x200 boxes
# with the 100x50 image draws its background at the sized tile; the
# no-repeat boxes each emit one PLOT BITMAP of exactly that size.
bp=$(ls "$R"/*-CSS-bgsizepct.plot 2>/dev/null | head -1)
nb1=$(grep -c "^PLOT BITMAP X .* Y .* WIDTH 300 HEIGHT 200$" "$bp" 2>/dev/null || true)
nb2=$(grep -c "^PLOT BITMAP X .* Y .* WIDTH 150 HEIGHT 100$" "$bp" 2>/dev/null || true)
nb3=$(grep -c "^PLOT BITMAP X .* Y .* WIDTH 450 HEIGHT 225$" "$bp" 2>/dev/null || true)
nb4=$(grep -c "^PLOT BITMAP X .* Y .* WIDTH 99 HEIGHT 50$" "$bp" 2>/dev/null || true)
echo "  CSS-bgsizepct: 100%=$nb1 50%=$nb2 150%=$nb3 33%x25%=$nb4 (1 each expected)"
[ "${nb1:-0}" = 1 ] && [ "${nb2:-0}" = 1 ] && [ "${nb3:-0}" = 1 ] && [ "${nb4:-0}" = 1 ] || fail "background-size percentages"
# The 320x200 gradient box at 50% 50% tiles: its stripes are 160 wide in two
# columns, and none spans the whole 320 (an untiled gradient would).
g160=$(awk '/^PLOT RECT/ && $8 - $4 == 160 && $10 - $6 < 20 { print $4 }' "$bp" 2>/dev/null | sort -u | wc -l)
g320=$(awk '/^PLOT RECT/ && $8 - $4 == 320 && $10 - $6 > 1 && $10 - $6 < 20 { n++ } END { print n + 0 }' "$bp" 2>/dev/null)
echo "  CSS-bgsizepct gradient: $g160 tile columns of 160, $g320 full-width stripes (2, 0 expected)"
[ "$g160" = 2 ] && [ "$g320" = 0 ] || fail "background-size percentage gradient"
# :is() / :where() (patch 91): each case that matches draws one 10px-high
# block of its own width; 105 must not match, 197-199 must lose.
iw=$(ls "$R"/*-CSS-iswhere.plot 2>/dev/null | head -1)
iws=$(awk '/^PLOT RECT/ && $10 - $6 == 10 && $8 - $4 < 300 { print $8 - $4 }' "$iw" 2>/dev/null | sort -n | tr '\n' ' ')
echo "  CSS-iswhere: block widths [$iws] (101 102 103 104 106 107 108 109 expected)"
[ "$iws" = "101 102 103 104 106 107 108 109 " ] || fail ":is() / :where()"
# CSS rewrite on a big sheet (patch 92): inset expands, and calc(1 * -1)
# folds to an integer so flex order moves the 122-wide item first.
bs=$(ls "$R"/*-CSS-bigsheet.plot 2>/dev/null | head -1)
bsf=$(awk '/^PLOT RECT/ && $8 - $4 == 333 && $10 - $6 == 44 { n++ } END { print n + 0 }' "$bs" 2>/dev/null)
bsa=$(awk '/^PLOT RECT/ && $8 - $4 == 111 && $10 - $6 == 12 { print $4; exit }' "$bs" 2>/dev/null)
bsb=$(awk '/^PLOT RECT/ && $8 - $4 == 122 && $10 - $6 == 12 { print $4; exit }' "$bs" 2>/dev/null)
echo "  CSS-bigsheet: inset fill $bsf (1 expected); order: 122-wide at x=${bsb:-?}, 111-wide at x=${bsa:-?} (122 first expected)"
[ "$bsf" = 1 ] && [ -n "$bsa" ] && [ -n "$bsb" ] && [ "$bsb" -lt "$bsa" ] || fail "CSS rewrite on a big sheet"
# box-shadow lists, rings, spread; sub-pixel, translucent and rounded
# borders (patches 96, 97, 99, 100). rects W H [BUCKET]: how many PLOT RECTs
# of that size, at that opacity bucket (none = solid).
rects() {
	awk -v w="$2" -v h="$3" -v b="${4:-}" '/^PLOT RECT/ && $8 - $4 == w &&
		$10 - $6 == h && ((b == "" && NF == 10) || $12 == b) { n++ }
		END { print n + 0 }' "$1" 2>/dev/null
}
bxplot=$(ls "$R"/*-CSS-shadow.plot 2>/dev/null | head -1)
bxs1=$(rects "$bxplot" 222 1); bxs2=$(rects "$bxplot" 239 3); bxs3=$(rects "$bxplot" 244 2)
bxs4=$(rects "$bxplot" 255 1 2); bxs5=$(awk '/^PLOT RECT/ && $8 - $4 == 266 && $10 - $6 <= 2 { n++ } END { print n + 0 }' "$bxplot" 2>/dev/null)
bxb1=$(rects "$bxplot" 277 1); bxb2=$(rects "$bxplot" 288 1 2)
echo "  CSS-shadow: ring $bxs1, spread $bxs2, list+initial $bxs3, hsl(from) ring $bxs4 (2 each); invalid $bxs5 (0)"
# (MacSurf's old rounded-box frame was a stroke, and the plot stream records
# fills only, so its absence is not checkable here; bxb2 proves rounded
# boxes now reach the border painter.)
echo "  CSS-shadow borders: 0.5px $bxb1 (2), rounded 50% $bxb2 (2)"
[ "$bxs1" = 2 ] && [ "$bxs2" = 2 ] && [ "$bxs3" = 2 ] && [ "$bxs4" = 2 ] && [ "$bxs5" = 0 ] &&
	[ "$bxb1" = 2 ] && [ "$bxb2" = 2 ] || fail "box-shadow / borders"
# Modern colour syntax and at-rules (patches 94, 95, 98, 99): each block
# drawn once, at the expected opacity bucket.
clplot=$(ls "$R"/*-CSS-color.plot 2>/dev/null | head -1)
clres=""
for clspec in 101:2 102:1 103: 104:3 105: 106: 107: 108: 109:; do
	clres="$clres $(rects "$clplot" "${clspec%%:*}" 10 "${clspec#*:}")"
done
echo "  CSS-color: blocks at the expected opacity [$clres ] (9 x 1)"
[ "$clres" = " 1 1 1 1 1 1 1 1 1" ] || fail "modern colour syntax / at-rules"
# Tailwind's spacing layer (patches 101-108): gap calc, :root,:host
# variables, @supports for absent features, inline calc, flex buttons,
# abs children of flex containers, border-radius vs bottom, @media width.
spplot=$(ls "$R"/*-CSS-spacing.plot 2>/dev/null | head -1)
spx() { awk -v w="$1" -v h="$2" '/^PLOT RECT/ && $8 - $4 == w && $10 - $6 == h { print $4, $6; exit }' "$spplot" 2>/dev/null; }
read -r spa1 spa2 spb1 spb2 <<SPEOF
$(spx 31 10) $(spx 32 10)
SPEOF
spgap=$(( ${spb1:-0} - ${spa1:-0} ))
sph=""
for spw in 141 142 143 144 145; do
	sph="$sph $(awk -v w=$spw '/^PLOT RECT/ && $8 - $4 == w { print $10 - $6; exit }' "$spplot" 2>/dev/null)"
done
read -r spc1 spc2 spd1 spd2 <<SPEOF
$(spx 198 1) $(spx 37 10)
SPEOF
spbx=$(( ${spd1:-0} - ${spc1:-0} )); spby=$(( ${spd2:-0} - ${spc2:-0} ))
echo "  CSS-spacing: gap $spgap (51); :host var $(rects "$spplot" 120 11) (1); iOS @supports $(rects "$spplot" 133 11)/$(rects "$spplot" 333 11) (1/0)"
echo "  CSS-spacing: inline calc heights [$sph ] ([ 2 4 6 8 10 ]); button child at +$spbx,+$spby (80|81,15)"
echo "  CSS-spacing: abs in flex $(rects "$spplot" 170 50) (1); radius+bottom $(rects "$spplot" 11 36) (1); @media $(rects "$spplot" 188 11)/$(rects "$spplot" 88 11) (1/0)"
# Round 10: range-syntax media queries -- (width>=350px) and the double
# range apply at the 960-wide viewport, (width>=961px) must not.
echo "  CSS-spacing: range media $(rects "$spplot" 251 11)/$(rects "$spplot" 253 11) (1/1); width>=961px $(rects "$spplot" 252 11) (0)"
[ "$spgap" = 51 ] && [ "$(rects "$spplot" 120 11)" = 1 ] &&
	[ "$(rects "$spplot" 133 11)" = 1 ] && [ "$(rects "$spplot" 333 11)" = 0 ] &&
	[ "$sph" = " 2 4 6 8 10" ] && { [ "$spbx" = 80 ] || [ "$spbx" = 81 ]; } &&
	[ "$spby" = 15 ] && [ "$(rects "$spplot" 170 50)" = 1 ] &&
	[ "$(rects "$spplot" 11 36)" = 1 ] && [ "$(rects "$spplot" 188 11)" = 1 ] &&
	[ "$(rects "$spplot" 88 11)" = 0 ] &&
	[ "$(rects "$spplot" 251 11)" = 1 ] && [ "$(rects "$spplot" 253 11)" = 1 ] &&
	[ "$(rects "$spplot" 252 11)" = 0 ] || fail "spacing / calc / layout"
# No horizontal overflow (patches 64, 65): an unbreakable URL in break-word
# text, and a min-width button in Minerva's header arrangement.
xw=$(sed -n 's/.*page CSS-overflow-x settled: .*extent \([0-9]*\)x.*/\1/p' "$R/log.txt" | head -1)
echo "  CSS-overflow-x: page width ${xw:-?} (the screen is 960)"
[ "$xw" = 960 ] || fail "horizontal overflow"

# The web platform census (patch 73) and ES modules (patches 71, 72): from
# app0: through the module loader's file path, and over http through
# fetch_get_blocking's curl transfers.
echo "== web APIs and ES modules =="
ap=$(ls "$R"/*-JS-apis.plot 2>/dev/null | head -1)
apis=$(sed -n 's/.*STR \(APIS: [0-9]*\/[0-9]* present\).*/\1/p' "$ap" 2>/dev/null | head -1)
beh=$(sed -n 's/.*STR \(behaviour: [0-9]*\/[0-9]* right\).*/\1/p' "$ap" 2>/dev/null | head -1)
echo "  JS-apis: ${apis:-no summary (script did not run?)}, ${beh:-no behaviour line}"
napi=$(echo "$apis" | sed -n 's/APIS: \([0-9]*\)\/.*/\1/p')
[ "${napi:-0}" -ge 149 ] && [ "$beh" = "behaviour: 10/10 right" ] || fail "web API census"
# Cross-realm frames (patch 126): an iframe is its own JS runtime; the two
# talk through postMessage, which crosses as JSON text only.
xp=$(ls "$R"/*-JS-xrealm.plot 2>/dev/null | head -1)
xs=$(sed -n 's/.*STR \(XREALM: [0-9]*\/[0-9]* passed\).*/\1/p' "$xp" 2>/dev/null | tail -1)
echo "  JS-xrealm: ${xs:-no summary (script did not run?)}"
[ "$xs" = "XREALM: 4/4 passed" ] || fail "cross-realm postMessage"
# window.open popups (patch 127) and script load events (patch 128).
for m in POPUP:JS-popup SCRIPTLOAD:JS-scriptload; do
	k=${m%%:*}; pg=${m#*:}
	pp=$(ls "$R"/*-"$pg".plot 2>/dev/null | head -1)
	ps=$(sed -n "s/.*STR \($k: [0-9]*\/[0-9]* passed\).*/\1/p" "$pp" 2>/dev/null | tail -1)
	echo "  $pg: ${ps:-no summary (script did not run?)}"
	[ "$ps" = "$k: 4/4 passed" ] || fail "$pg"
done
for m in JS-module JS-module-http; do
	mp=$(ls "$R"/*-"$m".plot 2>/dev/null | head -1)
	ms=$(sed -n 's/.*STR \(MODULES: [0-9]*\/[0-9]* passed\).*/\1/p' "$mp" 2>/dev/null | head -1)
	echo "  $m: ${ms:-no summary (module did not run?)}"
	[ "$ms" = "MODULES: 6/6 passed" ] || fail "ES modules ($m)"
done

[ -n "$ext" ] && [ "$ext" -gt 1500 ] && [ -n "$b1" ] && [ "$b1" = "$b2" ] && \
	[ -n "$c1" ] && [ "$c1" = "$c2" ] && [ "${npath:-0}" -ge 5 ] && \
	! grep -q LOGO-NOT-DRAWN "$sv" || fail "real-site layout regressions"

# The network probe (frontends/vita/netprobe.c) before pass N: against the
# local servers every step must succeed, with curl's own verdict logged.
echo "== network probe =="
grep -E 'netprobe: (getaddrinfo .* ->|connect|curl)' "$R/log.txt" | sed 's/^\[[^]]*\] /  /' | cut -c1-150
grep -q 'netprobe: connect .*: connected' "$R/log.txt" && \
	[ "$(grep -c 'netprobe: curl .*: OK (0)' "$R/log.txt")" -eq 2 ] || fail "network probe"

# The QuickJS engine probe (frontends/vita/jsprobe.c) at the autotest's end.
echo "== QuickJS engine probe =="
grep -E 'js: (QuickJS|FAIL|engine|probe took)' "$R/log.txt" | sed 's/^\[[^]]*\] /  /'
grep -q 'js: probe took .*: \([0-9]*\)/\1 checks' "$R/log.txt" && \
	! grep -q 'js: FAIL' "$R/log.txt" || fail "QuickJS probe"


# The autotest again at the Vita's pace (tools/vita-sim VITA_SIM_SLOW_MS: every
# main-loop pass takes 40 ms longer, so loads take the device's 1-2 s while
# page timers stay wall-clock). Hardware run 12: JS-window passed here at
# full speed and failed on the Vita, because the autotest judged a page
# settled the moment its frameless load ended, before its own timers ran.
# Every bundled page must dump exactly as it did at full speed (bar the
# time-varying animation), and JS-window must finish in every pass.
# This run also draws text the old way, one quad per glyph
# (VITA_SIM_TEXT_UNBATCHED), so its frames must match the batched run's
# pixel for pixel: the check that caught batching drawing a "9" as an "A".
echo "== at the Vita's pace (VITA_SIM_SLOW_MS=40), text unbatched =="
S2="$OUT/slow"
rm -rf "$S2"; mkdir -p "$S2/ux0:data/VitaBrowser"
cp -r "$OUT/run/app0:" "$S2/"
echo off > "$S2/ux0:data/VitaBrowser/netlog.cfg"
python3 "$ROOT/tools/vita-sim/httpd.py" --dir "$ROOT/testpages/pages" \
	--http "$HP" > "$OUT/httpd-slow.log" 2>&1 &
HTTPD=$!
echo "NET-http-local http://127.0.0.1:$HP/L1-layout-basics.html" \
	> "$S2/ux0:data/VitaBrowser/nettest.txt"
mkdir -p "$S2/snaps"
( cd "$S2" && VITA_SIM_SLOW_MS=40 VITA_SIM_TEXT_UNBATCHED=1 VITA_SIM_AUTOTEST=1 \
	VITA_SIM_SNAP="$S2/snaps" timeout 1200 "$NS/nsvita-sim" \
	> "$S2/stdout.log" 2>&1 ) || fail "slow autotest run"
kill $HTTPD 2>/dev/null || true
same=0; bad=0
for f in "$R"/[01]*.plot; do
	n=${f##*/}
	case "$n" in 07-PM-animation*) continue ;; esac
	if cmp -s "$f" "$S2/ux0:data/VitaBrowser/$n"; then same=$((same + 1))
	else bad=$((bad + 1)); echo "  DIFFERS at the Vita's pace: $n"; fi
done
echo "  bundled pages at the Vita's pace vs full speed: $same identical, $bad differ"
jsw_slow=$(grep -c 'JS-window row 7 passed' "$S2/ux0:data/VitaBrowser/netsurf.log")
echo "  JS-window finished in $jsw_slow of 4 passes"
psame=0; pbad=0
for f in "$OUT"/snaps/[ABCD]-*.png; do
	n=${f##*/}
	case "$n" in *PM-animation*) continue ;; esac
	if cmp -s "$f" "$S2/snaps/$n"; then psame=$((psame + 1))
	else pbad=$((pbad + 1)); echo "  PIXELS DIFFER, batched vs per glyph: $n"; fi
done
echo "  text batched vs one draw per glyph: $psame frames identical, $pbad differ"
[ "$pbad" -eq 0 ] && [ "$psame" -gt 0 ] || fail "text batching pixels"
isum_slow=$(sed -n 's/.*interact: \([0-9]*\/[0-9]*\) passed.*/\1/p' "$S2/ux0:data/VitaBrowser/log.txt" | tail -1)
echo "  interaction pass at the Vita's pace: ${isum_slow:-no summary} passed"
[ "$bad" -eq 0 ] && [ "$same" -gt 0 ] && [ "$jsw_slow" -ge 4 ] && \
	[ -n "$isum_slow" ] && [ "${isum_slow%/*}" = "${isum_slow#*/}" ] || fail "at the Vita's pace"
