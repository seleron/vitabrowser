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

# A window's first page joins its session history only when it is ready,
# and its scripts may read history.length while it parses: that walked the
# empty history (m.youtube.com, SIGSEGV; patch 231). Started ON the page,
# so it is the window's first; the page puts the length in its title.
echo "== history.length while a window's first page parses =="
HF="$OUT/histfirst"
rm -rf "$HF"; mkdir -p "$HF/ux0:data/VitaBrowser"
cp -r "$A" "$HF/"
echo off > "$HF/ux0:data/VitaBrowser/netlog.cfg"
hrc=0
( cd "$HF" && VITA_SIM_OUT="$HF" VITA_SIM_PAGES=1 \
	timeout 120 "$NS/nsvita-sim" file:///app0:/testpages/JS-history-first.html \
	> "$HF/stdout.log" 2>&1 ) || hrc=$?
hft=$(sed -n 's/.*gw title: \(HISTFIRST .*\)/\1/p' "$HF/ux0:data/VitaBrowser/log.txt" 2>/dev/null | tail -1)
echo "  JS-history-first: exit $hrc, title ${hft:-none} (Chromium: HISTFIRST 1)"
[ "$hrc" -eq 0 ] && [ "$hft" = "HISTFIRST 1" ] || fail "history.length on a window's first page"

echo "== autotest run (reference dumps) =="
rm -rf "$OUT/run/ux0:data/VitaBrowser" "$OUT/reference" "$OUT/snaps" "$OUT/net"
# the download gate checks this run's file, not one an earlier run left.
# ux0:download is made a plain FILE: every VPK is a safe eboot, which cannot
# create ux0:download/ (hardware run 27, errno 2), so the simulator takes
# the device's path -- the fallback to ux0:data/VitaBrowser/downloads/.
rm -rf "$OUT/run/ux0:download"
: > "$OUT/run/ux0:download"
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
CSS-inline-grid file:///app0:/testpages/CSS-inline-grid.html
CSS-opacity file:///app0:/testpages/CSS-opacity-group.html
CSS-census file:///app0:/testpages/CSS-census.html
CSS-intrinsic file:///app0:/testpages/CSS-intrinsic-width.html
JS-event-order file:///app0:/testpages/JS-event-order.html
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
NET-js-history-http http://127.0.0.1:$HP/JS-history.html
NET-js-history-https https://127.0.0.1:$((HP + 1))/JS-history.html
NET-js-storage-http http://127.0.0.1:$HP/JS-storage.html
NET-js-storage-https https://127.0.0.1:$((HP + 1))/JS-storage.html
NET-js-mutation-http http://127.0.0.1:$HP/JS-mutation.html
NET-js-mutation-https https://127.0.0.1:$((HP + 1))/JS-mutation.html
NET-js-fetch-body-http http://127.0.0.1:$HP/JS-fetch-body.html
NET-js-fetch-body-https https://127.0.0.1:$((HP + 1))/JS-fetch-body.html
NET-js-frame-local http://127.0.0.1:$HP/JS-frame-local.html
NET-js-interfaces http://127.0.0.1:$HP/JS-interfaces.html
NET-js-module-async http://127.0.0.1:$HP/JS-module-async.html
NET-js-module-static-async http://127.0.0.1:$HP/JS-module-static-async.html
NET-js-module-dedupe http://127.0.0.1:$HP/JS-module-dedupe.html
NET-js-lazyimg http://127.0.0.1:$HP/JS-lazyimg.html
NET-js-reflow-stall http://127.0.0.1:$HP/JS-reflow-stall.html
NET-js-parse-tail http://127.0.0.1:$HP/JS-parse-tail.html
NET-js-dom-stall http://127.0.0.1:$HP/JS-dom-stall.html
NET-js-cssom http://127.0.0.1:$HP/JS-cssom.html
NET-js-cssom-190 http://127.0.0.1:$HP/JS-cssom-190.html
NET-js-abspos191 http://127.0.0.1:$HP/JS-abspos191.html
NET-js-innertext http://127.0.0.1:$HP/JS-innertext.html
NET-js-sanitize http://127.0.0.1:$HP/JS-sanitize.html
NET-js-class-stall http://127.0.0.1:$HP/JS-class-stall.html
NET-js-block-class-stall http://127.0.0.1:$HP/JS-block-class-stall.html
NET-js-block-class-sibling http://127.0.0.1:$HP/JS-block-class-sibling.html
NET-css-sibling-class http://127.0.0.1:$HP/CSS-sibling-class.html
NET-js-list-nested-stall http://127.0.0.1:$HP/JS-list-nested-stall.html
NET-js-list-structural http://127.0.0.1:$HP/JS-list-structural.html
NET-js-block-sibling-insert http://127.0.0.1:$HP/JS-block-sibling-insert.html
NET-js-has193 http://127.0.0.1:$HP/JS-has193.html
NET-js-flex-stretch-maxheight http://127.0.0.1:$HP/JS-flex-stretch-maxheight.html
NET-js-flex195 http://127.0.0.1:$HP/JS-flex195.html
NET-js-appearance196 http://127.0.0.1:$HP/JS-appearance196.html
NET-js-selectors http://127.0.0.1:$HP/JS-selectors.html
NET-js-chardata http://127.0.0.1:$HP/JS-chardata.html
NET-css-flex-header http://127.0.0.1:$HP/CSS-flex-header.html
NET-css-account-bar http://127.0.0.1:$HP/CSS-account-bar.html
NET-css-appearance http://127.0.0.1:$HP/CSS-appearance.html
NET-css-table-caption http://127.0.0.1:$HP/CSS-table-caption.html
NET-js-inline-rect http://127.0.0.1:$HP/JS-inline-rect.html
NET-html-hidden-details http://127.0.0.1:$HP/HTML-hidden-details.html
NET-css-flow-root http://127.0.0.1:$HP/CSS-flow-root.html
NET-css-grid-autofill http://127.0.0.1:$HP/CSS-grid-autofill.html
NET-css-viewport-units http://127.0.0.1:$HP/CSS-viewport-units.html
NET-css-line-clamp http://127.0.0.1:$HP/CSS-line-clamp.html
NET-css-ch-unit http://127.0.0.1:$HP/CSS-ch-unit.html
NET-css-nesting http://127.0.0.1:$HP/CSS-nesting.html
NET-js-computed-alpha http://127.0.0.1:$HP/JS-computed-alpha.html
NET-css-media-features http://127.0.0.1:$HP/CSS-media-features.html
NET-css-line-height-normal http://127.0.0.1:$HP/CSS-line-height-normal.html
NET-js-crypto-subtle http://127.0.0.1:$HP/JS-crypto-subtle.html
NET-css-supports-absent http://127.0.0.1:$HP/CSS-supports-absent.html
NET-css-svg-size http://127.0.0.1:$HP/CSS-svg-size.html
NET-html-progress-meter http://127.0.0.1:$HP/HTML-progress-meter.html
NET-html-embed-placeholders http://127.0.0.1:$HP/HTML-embed-placeholders.html
NET-css-letter-spacing http://127.0.0.1:$HP/CSS-letter-spacing.html
NET-css-inline-block-space http://127.0.0.1:$HP/CSS-inline-block-space.html
NET-html-fieldset-legend http://127.0.0.1:$HP/HTML-fieldset-legend.html
NET-html-range-color http://127.0.0.1:$HP/HTML-range-color.html
NET-js-nan-constants http://127.0.0.1:$HP/JS-nan-constants.html
NET-html-checkbox-size http://127.0.0.1:$HP/HTML-checkbox-size.html
NET-html-control-margins http://127.0.0.1:$HP/HTML-control-margins.html
NET-css-inline-block-space-font http://127.0.0.1:$HP/CSS-inline-block-space-font.html
NET-css-fractional-spacing http://127.0.0.1:$HP/CSS-fractional-spacing.html
NET-html-legend-reset http://127.0.0.1:$HP/HTML-legend-reset.html
NET-js-innerhtml-raw http://127.0.0.1:$HP/JS-innerhtml-raw.html
NET-js-offsetparent http://127.0.0.1:$HP/JS-offsetparent.html
NET-js-computed-unboxed http://127.0.0.1:$HP/JS-computed-unboxed.html
NET-css-inline-outranks http://127.0.0.1:$HP/CSS-inline-outranks.html
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
# Every nettest.txt line must reach the autotest: past the frontend's
# VITA_NET_PAGES_MAX the rest are dropped with only a log line, and the
# dropped pages' gates then fail as "no summary" (JS-lazyimg, 2026-09-29).
if grep -q 'nettest.txt: [0-9]* pages ignored' "$OUT/reference/log.txt"; then
	grep -h 'nettest.txt: [0-9]* pages ignored' "$OUT/reference/log.txt" | sed 's/^/  /'
	fail "network page list longer than VITA_NET_PAGES_MAX (frontends/vita/main.c)"
fi
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

# History API Phase B (Patch 136): pushState/replaceState keep a real
# same-document session stack; back()/forward()/go() walk it with popstate;
# history.length/state are joint with the native history; location reflects
# the shown URL; cross-origin pushState throws SecurityError. The page is
# fully synchronous (pushState never navigates), checked over HTTP and HTTPS.
echo "== history pushState phase B (JS-history) =="
jh_bad=0
for f in "$R"/*NET-js-history*.plot; do
	[ -f "$f" ] || { echo "  missing: $f"; jh_bad=$((jh_bad + 1)); continue; }
	n=${f##*/}
	r=$(sed -n 's/.*STR \(JS history: [0-9]*\/[0-9]* passed\).*/\1/p' "$f" | head -1)
	echo "  $n: ${r:-no summary line (script did not run?)}"
	grep -o 'STR [0-9]* [^:]*: \(waiting\|FAIL\).*' "$f" | sed 's/^STR /  /'
	# The page appends " FAILS: <names>" to the summary when red; surface it.
	sed -n 's/.*STR \(JS history: [0-9]*\/[0-9]* passed FAILS: .*\)/\1/p' "$f" | head -1 | sed 's/^/  /'
	[ "$r" = "JS history: 30/30 passed" ] || jh_bad=$((jh_bad + 1))
done
[ "$(ls "$R"/*NET-js-history*.plot 2>/dev/null | wc -l)" -eq 2 ] || jh_bad=$((jh_bad + 1))
[ "$jh_bad" -eq 0 ]

# Web Storage (localStorage per-origin persistence via __storageSave /
# __storageLoad; sessionStorage per-page in-memory) and MutationObserver
# (records queued by native mutation, delivered async). Both pages are
# async (mutation delivery, storage is sync but the page ticks), checked
# over HTTP and HTTPS.
echo "== storage + mutation observer (JS-storage, JS-mutation) =="
sm_bad=0
for f in "$R"/*NET-js-storage*.plot "$R"/*NET-js-mutation*.plot; do
	[ -f "$f" ] || { echo "  missing: $f"; sm_bad=$((sm_bad + 1)); continue; }
	n=${f##*/}
	r=$(sed -n 's/.*STR \(JS \(storage\|mutation\): [0-9]*\/[0-9]* passed\).*/\1/p' "$f" | head -1)
	echo "  $n: ${r:-no summary line (script did not run?)}"
	grep -o 'STR [0-9]* [^:]*: \(waiting\|FAIL\).*' "$f" | sed 's/^STR /  /'
	sed -n 's/.*STR \(JS \(storage\|mutation\): [0-9]*\/[0-9]* passed FAILS: .*\)/\1/p' "$f" | head -1 | sed 's/^/  /'
	case "$n" in
		*storage*) [ "$r" = "JS storage: 15/15 passed" ] || sm_bad=$((sm_bad + 1)) ;;
		*mutation*) [ "$r" = "JS mutation: 7/7 passed" ] || sm_bad=$((sm_bad + 1)) ;;
	esac
done
[ "$(ls "$R"/*NET-js-storage*.plot "$R"/*NET-js-mutation*.plot 2>/dev/null | wc -l)" -eq 4 ] || sm_bad=$((sm_bad + 1))
[ "$sm_bad" -eq 0 ]

# Fetch/XHR request bodies (Patch 140): URLSearchParams serializes to
# x-www-form-urlencoded, FormData text fields to multipart. The /echo
# endpoint returns the raw body for verification.
echo "== fetch request bodies (JS-fetch-body) =="
fb_bad=0
for f in "$R"/*NET-js-fetch-body*.plot; do
	[ -f "$f" ] || { echo "  missing: $f"; fb_bad=$((fb_bad + 1)); continue; }
	n=${f##*/}
	r=$(sed -n 's/.*STR \(JS fetch body: [0-9]*\/[0-9]* passed\).*/\1/p' "$f" | head -1)
	echo "  $n: ${r:-no summary line (script did not run?)}"
	grep -o 'STR [0-9]* [^:]*: \(waiting\|FAIL\).*' "$f" | sed 's/^STR /  /'
	sed -n 's/.*STR \(JS fetch body: [0-9]*\/[0-9]* passed FAILS: .*\)/\1/p' "$f" | head -1 | sed 's/^/  /'
	[ "$r" = "JS fetch body: 4/4 passed" ] || fb_bad=$((fb_bad + 1))
done
[ "$(ls "$R"/*NET-js-fetch-body*.plot 2>/dev/null | wc -l)" -eq 2 ] || fb_bad=$((fb_bad + 1))
[ "$fb_bad" -eq 0 ]

# Event dispatch order (Patch 145/146: capture -> target -> bubble with
# document and window in the right phases, one defaultPrevented, no
# bubbling for non-bubbling events), display: inline-grid as an inline
# box (Patch 147: github.com crashed), group opacity + light-dark()
# (Patch 149; checked in the plot: hidden text must not be drawn).
echo "== event order, inline-grid, group opacity =="
eo=$(ls "$R"/*-JS-event-order.plot 2>/dev/null | head -1)
eor=$(sed -n 's/.*STR \(EVORDER: [0-9]*\/[0-9]* passed\).*/\1/p' "$eo" 2>/dev/null | head -1)
echo "  JS-event-order: ${eor:-no summary}"
[ -n "$eo" ] && grep -o 'STR [0-9]* [^:]*: .*(want.*' "$eo" | sed 's/^STR /  /'
ig=$(ls "$R"/*-CSS-inline-grid.plot 2>/dev/null | head -1)
igr=$(sed -n 's/.*STR \(INLINEGRID: [0-9]*\/[0-9]* passed\).*/\1/p' "$ig" 2>/dev/null | head -1)
echo "  CSS-inline-grid: ${igr:-no summary}"
op=$(ls "$R"/*-CSS-opacity.plot 2>/dev/null | head -1)
op_shown=$(grep -c 'STR SHOWNMARK' "$op" 2>/dev/null || true)
op_half=$(grep -c 'STR HALFMARK' "$op" 2>/dev/null || true)
op_hidden=$(grep -c 'HIDDENSPANMARK\|HIDDENBLOCKMARK' "$op" 2>/dev/null || true)
op_ldbox=$(awk '/PLOT RECT/ { if ($8 - $4 == 200 && $10 - $6 == 30) n++ } END { print n+0 }' "$op" 2>/dev/null)
echo "  CSS-opacity: shown ${op_shown:-0} (1), half ${op_half:-0} (1), hidden ${op_hidden:-?} (0), light-dark box fills ${op_ldbox:-0} (>=1)"
ifp=$(ls "$R"/*NET-js-interfaces.plot 2>/dev/null | head -1)
ifr=$(sed -n 's/.*STR \(IFACES: [0-9]*\/[0-9]* passed\).*/\1/p' "$ifp" 2>/dev/null | head -1)
echo "  JS-interfaces: ${ifr:-no summary}"
[ -n "$ifp" ] && { grep -o 'STR [0-9]* [0-9] .* FAIL.*' "$ifp" | sed 's/^STR /  /' || true; }
cnp=$(ls "$R"/*-CSS-census.plot 2>/dev/null | head -1)
cnr=$(sed -n 's/.*STR \(CENSUS: [0-9]*\/[0-9]* passed\).*/\1/p' "$cnp" 2>/dev/null | head -1)
echo "  CSS-census: ${cnr:-no summary}"
[ -n "$cnp" ] && { grep -o 'STR [0-9]* [0-9] .* FAIL' "$cnp" | sed 's/^STR /  /' || true; }
inp=$(ls "$R"/*-CSS-intrinsic.plot 2>/dev/null | head -1)
inr=$(sed -n 's/.*STR \(INTRINSIC: [0-9]*\/[0-9]* passed\).*/\1/p' "$inp" 2>/dev/null | head -1)
echo "  CSS-intrinsic: ${inr:-no summary}"
map=$(ls "$R"/*NET-js-module-async.plot 2>/dev/null | head -1)
mar=$(sed -n 's/.*STR \(MODASYNC: [0-9]*\/[0-9]* passed\).*/\1/p' "$map" 2>/dev/null | head -1)
echo "  JS-module-async: ${mar:-no summary}"
[ -n "$map" ] && { grep -o 'STR [0-9]* [0-9] .* FAIL' "$map" | sed 's/^STR /  /' || true; }
# Patch 160: static module graphs (external + inline) load between frames,
# and inline modules run in document order with the deferred scripts.
msp=$(ls "$R"/*NET-js-module-static-async.plot 2>/dev/null | head -1)
msr=$(sed -n 's/.*STR \(MODSTATIC: [0-9]*\/[0-9]* passed\).*/\1/p' "$msp" 2>/dev/null | head -1)
echo "  JS-module-static-async: ${msr:-no summary}"
[ -n "$msp" ] && { grep -o 'STR [0-9]* [0-9] .* FAIL' "$msp" | sed 's/^STR /  /' || true; }
# Patch 161: one fetch and one evaluation per module URL across parallel
# loads (static graph, import() twice, module script + import(), same src
# twice); the page asks httpd for its own GET counts (/fetch-count).
mdp=$(ls "$R"/*NET-js-module-dedupe.plot 2>/dev/null | head -1)
mdr=$(sed -n 's/.*STR \(MODDUP: [0-9]*\/[0-9]* passed\).*/\1/p' "$mdp" 2>/dev/null | head -1)
echo "  JS-module-dedupe: ${mdr:-no summary}"
[ -n "$mdp" ] && { grep -o 'STR [0-9]* [0-9] .* FAIL' "$mdp" | sed 's/^STR /  /' || true; }
# Patch 162: the viewport-gated lazy-image drain (fixes738's queue, wired
# into the Vita frontend after every frame). The page proves it with
# httpd /fetch-count: at load only the 10-image eager budget is fetched;
# scrolling brings the six below-the-fold images in exactly once;
# scrolling back refetches nothing (16 GETs total). Read from the -bottom
# dump: checks 2-4 run after the autotest's scroll to the bottom.
lzp=$(ls "$R"/*NET-js-lazyimg-bottom.plot 2>/dev/null | head -1)
lzr=$(sed -n 's/.*STR \(LAZYIMG: [0-9]*\/[0-9]* passed\).*/\1/p' "$lzp" 2>/dev/null | head -1)
echo "  JS-lazyimg: ${lzr:-no summary}"
[ -n "$lzp" ] && { grep -o 'STR [0-9]* [0-9] .* FAIL' "$lzp" | sed 's/^STR /  /' || true; }
[ "$inr" = "INTRINSIC: 5/5 passed" ] && \
[ "$cnr" = "CENSUS: 5/5 passed" ] && \
[ "$mdr" = "MODDUP: 5/5 passed" ] && \
[ "$msr" = "MODSTATIC: 5/5 passed" ] && \
[ "$mar" = "MODASYNC: 4/4 passed" ] && \
# Patch 163: a late image re-lays out only its own lines (WS-C2b). The
# page measures the main loop while four images land at the bottom of a
# 5000-paragraph page (full layout 50-75 ms here); the engine's log for
# that page must show only local relayouts, each under a frame (16 ms).
rsp=$(ls "$R"/*NET-js-reflow-stall-bottom.plot 2>/dev/null | head -1)
rsr=$(sed -n 's/.*STR \(REFLOW: [0-9]*\/[0-9]* passed\).*/\1/p' "$rsp" 2>/dev/null | head -1)
if [ -z "$rsr" ]; then
	rsp=$(ls "$R"/*NET-js-reflow-stall.plot 2>/dev/null | head -1)
	rsr=$(sed -n 's/.*STR \(REFLOW: [0-9]*\/[0-9]* passed\).*/\1/p' "$rsp" 2>/dev/null | head -1)
fi
echo "  JS-reflow-stall: ${rsr:-no summary}"
[ -n "$rsp" ] && { grep -o 'STR [0-9]* [0-9] .* FAIL' "$rsp" | sed 's/^STR /  /' || true; }
rsl=$(awk '/page [0-9]*\/[0-9]* NET-js-reflow-stall: navigate/ {on=1; next}
	on && /page [0-9]*\/[0-9]* [^ ]*: navigate/ {on=0}
	on' "$R/netsurf.log" 2>/dev/null)
rs_local=$(printf '%s\n' "$rsl" | grep -c 'LIFE relayout local: [+-][0-9]* px in' || true)
rs_full=$(printf '%s\n' "$rsl" | grep -c 'LIFE relayout local: full reflow instead' || true)
rs_max=$(printf '%s\n' "$rsl" | sed -n 's/.*LIFE relayout local: [+-][0-9]* px in \([0-9]*\) us.*/\1/p' | sort -n | tail -1)
echo "  JS-reflow-stall engine: ${rs_local} local relayouts (longest ${rs_max:-?} us), ${rs_full} fell back to full"
# Patch 164: the last 64 characters of a 4097-4160-byte document or
# stylesheet were dropped (libparserutils without iconv): the page's only
# script and its stylesheet's last rule sit there.
ptp=$(ls "$R"/*NET-js-parse-tail.plot 2>/dev/null | head -1)
ptr=$(sed -n 's/.*STR \(PARSETAIL: [0-9]*\/[0-9]* passed\).*/\1/p' "$ptp" 2>/dev/null | head -1)
echo "  JS-parse-tail: ${ptr:-no summary}"
# CSSOM (Patch 168): styleSheets / cssRules parsed from the sheet's text,
# Google's sentinel check, insertRule / deleteRule / rule.style restyling.
csp=$(ls "$R"/*NET-js-cssom.plot 2>/dev/null | head -1)
csr=$(sed -n 's/.*STR \(CSSOM: [0-9]*\/[0-9]* passed\).*/\1/p' "$csp" 2>/dev/null | head -1)
echo "  JS-cssom: ${csr:-no summary}"
[ -n "$csp" ] && grep -o 'STR [0-9] [^"]*FAIL' "$csp" | sed 's/^STR /  /'
# CSSOM Patch 190: lost-update race and read-only cssRules (separate page
# to avoid interfering with the layout-sensitive checks above).
c190p=$(ls "$R"/*NET-js-cssom-190.plot 2>/dev/null | head -1)
c190r=$(sed -n 's/.*STR \(CSSOM190: [0-9]*\/[0-9]* passed\).*/\1/p' "$c190p" 2>/dev/null | head -1)
echo "  JS-cssom-190: ${c190r:-no summary}"
[ -n "$c190p" ] && grep -o 'STR [0-9] [^"]*FAIL' "$c190p" | sed 's/^STR /  /'
# Patch 191: bottom-anchored abspos in an earlier sibling moves when the
# containing block grows/shrinks via the local relayout path.
a191p=$(ls "$R"/*NET-js-abspos191.plot 2>/dev/null | head -1)
a191r=$(sed -n 's/.*STR \(ABSPOS191: [0-9]*\/[0-9]* passed\).*/\1/p' "$a191p" 2>/dev/null | head -1)
echo "  JS-abspos191: ${a191r:-no summary}"
[ -n "$a191p" ] && grep -o 'STR [0-9] [^"]*FAIL' "$a191p" | sed 's/^STR /  /'
# Patch 201: <caption> is a table-wide block above/below the grid.
c201p=$(ls "$R"/*NET-css-table-caption.plot 2>/dev/null | head -1)
c201r=$(sed -n 's/.*STR \(CAPTION201: [0-9]*\/[0-9]* passed\).*/\1/p' "$c201p" 2>/dev/null | head -1)
echo "  CSS-table-caption: ${c201r:-no summary}"
[ -n "$c201p" ] && grep -o 'STR [0-9] [^"]*FAIL' "$c201p" | sed 's/^STR /  /'
# Patch 202: an inline element's rect / offset size is its fragments' union.
i202p=$(ls "$R"/*NET-js-inline-rect.plot 2>/dev/null | head -1)
i202r=$(sed -n 's/.*STR \(INLINERECT: [0-9]*\/[0-9]* passed\).*/\1/p' "$i202p" 2>/dev/null | head -1)
echo "  JS-inline-rect: ${i202r:-no summary}"
[ -n "$i202p" ] && grep -o 'STR [0-9] [^"]*FAIL' "$i202p" | sed 's/^STR /  /'
# Patch 203: [hidden] / closed dialog / template / closed details hidden;
# summary click toggles; dialog show/close.
h203p=$(ls "$R"/*NET-html-hidden-details.plot 2>/dev/null | head -1)
h203r=$(sed -n 's/.*STR \(HIDDEN203: [0-9]*\/[0-9]* passed\).*/\1/p' "$h203p" 2>/dev/null | head -1)
echo "  HTML-hidden-details: ${h203r:-no summary}"
[ -n "$h203p" ] && grep -o 'STR [0-9] [^"]*FAIL' "$h203p" | sed 's/^STR /  /'
# Patch 204: display: flow-root is a block formatting context root.
f204p=$(ls "$R"/*NET-css-flow-root.plot 2>/dev/null | head -1)
f204r=$(sed -n 's/.*STR \(FLOWROOT204: [0-9]*\/[0-9]* passed\).*/\1/p' "$f204p" 2>/dev/null | head -1)
echo "  CSS-flow-root: ${f204r:-no summary}"
[ -n "$f204p" ] && grep -o 'STR [0-9] [^"]*FAIL' "$f204p" | sed 's/^STR /  /'
# Patch 206: grid auto-fill/auto-fit by container width; spaced grid-area.
g206p=$(ls "$R"/*NET-css-grid-autofill.plot 2>/dev/null | head -1)
g206r=$(sed -n 's/.*STR \(GRIDFILL206: [0-9]*\/[0-9]* passed\).*/\1/p' "$g206p" 2>/dev/null | head -1)
echo "  css-grid-autofill: ${g206r:-no summary}"
[ -n "$g206p" ] && grep -o 'STR [0-9] [^"]*FAIL' "$g206p" | sed 's/^STR /  /'
# Patch 207: svh/lvh/dvh (etc.) viewport units; lh resolves.
v207p=$(ls "$R"/*NET-css-viewport-units.plot 2>/dev/null | head -1)
v207r=$(sed -n 's/.*STR \(VUNITS207: [0-9]*\/[0-9]* passed\).*/\1/p' "$v207p" 2>/dev/null | head -1)
echo "  css-viewport-units: ${v207r:-no summary}"
[ -n "$v207p" ] && grep -o 'STR [0-9] [^"]*FAIL' "$v207p" | sed 's/^STR /  /'
# Patch 208: -webkit-line-clamp clamps the box to N lines.
l208p=$(ls "$R"/*NET-css-line-clamp.plot 2>/dev/null | head -1)
l208r=$(sed -n 's/.*STR \(CLAMP208: [0-9]*\/[0-9]* passed\).*/\1/p' "$l208p" 2>/dev/null | head -1)
echo "  css-line-clamp: ${l208r:-no summary}"
[ -n "$l208p" ] && grep -o 'STR [0-9] [^"]*FAIL' "$l208p" | sed 's/^STR /  /'
# Patch 210: 1ch is 0.5em when the "0" glyph is not measured.
c210p=$(ls "$R"/*NET-css-ch-unit.plot 2>/dev/null | head -1)
c210r=$(sed -n 's/.*STR \(CHUNIT210: [0-9]*\/[0-9]* passed\).*/\1/p' "$c210p" 2>/dev/null | head -1)
echo "  css-ch-unit: ${c210r:-no summary}"
[ -n "$c210p" ] && grep -o 'STR [0-9] [^"]*FAIL' "$c210p" | sed 's/^STR /  /'
# Patch 211: CSS nesting is flattened by the CSS rewrite.
n211p=$(ls "$R"/*NET-css-nesting.plot 2>/dev/null | head -1)
n211r=$(sed -n 's/.*STR \(NEST211: [0-9]*\/[0-9]* passed\).*/\1/p' "$n211p" 2>/dev/null | head -1)
echo "  css-nesting: ${n211r:-no summary}"
[ -n "$n211p" ] && grep -o 'STR [0-9] [^"]*FAIL' "$n211p" | sed 's/^STR /  /'
# Patch 212: getComputedStyle keeps colour alpha; alpha rounds.
a212p=$(ls "$R"/*NET-js-computed-alpha.plot 2>/dev/null | head -1)
a212r=$(sed -n 's/.*STR \(ALPHA212: [0-9]*\/[0-9]* passed\).*/\1/p' "$a212p" 2>/dev/null | head -1)
echo "  js-computed-alpha: ${a212r:-no summary}"
[ -n "$a212p" ] && grep -o 'STR [0-9] [^"]*FAIL' "$a212p" | sed 's/^STR /  /'
# Patch 213: discrete media features answer for the Vita.
m213p=$(ls "$R"/*NET-css-media-features.plot 2>/dev/null | head -1)
m213r=$(sed -n 's/.*STR \(MQFEAT213: [0-9]*\/[0-9]* passed\).*/\1/p' "$m213p" 2>/dev/null | head -1)
echo "  css-media-features: ${m213r:-no summary}"
[ -n "$m213p" ] && grep -o 'STR [0-9] [^"]*FAIL' "$m213p" | sed 's/^STR /  /'
# Patch 214: line-height: normal is the font's own (1.164).
l214p=$(ls "$R"/*NET-css-line-height-normal.plot 2>/dev/null | head -1)
l214r=$(sed -n 's/.*STR \(LINEH214: [0-9]*\/[0-9]* passed\).*/\1/p' "$l214p" 2>/dev/null | head -1)
echo "  css-line-height-normal: ${l214r:-no summary}"
[ -n "$l214p" ] && grep -o 'STR [0-9] [^"]*FAIL' "$l214p" | sed 's/^STR /  /'
# Patch 215: crypto.subtle digest + HMAC.
s215p=$(ls "$R"/*NET-js-crypto-subtle.plot 2>/dev/null | head -1)
s215r=$(sed -n 's/.*STR \(SUBTLE215: [0-9]*\/[0-9]* passed\).*/\1/p' "$s215p" 2>/dev/null | head -1)
echo "  js-crypto-subtle: ${s215r:-no summary}"
[ -n "$s215p" ] && grep -o 'STR [0-9] [^"]*FAIL' "$s215p" | sed 's/^STR /  /'
# Patch 216: @supports knows the properties we lack.
u216p=$(ls "$R"/*NET-css-supports-absent.plot 2>/dev/null | head -1)
u216r=$(sed -n 's/.*STR \(SUPABS216: [0-9]*\/[0-9]* passed\).*/\1/p' "$u216p" 2>/dev/null | head -1)
echo "  css-supports-absent: ${u216r:-no summary}"
[ -n "$u216p" ] && grep -o 'STR [0-9] [^"]*FAIL' "$u216p" | sed 's/^STR /  /'
# Patch 217: inline svg auto sizes from the viewBox ratio.
v217p=$(ls "$R"/*NET-css-svg-size.plot 2>/dev/null | head -1)
v217r=$(sed -n 's/.*STR \(SVGSIZE217: [0-9]*\/[0-9]* passed\).*/\1/p' "$v217p" 2>/dev/null | head -1)
echo "  css-svg-size: ${v217r:-no summary}"
[ -n "$v217p" ] && grep -o 'STR [0-9] [^"]*FAIL' "$v217p" | sed 's/^STR /  /'
# Patch 218: <progress> / <meter> bars.
p218p=$(ls "$R"/*NET-html-progress-meter.plot 2>/dev/null | head -1)
p218r=$(sed -n 's/.*STR \(PROGRESS218: [0-9]*\/[0-9]* passed\).*/\1/p' "$p218p" 2>/dev/null | head -1)
echo "  html-progress-meter: ${p218r:-no summary}"
[ -n "$p218p" ] && grep -o 'STR [0-9] [^"]*FAIL' "$p218p" | sed 's/^STR /  /'
# Patch 219: unloaded iframes / video keep their size.
e219p=$(ls "$R"/*NET-html-embed-placeholders.plot 2>/dev/null | head -1)
e219r=$(sed -n 's/.*STR \(EMBED219: [0-9]*\/[0-9]* passed\).*/\1/p' "$e219p" 2>/dev/null | head -1)
echo "  html-embed-placeholders: ${e219r:-no summary}"
[ -n "$e219p" ] && grep -o 'STR [0-9] [^"]*FAIL' "$e219p" | sed 's/^STR /  /'
# Patch 220: letter-spacing / word-spacing measured and drawn.
s220p=$(ls "$R"/*NET-css-letter-spacing.plot 2>/dev/null | head -1)
s220r=$(sed -n 's/.*STR \(SPACING220: [0-9]*\/[0-9]* passed\).*/\1/p' "$s220p" 2>/dev/null | head -1)
echo "  css-letter-spacing: ${s220r:-no summary}"
[ -n "$s220p" ] && grep -o 'STR [0-9] [^"]*FAIL' "$s220p" | sed 's/^STR /  /'
# Patch 221: the space after inline-blocks / replaced boxes.
i221p=$(ls "$R"/*NET-css-inline-block-space.plot 2>/dev/null | head -1)
i221r=$(sed -n 's/.*STR \(IBSPACE221: [0-9]*\/[0-9]* passed\).*/\1/p' "$i221p" 2>/dev/null | head -1)
echo "  css-inline-block-space: ${i221r:-no summary}"
[ -n "$i221p" ] && grep -o 'STR [0-9] [^"]*FAIL' "$i221p" | sed 's/^STR /  /'
# Patch 222: fieldset / legend geometry.
f222p=$(ls "$R"/*NET-html-fieldset-legend.plot 2>/dev/null | head -1)
f222r=$(sed -n 's/.*STR \(FIELDSET222: [0-9]*\/[0-9]* passed\).*/\1/p' "$f222p" 2>/dev/null | head -1)
echo "  html-fieldset-legend: ${f222r:-no summary}"
[ -n "$f222p" ] && grep -o 'STR [0-9] [^"]*FAIL' "$f222p" | sed 's/^STR /  /'
# Patch 223: range / color inputs as widgets.
r223p=$(ls "$R"/*NET-html-range-color.plot 2>/dev/null | head -1)
r223r=$(sed -n 's/.*STR \(RANGECOL223: [0-9]*\/[0-9]* passed\).*/\1/p' "$r223p" 2>/dev/null | head -1)
echo "  html-range-color: ${r223r:-no summary}"
[ -n "$r223p" ] && grep -o 'STR [0-9] [^"]*FAIL' "$r223p" | sed 's/^STR /  /'
# quickjs patch 05: NaN / Infinity constants.
ncp=$(ls "$R"/*NET-js-nan-constants.plot 2>/dev/null | head -1)
ncr=$(sed -n 's/.*STR \(NANCONST: [0-9]*\/[0-9]* passed\).*/\1/p' "$ncp" 2>/dev/null | head -1)
echo "  js-nan-constants: ${ncr:-no summary}"
[ -n "$ncp" ] && grep -o 'STR [0-9] [^"]*FAIL' "$ncp" | sed 's/^STR /  /'
# Patch 224: checkbox / radio size.
c224p=$(ls "$R"/*NET-html-checkbox-size.plot 2>/dev/null | head -1)
c224r=$(sed -n 's/.*STR \(CHECKBOX224: [0-9]*\/[0-9]* passed\).*/\1/p' "$c224p" 2>/dev/null | head -1)
echo "  html-checkbox-size: ${c224r:-no summary}"
[ -n "$c224p" ] && grep -o 'STR [0-9] [^"]*FAIL' "$c224p" | sed 's/^STR /  /'
# Patch 225: no margin on form controls.
m225p=$(ls "$R"/*NET-html-control-margins.plot 2>/dev/null | head -1)
m225r=$(sed -n 's/.*STR \(CTLMARGIN225: [0-9]*\/[0-9]* passed\).*/\1/p' "$m225p" 2>/dev/null | head -1)
echo "  html-control-margins: ${m225r:-no summary}"
[ -n "$m225p" ] && grep -o 'STR [0-9] [^"]*FAIL' "$m225p" | sed 's/^STR /  /'
# Patch 226: the space after inline-blocks in the surrounding font.
i226p=$(ls "$R"/*NET-css-inline-block-space-font.plot 2>/dev/null | head -1)
i226r=$(sed -n 's/.*STR \(IBFONT226: [0-9]*\/[0-9]* passed\).*/\1/p' "$i226p" 2>/dev/null | head -1)
echo "  css-inline-block-space-font: ${i226r:-no summary}"
[ -n "$i226p" ] && grep -o 'STR [0-9] [^"]*FAIL' "$i226p" | sed 's/^STR /  /'
# Patch 227: fractional letter- / word-spacing.
f227p=$(ls "$R"/*NET-css-fractional-spacing.plot 2>/dev/null | head -1)
f227r=$(sed -n 's/.*STR \(FRACSP227: [0-9]*\/[0-9]* passed\).*/\1/p' "$f227p" 2>/dev/null | head -1)
echo "  css-fractional-spacing: ${f227r:-no summary}"
[ -n "$f227p" ] && grep -o 'STR [0-9] [^"]*FAIL' "$f227p" | sed 's/^STR /  /'
# Patch 228: the legend lifted from its fieldset's own border / padding.
l228p=$(ls "$R"/*NET-html-legend-reset.plot 2>/dev/null | head -1)
l228r=$(sed -n 's/.*STR \(LEGEND228: [0-9]*\/[0-9]* passed\).*/\1/p' "$l228p" 2>/dev/null | head -1)
echo "  html-legend-reset: ${l228r:-no summary}"
[ -n "$l228p" ] && grep -o 'STR [0-9] [^"]*FAIL' "$l228p" | sed 's/^STR /  /'
# Patches 233-236 (make.wordpress.org's o2 app): a raw-text element's own
# innerHTML unescaped (233), offsetParent / offsetTop per CSSOM View (234),
# getComputedStyle for an element with no box (235), inline style outranks
# author rules whatever matched last (236, libcss).
o2_bad=
for g in "js-innerhtml-raw IHRAW 6" "js-offsetparent OFFPARENT 8" \
	 "js-computed-unboxed UNBOXED 7" "css-inline-outranks INLINE236 4"; do
	set -- $g
	gp=$(ls "$R"/*NET-$1.plot 2>/dev/null | head -1)
	gr=$(sed -n "s/.*STR \($2: [0-9]*\/[0-9]* passed\).*/\1/p" "$gp" 2>/dev/null | head -1)
	echo "  $1: ${gr:-no summary}"
	[ -n "$gp" ] && grep -o 'STR [0-9] [^"]*FAIL' "$gp" | sed 's/^STR /  /'
	[ "$gr" = "$2: $3/$3 passed" ] || o2_bad="$o2_bad $1"
done
# innerText (Patch 168): the rendered text, not textContent.
itp=$(ls "$R"/*NET-js-innertext.plot 2>/dev/null | head -1)
itr=$(sed -n 's/.*STR \(INNERTEXT: [0-9]*\/[0-9]* passed\).*/\1/p' "$itp" 2>/dev/null | head -1)
echo "  JS-innertext: ${itr:-no summary}"
[ -n "$itp" ] && grep -o 'STR [0-9] [^"]*FAIL[^"]*' "$itp" | sed 's/^STR /  /'
# Sanitizer primitives (Patch 171): attributes, TreeWalker, NodeIterator,
# Range.createContextualFragment, XMLSerializer, Closure's sanitize loop.
szp=$(ls "$R"/*NET-js-sanitize.plot 2>/dev/null | head -1)
szr=$(sed -n 's/.*STR \(SANITIZE: [0-9]*\/[0-9]* passed\).*/\1/p' "$szp" 2>/dev/null | head -1)
echo "  JS-sanitize: ${szr:-no summary}"
[ -n "$szp" ] && grep -a 'FAIL (want' "$szp" | sed 's/.*STR /  /' | cut -c1-160
# Class changes (Patch 173): a class set on an inline-level element among
# 5000 paragraphs rebuilds its block only; the page times it, the engine
# log must show the local rebuilds (and the block-level one declined).
csp2=$(ls "$R"/*NET-js-class-stall*.plot 2>/dev/null)
clr=$(sed -n 's/.*STR \(CLASSSTALL: [0-9]*\/[0-9]* passed\).*/\1/p' $csp2 2>/dev/null | head -1)
cll=$(awk '/page [0-9]*\/[0-9]* NET-js-class-stall: navigate/ {on=1; next}
	on && /page [0-9]*\/[0-9]* [^ ]*: navigate/ {on=0}
	on' "$R/netsurf.log" 2>/dev/null | grep -c 'LIFE rebuild local: rebuilt and laid out' || true)
echo "  JS-class-stall: ${clr:-no summary}; ${cll} class changes rebuilt locally"
[ -n "$csp2" ] && grep -aho 'STR [0-9] [^"]*FAIL' $csp2 | sort -u | sed 's/^STR /  /'
# (each page writes its summary once, at the end: it is in whichever of
# the page's two dumps -- top, -bottom -- was taken after that)
# Block class changes (Patch 174): a paragraph's own class rebuilds that
# block alone and places it back (engine log: "block restyled"); with a
# sibling combinator in the page CSS it must decline to the full rebuild,
# and the following siblings must still restyle (JS-block-class-sibling).
bcp=$(ls "$R"/*NET-js-block-class-stall*.plot 2>/dev/null)
bcr=$(sed -n 's/.*STR \(BLOCKCLASS: [0-9]*\/[0-9]* passed\).*/\1/p' $bcp 2>/dev/null | head -1)
bcl=$(grep -c 'LIFE rebuild local: block restyled [-+]' "$R/netsurf.log" || true)
bsp=$(ls "$R"/*NET-js-block-class-sibling*.plot 2>/dev/null)
bsr=$(sed -n 's/.*STR \(BLOCKSIB: [0-9]*\/[0-9]* passed\).*/\1/p' $bsp 2>/dev/null | head -1)
# Patch 197: count the post-186 decline message. Patch 174's string
# ("page CSS has sibling combinators") was removed by patch 186, which
# split it into precise/conservative variants logged inside
# html_rl_class_sibling_risk plus ONE call-site line per decline,
# "class change may move a sibling selector". The requirement is
# unchanged (>= 3 sibling-risk declines); only the matched log text
# tracks the engine's current wording. Without this the counter is
# permanently 0 and the check can never pass (root cause B of the
# 2026-10-02 cluster bisect).
bsd=$(grep -c 'declined (class change may move a sibling selector)' "$R/netsurf.log" || true)
echo "  JS-block-class-stall: ${bcr:-no summary}; ${bcl} blocks restyled locally"
echo "  JS-block-class-sibling: ${bsr:-no summary}; ${bsd} declined for sibling combinators"
# Precise sibling risk (Patch 186): unrelated sibling CSS stays local,
# genuine +/~ risks decline and restyle siblings, :has(+ ...) declines.
s186p=$(ls "$R"/*NET-css-sibling-class*.plot 2>/dev/null)
s186r=$(sed -n 's/.*STR \(SIB186: [0-9]*\/[0-9]* passed\).*/\1/p' $s186p 2>/dev/null | head -1)
s186d=$(grep -c 'declined (class change moves a sibling selector)' "$R/netsurf.log" || true)
s186c=$(grep -c 'declined (page CSS needs conservative sibling check)' "$R/netsurf.log" || true)
echo "  CSS-sibling-class: ${s186r:-no summary}; ${s186d} precise declines, ${s186c} conservative declines"
[ -n "$bcp" ] && grep -aho 'STR [0-9] [^"]*FAIL' $bcp | sort -u | sed 's/^STR /  /'
# Lists and nested blocks (Patch 176): a list item or a block of blocks a
# script adds or removes is built alone and the page laid out once (no
# full box-tree rebuild): markers renumbered, margins collapsed through.
lnp=$(ls "$R"/*NET-js-list-nested-stall*.plot 2>/dev/null)
lnr=$(sed -n 's/.*STR \(LISTNEST: [0-9]*\/[0-9]* passed\).*/\1/p' $lnp 2>/dev/null | head -1)
lnl=$(grep -c 'LIFE rebuild local: blocks rebuilt ([0-9]* added, [0-9]* removed), full layout (a list item or nested blocks)' "$R/netsurf.log" || true)
echo "  JS-list-nested-stall: ${lnr:-no summary}; ${lnl} list/nested changes built alone"
[ -n "$lnp" ] && grep -aho 'STR [0-9] [^"]*FAIL' $lnp | sort -u | sed 's/^STR /  /'
# Structural/counter lists (Patch 192): inserting/removing a list item on a
# page whose CSS uses :nth-child() or CSS counters declines the local path
# (following siblings would keep stale styles/counter text) and a removed
# item's marker box is freed.
lsp=$(ls "$R"/*NET-js-list-structural*.plot 2>/dev/null)
lsr=$(sed -n 's/.*STR \(LISTSTRUCT: [0-9]*\/[0-9]* passed\).*/\1/p' $lsp 2>/dev/null | head -1)
lsd=$(grep -c 'LIFE rebuild local: declined (structural selectors or counters in page CSS)' "$R/netsurf.log" || true)
lsm=$(grep -c 'box_free: freed list marker' "$R/netsurf.log" || true)
echo "  JS-list-structural: ${lsr:-no summary}; ${lsd} structural/counter declines, ${lsm} markers freed"
[ -n "$lsp" ] && grep -aho 'STR [0-9] [^"]*FAIL' $lsp | sort -u | sed 's/^STR /  /'
# Sibling insert/remove (Patch 198): inserting or removing a block that can
# move a following sibling's match through a + / ~ rule (or flip the
# parent's :empty / an ancestor's :has) declines the local path; the test
# page asserts the sibling's computed colour actually changed (on the local
# path it would stay stale). The engine log must show the declines.
sbp=$(ls "$R"/*NET-js-block-sibling-insert*.plot 2>/dev/null)
sbr=$(sed -n 's/.*STR \(SIBINS: [0-9]*\/[0-9]* passed\).*/\1/p' $sbp 2>/dev/null | head -1)
sbd=$(grep -c 'LIFE rebuild local: declined (sibling combinator may restyle on insert/remove)' "$R/netsurf.log" || true)
echo "  JS-block-sibling-insert: ${sbr:-no summary}; ${sbd} insert/remove sibling declines"
[ -n "$sbp" ] && grep -aho 'STR [0-9] [^"]*FAIL' $sbp | sort -u | sed 's/^STR /  /'
# :has() gaps (Patch 193): sibling-lead multi-part relative selectors match
# descendants of following siblings; element.querySelectorAll(':scope')
# includes the element; nested :has() and :has() with pseudo-classes.
h9p=$(ls "$R"/*NET-js-has193*.plot 2>/dev/null)
h9r=$(sed -n 's/.*STR \(HAS193: [0-9]*\/[0-9]* passed\).*/\1/p' $h9p 2>/dev/null | head -1)
echo "  JS-has193: ${h9r:-no summary}"
[ -n "$h9p" ] && grep -aho 'STR [0-9] [^"]*FAIL' $h9p | sort -u | sed 's/^STR /  /'
# Flex stretch vs max-height (Patch 194): stretched nested flex/grid items
# keep a valid max-height clamp; stretch restoration still applies without
# max-height and does not over-clamp a larger max-height.
smp=$(ls "$R"/*NET-js-flex-stretch-maxheight*.plot 2>/dev/null)
smr=$(sed -n 's/.*STR \(STRMAX194: [0-9]*\/[0-9]* passed\).*/\1/p' $smp 2>/dev/null | head -1)
echo "  JS-flex-stretch-maxheight: ${smr:-no summary}"
[ -n "$smp" ] && grep -aho 'STR [0-9] [^"]*FAIL' $smp | sort -u | sed 's/^STR /  /'
# Flex centering single-line only (Patch 195): patch 183's oversized-item
# centering applies to single-line flex; multi-line uses per-line cross size.
f95p=$(ls "$R"/*NET-js-flex195*.plot 2>/dev/null)
f95r=$(sed -n 's/.*STR \(FLEX195: [0-9]*\/[0-9]* passed\).*/\1/p' $f95p 2>/dev/null | head -1)
echo "  JS-flex195: ${f95r:-no summary}"
[ -n "$f95p" ] && grep -aho 'STR [0-9] [^"]*FAIL' $f95p | sort -u | sed 's/^STR /  /'
# webkit-appearance (Patch 196): canonical legacy keywords parse (all ->
# auto); gcs.webkitAppearance and getPropertyValue('-webkit-appearance')
# answer; el.style.webkitAppearance get/set round-trips.
a96p=$(ls "$R"/*NET-js-appearance196*.plot 2>/dev/null)
a96r=$(sed -n 's/.*STR \(APPEAR196: [0-9]*\/[0-9]* passed\).*/\1/p' $a96p 2>/dev/null | head -1)
echo "  JS-appearance196: ${a96r:-no summary}"
[ -n "$a96p" ] && grep -aho 'STR [0-9] [^"]*FAIL' $a96p | sort -u | sed 's/^STR /  /'
# Selectors (Patch 178): matches / closest / querySelector(All) against
# Chromium's answers for 85 cases (JS-selectors.html carries them).
slp=$(ls "$R"/*NET-js-selectors*.plot 2>/dev/null)
slr=$(sed -n 's/.*STR \(SELECTORS: [0-9]*\/[0-9]* passed\).*/\1/p' $slp 2>/dev/null | head -1)
echo "  JS-selectors: ${slr:-no summary}"
[ "$slr" = "SELECTORS: 85/85 passed" ] || { [ -n "$slp" ] && grep -aho 'STR [^"]*(want[^"]*' $slp | head -3 | sed 's/^STR /  /'; }
# Character data (Patch 179): a detached text node's data set no longer
# crashes libdom; CharacterData edits; characterData mutation records.
cdp=$(ls "$R"/*NET-js-chardata*.plot 2>/dev/null)
cdr=$(sed -n 's/.*STR \(CHARDATA: [0-9]*\/[0-9]* passed\).*/\1/p' $cdp 2>/dev/null | head -1)
echo "  JS-chardata: ${cdr:-no summary}"
[ -n "$cdp" ] && grep -aho 'STR [0-9] [^"]*FAIL' $cdp | sort -u | sed 's/^STR /  /'
# Flex header (Patch 180): google's header reduced -- flex: 1 0 auto grows
# (libcss shorthand), a nested flex container stretches, a flex container
# is not collapsed through, calc() line-height, border-box min-height.
fhp=$(ls "$R"/*NET-css-flex-header*.plot 2>/dev/null)
fhr=$(sed -n 's/.*STR \(FLEXHDR: [0-9]*\/[0-9]* passed\).*/\1/p' $fhp 2>/dev/null | head -1)
echo "  CSS-flex-header: ${fhr:-no summary}"
[ -n "$fhp" ] && grep -aho 'STR [0-9] [^"]*FAIL' $fhp | sort -u | sed 's/^STR /  /'
# Account bar (Patch 182): a script innerHTML on a standards-mode page
# must not switch the page into quirks; the absolutely-positioned
# sign-in button stays top-right, live class matching stays case-sensitive.
abp=$(ls "$R"/*NET-css-account-bar*.plot 2>/dev/null)
abr=$(sed -n 's/.*STR \(ACCTBAR: [0-9]*\/[0-9]* passed\).*/\1/p' $abp 2>/dev/null | head -1)
echo "  CSS-account-bar: ${abr:-no summary}"
[ -n "$abp" ] && grep -aho 'STR [0-9] [^"]*FAIL' $abp | sort -u | sed 's/^STR /  /'
# Appearance (Patch 184): -webkit-appearance is read as appearance and the
# legacy widget values (button/textfield/...) compute to auto; an unknown
# value drops. Six getComputedStyle cases (Chromium's answers).
app=$(ls "$R"/*NET-css-appearance*.plot 2>/dev/null)
appr=$(sed -n 's/.*STR \(APPEAR: [0-9]*\/[0-9]* passed\).*/\1/p' $app 2>/dev/null | head -1)
echo "  CSS-appearance: ${appr:-no summary}"
[ -n "$app" ] && grep -aho 'STR [0-9] [^"]*FAIL' $app | sort -u | sed 's/^STR /  /'
[ -n "$ptp" ] && { grep -o 'STR [0-9]* [0-9] .* FAIL' "$ptp" | sed 's/^STR /  /' || true; }
# Patch 165: a script's text change rebuilds and lays out only its block
# (html_reconvert_local): three text edits on a 5000-paragraph page, each
# < 60 ms of stall, and the engine log shows them done locally.
# Patch 166: the same for a paragraph inserted, appended and removed
# (layout_relayout_block): placed locally, < 60 ms each.
dsp=$(ls "$R"/*NET-js-dom-stall-bottom.plot 2>/dev/null | head -1)
dsr=$(sed -n 's/.*STR \(DOMSTALL: [0-9]*\/[0-9]* passed\).*/\1/p' "$dsp" 2>/dev/null | head -1)
if [ -z "$dsr" ]; then
	dsp=$(ls "$R"/*NET-js-dom-stall.plot 2>/dev/null | head -1)
	dsr=$(sed -n 's/.*STR \(DOMSTALL: [0-9]*\/[0-9]* passed\).*/\1/p' "$dsp" 2>/dev/null | head -1)
fi
echo "  JS-dom-stall: ${dsr:-no summary}"
[ -n "$dsp" ] && { grep -o 'STR [0-9]* [0-9] .* FAIL' "$dsp" | sed 's/^STR /  /' || true; }
dsl=$(awk '/page [0-9]*\/[0-9]* NET-js-dom-stall: navigate/ {on=1; next}
	on && /page [0-9]*\/[0-9]* [^ ]*: navigate/ {on=0}
	on' "$R/netsurf.log" 2>/dev/null)
ds_local=$(printf '%s\n' "$dsl" | grep -c 'LIFE rebuild local: rebuilt and laid out' || true)
ds_blocks=$(printf '%s\n' "$dsl" | grep -c 'LIFE rebuild local: blocks placed' || true)
echo "  JS-dom-stall engine: ${ds_local} text changes rebuilt locally, ${ds_blocks} block changes placed locally"
# Patch 188: step 7 is the span:empty{display:none} + comment-child probe
# (use-after-free repro): the count went 7 -> 8.
# GATE_TIMING_SOFT=1: REFLOW's check 3 is a wall-clock bound (longest
# main-loop gap); on a loaded VM one host hiccup fails it in most runs,
# and this combined check then stops the gate before the sections below
# (frames, window services, interaction pass, downloads, real-site
# layout, web APIs, the Vita-pace run) ever run. With the knob, 2/3 with
# only check 3 failing is accepted, and said so. Off by default.
# soft_pass RESULT EXPECTED "PLOTS" N: RESULT is EXPECTED, or, with
# GATE_TIMING_SOFT=1, one short of it with check N -- a wall-clock "gap"
# bound -- its only failure (said so). The structural counts beside each
# use stay strict.
soft_pass() {
	[ "$1" = "$2" ] && return 0
	[ "${GATE_TIMING_SOFT:-0}" = 1 ] || return 1
	sp_name=${2%%:*}; sp_total=${2#*/}; sp_total=${sp_total%% *}
	[ "$1" = "$sp_name: $((sp_total - 1))/$sp_total passed" ] || return 1
	grep -h -o 'STR [0-9] [^"]*FAIL' $3 2>/dev/null | grep -q "^STR $4 .*gap" || return 1
	grep -h -o 'STR [0-9] [^"]*FAIL' $3 2>/dev/null | grep -v "^STR $4 " | grep -q . && return 1
	echo "  $sp_name: only timing check $4 failed -- accepted, GATE_TIMING_SOFT=1"
	return 0
}
# The longest local relayout is host wall-clock too. Under
# GATE_TIMING_SOFT=1 a run over the 16 ms bound is measured once more --
# the reflow page alone, in a fresh simulator -- and the bound applies to
# that second measurement (said so). The bound itself never moves: a real
# slowdown fails both runs. (Was: up to 2x accepted outright.)
if [ "${GATE_TIMING_SOFT:-0}" = 1 ] && [ "${rs_max:-99999}" -ge 16000 ] && \
   [ "${rs_local:-0}" -ge 4 ] && [ "${rs_full:-1}" -eq 0 ]; then
	echo "  REFLOW: longest local relayout ${rs_max} us over 16000 -- measuring once more"
	S3="$OUT/reflow-retry"
	rm -rf "$S3"; mkdir -p "$S3/ux0:data/VitaBrowser"
	cp -r "$OUT/run/app0:" "$S3/"
	echo off > "$S3/ux0:data/VitaBrowser/netlog.cfg"
	echo "NET-js-reflow-stall http://127.0.0.1:$HP/JS-reflow-stall.html" \
		> "$S3/ux0:data/VitaBrowser/nettest.txt"
	python3 "$ROOT/tools/vita-sim/httpd.py" --dir "$ROOT/testpages/pages" \
		--http "$HP" > "$OUT/httpd-retry.log" 2>&1 &
	HTTPD=$!
	sleep 1
	( cd "$S3" && VITA_SIM_AUTOTEST=1 \
		VITA_SETTLE_EXTRA_MS="${VITA_SETTLE_EXTRA_MS:-7000}" \
		timeout 900 "$NS/nsvita-sim" > "$S3/stdout.log" 2>&1 ) || true
	kill $HTTPD 2>/dev/null || true
	rsl2=$(awk '/page [0-9]*\/[0-9]* NET-js-reflow-stall: navigate/ {on=1; next}
		on && /page [0-9]*\/[0-9]* [^ ]*: navigate/ {on=0}
		on' "$S3/ux0:data/VitaBrowser/netsurf.log" 2>/dev/null)
	rs_local2=$(printf '%s\n' "$rsl2" | grep -c 'LIFE relayout local: [+-][0-9]* px in' || true)
	rs_full2=$(printf '%s\n' "$rsl2" | grep -c 'LIFE relayout local: full reflow instead' || true)
	rs_max2=$(printf '%s\n' "$rsl2" | sed -n 's/.*LIFE relayout local: [+-][0-9]* px in \([0-9]*\) us.*/\1/p' | sort -n | tail -1)
	echo "  REFLOW retry: ${rs_local2} local relayouts (longest ${rs_max2:-?} us), ${rs_full2} fell back to full"
	if [ "${rs_local2:-0}" -ge 4 ] && [ "${rs_full2:-1}" -eq 0 ] && \
	   [ "${rs_max2:-99999}" -lt 16000 ]; then
		rs_max=$rs_max2
		echo "  REFLOW: second measurement under 16000 -- accepted, GATE_TIMING_SOFT=1"
	fi
fi
rs_ok=no
[ "$rsr" = "REFLOW: 3/3 passed" ] && rs_ok=yes
if [ "$rs_ok" = no ] && [ "${GATE_TIMING_SOFT:-0}" = 1 ] && \
   [ "$rsr" = "REFLOW: 2/3 passed" ] && [ -n "$rsp" ] && \
   grep -o 'STR [^"]*' "$rsp" | sed 's/^STR //' | tr '\n' ' ' | \
	grep -q '3 no stall:.* FAIL' && \
   ! grep -q 'STR [12] [^"]*FAIL' "$rsp"; then
	rs_ok=soft
	echo "  REFLOW: only the timing check (3) failed -- accepted, GATE_TIMING_SOFT=1"
fi
soft_pass "$dsr" "DOMSTALL: 8/8 passed" "$dsp" 8 && [ "${ds_local:-0}" -ge 3 ] && \
[ "${ds_blocks:-0}" -ge 3 ] && \
[ "$ptr" = "PARSETAIL: 2/2 passed" ] && \
[ "$csr" = "CSSOM: 8/8 passed" ] && \
[ "$c190r" = "CSSOM190: 2/2 passed" ] && \
[ "$a191r" = "ABSPOS191: 2/2 passed" ] && \
[ "$c201r" = "CAPTION201: 8/8 passed" ] && \
[ "$i202r" = "INLINERECT: 6/6 passed" ] && \
[ "$h203r" = "HIDDEN203: 9/9 passed" ] && \
[ "$f204r" = "FLOWROOT204: 4/4 passed" ] && \
[ "$g206r" = "GRIDFILL206: 8/8 passed" ] && \
[ "$v207r" = "VUNITS207: 4/4 passed" ] && \
[ "$l208r" = "CLAMP208: 4/4 passed" ] && \
[ "$c210r" = "CHUNIT210: 2/2 passed" ] && \
[ "$n211r" = "NEST211: 6/6 passed" ] && \
[ "$a212r" = "ALPHA212: 4/4 passed" ] && \
[ "$m213r" = "MQFEAT213: 4/4 passed" ] && \
[ "$l214r" = "LINEH214: 3/3 passed" ] && \
[ "$s215r" = "SUBTLE215: 5/5 passed" ] && \
[ "$u216r" = "SUPABS216: 3/3 passed" ] && \
[ "$v217r" = "SVGSIZE217: 5/5 passed" ] && \
[ "$p218r" = "PROGRESS218: 5/5 passed" ] && \
[ "$e219r" = "EMBED219: 4/4 passed" ] && \
[ "$s220r" = "SPACING220: 3/3 passed" ] && \
[ "$i221r" = "IBSPACE221: 5/5 passed" ] && \
[ "$f222r" = "FIELDSET222: 5/5 passed" ] && \
[ "$r223r" = "RANGECOL223: 4/4 passed" ] && \
[ "$ncr" = "NANCONST: 4/4 passed" ] && \
[ "$c224r" = "CHECKBOX224: 4/4 passed" ] && \
[ "$m225r" = "CTLMARGIN225: 3/3 passed" ] && \
[ "$i226r" = "IBFONT226: 4/4 passed" ] && \
[ "$f227r" = "FRACSP227: 4/4 passed" ] && \
[ "$l228r" = "LEGEND228: 4/4 passed" ] && [ -z "$o2_bad" ] && \
[ "$itr" = "INNERTEXT: 9/9 passed" ] && \
[ "$szr" = "SANITIZE: 7/7 passed" ] && \
soft_pass "$clr" "CLASSSTALL: 7/7 passed" "$csp2" 7 && [ "${cll:-0}" -ge 5 ] && \
soft_pass "$bcr" "BLOCKCLASS: 7/7 passed" "$bcp" 7 && [ "${bcl:-0}" -ge 6 ] && \
[ "$bsr" = "BLOCKSIB: 3/3 passed" ] && [ "${bsd:-0}" -ge 3 ] && \
soft_pass "$lnr" "LISTNEST: 7/7 passed" "$lnp" 7 && [ "${lnl:-0}" -ge 6 ] && \
[ "$lsr" = "LISTSTRUCT: 6/6 passed" ] && [ "${lsd:-0}" -ge 4 ] && [ "${lsm:-0}" -ge 1 ] && \
[ "$sbr" = "SIBINS: 4/4 passed" ] && [ "${sbd:-0}" -ge 2 ] && \
[ "$h9r" = "HAS193: 6/6 passed" ] && \
[ "$smr" = "STRMAX194: 4/4 passed" ] && \
[ "$f95r" = "FLEX195: 4/4 passed" ] && \
[ "$a96r" = "APPEAR196: 22/22 passed" ] && \
[ "$slr" = "SELECTORS: 85/85 passed" ] && \
[ "$abr" = "ACCTBAR: 5/5 passed" ] && \
[ "$appr" = "APPEAR: 6/6 passed" ] && \
[ "$cdr" = "CHARDATA: 5/5 passed" ] && \
[ "$fhr" = "FLEXHDR: 6/6 passed" ] && \
[ "$rs_ok" != no ] && [ "${rs_local:-0}" -ge 4 ] && \
[ "${rs_full:-1}" -eq 0 ] && [ "${rs_max:-99999}" -lt 16000 ] && \
[ "$lzr" = "LAZYIMG: 4/4 passed" ] && \
[ "$ifr" = "IFACES: 9/9 passed" ] && \
[ "$eor" = "EVORDER: 5/5 passed" ] && [ "$igr" = "INLINEGRID: 4/4 passed" ] && \
	[ "${op_shown:-0}" -ge 1 ] && [ "${op_half:-0}" -ge 1 ] && [ "${op_hidden:-1}" -eq 0 ] && \
	[ "${op_ldbox:-0}" -ge 1 ] || fail "event order / inline-grid / group opacity"

# Script-made frames (Patch 143) and timer chains (Patch 141): a same-
# origin or blank frame a script makes fires load and has a same-realm
# contentWindow with eval (Google's BotGuard runs in one); a cross-origin
# one gets no made-up load; 300 chained setTimeout(fn, 1) finish quickly.
echo "== script-made frames + timer chains (JS-frame-local) =="
fl=$(ls "$R"/*NET-js-frame-local.plot 2>/dev/null | head -1)
flr=$(sed -n 's/.*STR \(FRAMELOCAL: [0-9]*\/[0-9]* passed\).*/\1/p' "$fl" 2>/dev/null | head -1)
echo "  JS-frame-local: ${flr:-no summary line (script did not run?)}"
[ -n "$fl" ] && grep -o 'STR [0-9]* [^:]*: waiting.*' "$fl" | sed 's/^STR /  /'
[ "$flr" = "FRAMELOCAL: 6/6 passed" ] || fail "script-made frames / timer chains"

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
# A download (vita/download.c): the tap saves to ux0:data/VitaBrowser/
# downloads/ (ux0:download/ is out of a safe eboot's reach; see above), and
# the saved file must be byte-for-byte the bundled target -- not truncated,
# not renamed to " (2)", not the page itself.
echo "== downloads (ux0:data/VitaBrowser/downloads/, ux0:download/ refused) =="
DLSAVED="$OUT/run/ux0:data/VitaBrowser/downloads/vita-test.bin"
echo "  saved: $DLSAVED ($(stat -c %s "$DLSAVED" 2>/dev/null || echo missing) bytes, target 1024)"
if [ -f "$DLSAVED" ] && cmp -s "$DLSAVED" "$ROOT/testpages/pages/IN-download-target.bin"; then
	echo "  vita-test.bin: byte-identical to the bundled target"
else
	echo "  vita-test.bin: DIFFERS from the target (or missing)"; fail "downloads"
fi
grep -E 'download: (saved|FAILED)' "$R/log.txt" | sed 's/^\[[^]]*\] /  /' | cut -c1-120
grep -q 'download: cannot make ux0:download' "$R/log.txt" || fail "downloads: ux0:download was not refused first"
[ -n "$isum" ] && [ "${isum%/*}" = "${isum#*/}" ] && \
	[ "$iblk" = "IN block: 2/2 passed" ] && [ -f "$R/IN-zoom125.plot" ] && \
	[ -f "$R/IN-form-sent.plot" ] && \
	grep -q 'a submit whose click rebuilds the page: PASS' "$R/log.txt" && \
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
[ "${napi:-0}" -ge 172 ] && [ "$beh" = "behaviour: 10/10 right" ] || fail "web API census"
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
	# [01]* meant the bundled pages (01-19) until the network list ran
	# past page 99: 100-* and up are network pages this run never
	# loads (it has only NET-http-local).
	case "$n" in
	*-NET-*) [ -f "$S2/ux0:data/VitaBrowser/$n" ] || continue ;;
	esac
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
