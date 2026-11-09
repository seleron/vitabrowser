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
HTTPD=; RX=; BG_JOBS=
# Unit 403: the background runs (bg_forms, bg_slow below) record their
# httpd and simulator PIDs in $OUT/*.pids; a gate that stops early takes
# them down too.
trap 'kill $HTTPD $RX $BG_JOBS $(cat "$OUT"/*.pids 2>/dev/null) 2>/dev/null || true' EXIT
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

# Unit 403 (gate efficiency): the scriptless form submissions and the
# Vita's-pace autotest share nothing with the main autotest while they run
# (own directories, own httpd and LAN-listener ports; their checks read the
# main run's dumps only after both finish), so they start here and are
# waited for at their own sections. GATE_SERIAL=1 runs them in place, one
# after another, as before. HP is the main run's httpd port (set below).
HP="${HTTPD_PORT:-45280}"
# The background runs' TCP ports sit BELOW Linux's ephemeral range
# (32768-60999 here): a listener inside it can lose its port to any
# outgoing connection that happens to be using it as a local port at that
# moment (the frontend's listener has SO_REUSEADDR, which covers TIME_WAIT,
# not live sockets). Seen: "remote: cannot listen on :45182, errno 98" and
# the slow run's interaction 45/52. The main run's 45180/45280-45282 carry
# the same small, pre-existing exposure.
SLOW_HP="${SLOW_HTTPD_PORT:-31290}"; SLOW_REMOTE="${SLOW_REMOTE_PORT:-31182}"
FORMS_HP="${FORMS_HTTPD_PORT:-31300}"; FORMS_REMOTE="${FORMS_REMOTE_PORT:-31183}"
# bind_note DIR: say so when a run's LAN listener could not bind (its
# remote-control steps then fail and the summary alone does not say why)
bind_note() {
	grep -h "remote: cannot listen" "$1/ux0:data/VitaBrowser/log.txt" 2>/dev/null | \
		sed 's/^\[[^]]*\] /  LISTENER: /' || true
}
# bg_forms: the scriptless form submissions' run (checked at its section).
# Own httpd port and LAN-listener port: it may run beside the main autotest
# (unit 403).
bg_forms() {
	FS="$OUT/forms"
	rm -rf "$FS"; mkdir -p "$FS/ux0:data/VitaBrowser"
	cp -r "$OUT/run/app0:" "$FS/"
	echo off > "$FS/ux0:data/VitaBrowser/netlog.cfg"
	FU="$FS/q\"uote é.dat"
	printf 'upload line 1\r\nline 2\n\000\001\376\377 end' > "$FU"
	FB="http://127.0.0.1:$FORMS_HP"
	printf 'settle 3000\ntap 160 65\nsettle 3000\nnav %s/HTML-multipart-form.html\nsettle 3000\ntap 160 135\nsettle 3000\nnav %s/HTML-multipart-1252.html\nsettle 3000\ntap 160 65\nsettle 3000\nnav %s/HTML-multipart-upload.html\nsettle 3000\ntap 160 65\nsettle 1500\ntap 160 135\nsettle 3000\n' \
		"$FB" "$FB" "$FB" > "$FS/script.txt"
	for c in img imgnoname nosub submit button values; do
		printf 'nav %s/JS-form-submitters.html?%s\nsettle 3000\n' "$FB" "$c" >> "$FS/script.txt"
	done
	# Patch 289: a tapped Send button and a tapped link whose target is an
	# iframe (one with no src, one display:none) load there; the page stays
	# and its title lists what arrived (was: the result replaced the page)
	printf 'nav %s/JS-form-target.html?tap\nsettle 3000\ntap 160 65\nsettle 2000\ntap 160 135\nsettle 3000\n' "$FB" >> "$FS/script.txt"
	echo quit >> "$FS/script.txt"
	python3 "$ROOT/tools/vita-sim/httpd.py" --dir "$ROOT/testpages/pages" \
		--http "$FORMS_HP" > "$OUT/httpd-forms.log" 2>&1 &
	echo $! > "$OUT/forms.pids"
	sleep 1
	( cd "$FS" && VITA_SIM_UPLOAD="$FU" VITA_SIM_SCRIPT="$FS/script.txt" \
		VITA_SIM_OUT="$FS" VITA_SIM_REMOTE_PORT=$FORMS_REMOTE \
		exec timeout 300 "$NS/nsvita-sim" \
		"$FB/HTML-multipart-form.html" > "$FS/stdout.log" 2>&1 ) &
	echo $! >> "$OUT/forms.pids"
	f_rc=0; wait $! || f_rc=$?
	kill $(head -1 "$OUT/forms.pids") 2>/dev/null || true
	rm -f "$OUT/forms.pids"
	echo $f_rc > "$FS/rc"
}
# bg_slow: the Vita's-pace autotest's run (checked at its section). Own
# httpd port and LAN-listener port; its dumps are compared with the main
# run's only after both finish (unit 403).
bg_slow() {
	S2="$OUT/slow"
	rm -rf "$S2"; mkdir -p "$S2/ux0:data/VitaBrowser"
	cp -r "$OUT/run/app0:" "$S2/"
	echo off > "$S2/ux0:data/VitaBrowser/netlog.cfg"
	python3 "$ROOT/tools/vita-sim/httpd.py" --dir "$ROOT/testpages/pages" \
		--http "$SLOW_HP" > "$OUT/httpd-slow.log" 2>&1 &
	echo $! > "$OUT/slow.pids"
	echo "NET-http-local http://127.0.0.1:$SLOW_HP/L1-layout-basics.html" \
		> "$S2/ux0:data/VitaBrowser/nettest.txt"
	mkdir -p "$S2/snaps"
	( cd "$S2" && VITA_SIM_SLOW_MS=40 VITA_SIM_TEXT_UNBATCHED=1 VITA_SIM_AUTOTEST=1 \
		VITA_SIM_SNAP="$S2/snaps" VITA_SIM_REMOTE_PORT=$SLOW_REMOTE \
		exec timeout 1200 "$NS/nsvita-sim" > "$S2/stdout.log" 2>&1 ) &
	echo $! >> "$OUT/slow.pids"
	s_rc=0; wait $! || s_rc=$?
	kill $(head -1 "$OUT/slow.pids") 2>/dev/null || true
	rm -f "$OUT/slow.pids"
	echo $s_rc > "$S2/rc"
}

FORMS_JOB=; SLOW_JOB=
if [ "${GATE_SERIAL:-0}" != 1 ]; then
	bg_forms > "$OUT/bg-forms.log" 2>&1 & FORMS_JOB=$!
	bg_slow > "$OUT/bg-slow.log" 2>&1 & SLOW_JOB=$!
	BG_JOBS="$FORMS_JOB $SLOW_JOB"
	echo "  (forms + Vita's-pace runs started in the background: jobs $BG_JOBS)"
fi

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
CSS-opacity-image file:///app0:/testpages/CSS-opacity-image.html
CSS-isolation file:///app0:/testpages/CSS-isolation.html
CSS-svg-viewbox file:///app0:/testpages/CSS-svg-viewbox.html
CSS-svg-smooth-quad file:///app0:/testpages/CSS-svg-smooth-quad.html
CSS-bg-layers-svg file:///app0:/testpages/CSS-bg-layers-svg.html
CSS-svg-arc-flags file:///app0:/testpages/CSS-svg-arc-flags.html
CSS-img-webp file:///app0:/testpages/CSS-img-webp.html
CSS-svg-fill-inherit file:///app0:/testpages/CSS-svg-fill-inherit.html
CSS-svg-child-css file:///app0:/testpages/CSS-svg-child-css.html
CSS-svg-stroke file:///app0:/testpages/CSS-svg-stroke.html
CSS-svg-aa file:///app0:/testpages/CSS-svg-aa.html
CSS-flex-column-automin file:///app0:/testpages/CSS-flex-column-automin.html
JS-style-invalid file:///app0:/testpages/JS-style-invalid.html
CSS-border-radius file:///app0:/testpages/CSS-border-radius.html
JS-float-insert file:///app0:/testpages/JS-float-insert.html
CSS-float-insert-ref file:///app0:/testpages/CSS-float-insert-ref.html
JS-float-insert-one file:///app0:/testpages/JS-float-insert-one.html
CSS-float-insert-one-ref file:///app0:/testpages/CSS-float-insert-one-ref.html
JS-table-cell-text file:///app0:/testpages/JS-table-cell-text.html
CSS-table-cell-text-ref file:///app0:/testpages/CSS-table-cell-text-ref.html
JS-table-cell-float file:///app0:/testpages/JS-table-cell-float.html
CSS-table-cell-float-ref file:///app0:/testpages/CSS-table-cell-float-ref.html
JS-remove-controls file:///app0:/testpages/JS-remove-controls.html
CSS-remove-controls-ref file:///app0:/testpages/CSS-remove-controls-ref.html
JS-table-cell-class file:///app0:/testpages/JS-table-cell-class.html
CSS-table-cell-class-ref file:///app0:/testpages/CSS-table-cell-class-ref.html
JS-style-attr file:///app0:/testpages/JS-style-attr.html
CSS-style-attr-ref file:///app0:/testpages/CSS-style-attr-ref.html
JS-flex-restyle file:///app0:/testpages/JS-flex-restyle.html
CSS-flex-restyle-ref file:///app0:/testpages/CSS-flex-restyle-ref.html
JS-gen-empty file:///app0:/testpages/JS-gen-empty.html
CSS-gen-empty-ref file:///app0:/testpages/CSS-gen-empty-ref.html
JS-gen-empty-sib file:///app0:/testpages/JS-gen-empty-sib.html
CSS-gen-empty-sib-ref file:///app0:/testpages/CSS-gen-empty-sib-ref.html
JS-counters-local file:///app0:/testpages/JS-counters-local.html
CSS-counters-local-ref file:///app0:/testpages/CSS-counters-local-ref.html
JS-bg-objects file:///app0:/testpages/JS-bg-objects.html
CSS-bg-objects-ref file:///app0:/testpages/CSS-bg-objects-ref.html
JS-objects-relink file:///app0:/testpages/JS-objects-relink.html
CSS-objects-relink-ref file:///app0:/testpages/CSS-objects-relink-ref.html
JS-block-subtree file:///app0:/testpages/JS-block-subtree.html
CSS-block-subtree-ref file:///app0:/testpages/CSS-block-subtree-ref.html
JS-mixed-siblings file:///app0:/testpages/JS-mixed-siblings.html
CSS-mixed-siblings-ref file:///app0:/testpages/CSS-mixed-siblings-ref.html
JS-late-append file:///app0:/testpages/JS-late-append.html
CSS-late-append-ref file:///app0:/testpages/CSS-late-append-ref.html
JS-late-append-struct file:///app0:/testpages/JS-late-append-struct.html
CSS-late-append-struct-ref file:///app0:/testpages/CSS-late-append-struct-ref.html
JS-struct-scoped file:///app0:/testpages/JS-struct-scoped.html
CSS-struct-scoped-ref file:///app0:/testpages/CSS-struct-scoped-ref.html
JS-struct-dir file:///app0:/testpages/JS-struct-dir.html
CSS-struct-dir-ref file:///app0:/testpages/CSS-struct-dir-ref.html
JS-struct-hits file:///app0:/testpages/JS-struct-hits.html
CSS-struct-hits-ref file:///app0:/testpages/CSS-struct-hits-ref.html
JS-leaf-insert file:///app0:/testpages/JS-leaf-insert.html
CSS-leaf-insert-ref file:///app0:/testpages/CSS-leaf-insert-ref.html
JS-style-sib-local file:///app0:/testpages/JS-style-sib-local.html
CSS-style-sib-local-ref file:///app0:/testpages/CSS-style-sib-local-ref.html
JS-style-sib-risk file:///app0:/testpages/JS-style-sib-risk.html
CSS-style-sib-risk-ref file:///app0:/testpages/CSS-style-sib-risk-ref.html
JS-sib-unreadable file:///app0:/testpages/JS-sib-unreadable.html
CSS-sib-unreadable-ref file:///app0:/testpages/CSS-sib-unreadable-ref.html
JS-sib-universal file:///app0:/testpages/JS-sib-universal.html
CSS-sib-universal-ref file:///app0:/testpages/CSS-sib-universal-ref.html
JS-class-unnamed file:///app0:/testpages/JS-class-unnamed.html
CSS-class-unnamed-ref file:///app0:/testpages/CSS-class-unnamed-ref.html
JS-class-unnamed-attr file:///app0:/testpages/JS-class-unnamed-attr.html
CSS-class-unnamed-attr-ref file:///app0:/testpages/CSS-class-unnamed-attr-ref.html
JS-sheet-noop file:///app0:/testpages/JS-sheet-noop.html
CSS-sheet-noop-ref file:///app0:/testpages/CSS-sheet-noop-ref.html
JS-inline-mid file:///app0:/testpages/JS-inline-mid.html
CSS-inline-mid-ref file:///app0:/testpages/CSS-inline-mid-ref.html
JS-attr-restyle file:///app0:/testpages/JS-attr-restyle.html
CSS-attr-restyle-ref file:///app0:/testpages/CSS-attr-restyle-ref.html
JS-domparser-svg file:///app0:/testpages/JS-domparser-svg.html
CSS-domparser-svg-ref file:///app0:/testpages/CSS-domparser-svg-ref.html
JS-root-noop file:///app0:/testpages/JS-root-noop.html
CSS-root-noop-ref file:///app0:/testpages/CSS-root-noop-ref.html
JS-float-marker file:///app0:/testpages/JS-float-marker.html
CSS-float-marker-ref file:///app0:/testpages/CSS-float-marker-ref.html
JS-style-detach-noop file:///app0:/testpages/JS-style-detach-noop.html
CSS-style-detach-noop-ref file:///app0:/testpages/CSS-style-detach-noop-ref.html
JS-flex-below file:///app0:/testpages/JS-flex-below.html
CSS-flex-below-ref file:///app0:/testpages/CSS-flex-below-ref.html
JS-control-restyle file:///app0:/testpages/JS-control-restyle.html
CSS-control-restyle-ref file:///app0:/testpages/CSS-control-restyle-ref.html
JS-control-js file:///app0:/testpages/JS-control-js.html
CSS-control-js-ref file:///app0:/testpages/CSS-control-js-ref.html
JS-content-whole file:///app0:/testpages/JS-content-whole.html
CSS-content-whole-ref file:///app0:/testpages/CSS-content-whole-ref.html
JS-reflect-proto file:///app0:/testpages/JS-reflect-proto.html
JS-style-noop file:///app0:/testpages/JS-style-noop.html
JS-sib-func file:///app0:/testpages/JS-sib-func.html
CSS-sib-func-ref file:///app0:/testpages/CSS-sib-func-ref.html
CSS-style-noop-ref file:///app0:/testpages/CSS-style-noop-ref.html
JS-sib-tail file:///app0:/testpages/JS-sib-tail.html
CSS-sib-tail-ref file:///app0:/testpages/CSS-sib-tail-ref.html
JS-flex-buttons file:///app0:/testpages/JS-flex-buttons.html
CSS-flex-buttons-ref file:///app0:/testpages/CSS-flex-buttons-ref.html
JS-head-attr file:///app0:/testpages/JS-head-attr.html
CSS-head-attr-ref file:///app0:/testpages/CSS-head-attr-ref.html
JS-class-churn file:///app0:/testpages/JS-class-churn.html
CSS-class-churn-ref file:///app0:/testpages/CSS-class-churn-ref.html
JS-object-rebuild file:///app0:/testpages/JS-object-rebuild.html
CSS-object-rebuild-ref file:///app0:/testpages/CSS-object-rebuild-ref.html
JS-style-detach file:///app0:/testpages/JS-style-detach.html
CSS-style-detach-ref file:///app0:/testpages/CSS-style-detach-ref.html
NET-js-link-detach http://127.0.0.1:$HP/NET-js-link-detach.html
CSS-link-detach-ref file:///app0:/testpages/CSS-link-detach-ref.html
NET-js-link-preload http://127.0.0.1:$HP/NET-js-link-preload.html
CSS-link-preload-ref file:///app0:/testpages/CSS-link-preload-ref.html
CSS-svg-reltq file:///app0:/testpages/CSS-svg-reltq.html
IMG-standalone file:///app0:/testpages/opimg-20.png
CSS-census file:///app0:/testpages/CSS-census.html
CSS-intrinsic file:///app0:/testpages/CSS-intrinsic-width.html
JS-event-order file:///app0:/testpages/JS-event-order.html
JS-capture-target file:///app0:/testpages/JS-capture-target.html
JS-event-phase file:///app0:/testpages/JS-event-phase.html
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
NET-js-batch-burst http://127.0.0.1:$HP/JS-batch-burst.html
NET-js-attr-local http://127.0.0.1:$HP/JS-attr-local.html
NET-js-sheet-census http://127.0.0.1:$HP/JS-sheet-census.html
NET-js-style-absorb http://127.0.0.1:$HP/JS-style-absorb.html
NET-js-sheet-scope http://127.0.0.1:$HP/JS-sheet-scope.html
NET-js-sheet-scope-unb http://127.0.0.1:$HP/JS-sheet-scope-unb.html
NET-js-sheet-scope-quirks http://127.0.0.1:$HP/JS-sheet-scope-quirks.html
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
NET-css-gcs-props http://127.0.0.1:$HP/CSS-gcs-props.html
NET-css-flex-gap http://127.0.0.1:$HP/CSS-flex-gap.html
NET-css-table-caption http://127.0.0.1:$HP/CSS-table-caption.html
NET-js-inline-rect http://127.0.0.1:$HP/JS-inline-rect.html
NET-html-hidden-details http://127.0.0.1:$HP/HTML-hidden-details.html
NET-css-flow-root http://127.0.0.1:$HP/CSS-flow-root.html
NET-css-grid-autofill http://127.0.0.1:$HP/CSS-grid-autofill.html
NET-css-grid-named-var http://127.0.0.1:$HP/CSS-grid-named-var.html
NET-css-grid-fr-minmax http://127.0.0.1:$HP/CSS-grid-fr-minmax.html
NET-css-calc-negative http://127.0.0.1:$HP/CSS-calc-negative.html
NET-css-grid-var-crosssheet http://127.0.0.1:$HP/CSS-grid-var-crosssheet.html
NET-css-grid-nested-padding http://127.0.0.1:$HP/CSS-grid-nested-padding.html
NET-css-flex-min-width-explicit http://127.0.0.1:$HP/CSS-flex-min-width-explicit.html
NET-css-grid-uniform-placement http://127.0.0.1:$HP/CSS-grid-uniform-placement.html
NET-css-grid-inline-placement http://127.0.0.1:$HP/CSS-grid-inline-placement.html
NET-css-grid-item-offsets http://127.0.0.1:$HP/CSS-grid-item-offsets.html
NET-js-style-setters http://127.0.0.1:$HP/JS-style-setters.html
NET-js-empty-text-nodes http://127.0.0.1:$HP/JS-empty-text-nodes.html
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
NET-js-import-meta http://127.0.0.1:$HP/JS-import-meta.html
NET-js-importmap http://127.0.0.1:$HP/JS-importmap.html
NET-js-custom-elements http://127.0.0.1:$HP/JS-custom-elements.html
NET-js-perfobserver http://127.0.0.1:$HP/JS-perfobserver.html
NET-js-template-text http://127.0.0.1:$HP/JS-template-text.html
NET-js-selector-list-long http://127.0.0.1:$HP/JS-selector-list-long.html
NET-js-attach-shadow http://127.0.0.1:$HP/JS-attach-shadow.html
NET-css-late-link http://127.0.0.1:$HP/CSS-late-link.html
NET-js-xorigin-frame http://127.0.0.1:$HP/JS-xorigin-frame.html
NET-js-scratch-doc http://127.0.0.1:$HP/JS-scratch-doc.html
NET-js-scratch-qsa http://127.0.0.1:$HP/JS-scratch-qsa.html
NET-js-frame-xdoc http://127.0.0.1:$HP/JS-frame-xdoc.html
NET-js-frame-document http://127.0.0.1:$HP/JS-frame-document.html
NET-js-mo-delivery http://127.0.0.1:$HP/JS-mo-delivery.html
NET-js-form-shadow http://127.0.0.1:$HP/JS-form-shadow.html
NET-js-form-shadow-chain http://127.0.0.1:$HP/JS-form-shadow-chain.html
NET-js-element-instanceof http://127.0.0.1:$HP/JS-element-instanceof.html
NET-js-node-names http://127.0.0.1:$HP/JS-node-names.html
NET-js-image-load http://127.0.0.1:$HP/JS-image-load.html
NET-js-canvas-2d http://127.0.0.1:$HP/JS-canvas-2d.html
NET-js-wasm http://127.0.0.1:$HP/JS-wasm.html
NET-js-frame-realm http://127.0.0.1:$HP/JS-frame-realm.html
NET-js-form-submit http://127.0.0.1:$HP/JS-form-submit.html
NET-css-important-operands http://127.0.0.1:$HP/CSS-important-operands.html
NET-css-style-edit http://127.0.0.1:$HP/CSS-style-edit.html
NET-js-xorigin-frame-early http://127.0.0.1:$HP/JS-xorigin-frame-early.html
NET-js-builtins-native http://127.0.0.1:$HP/JS-builtins-native.html
NET-js-perf-timing http://127.0.0.1:$HP/JS-perf-timing.html
NET-js-device-honest http://127.0.0.1:$HP/JS-device-honest.html
NET-js-window-proto http://127.0.0.1:$HP/JS-window-proto.html
NET-js-builtin-shape http://127.0.0.1:$HP/JS-builtin-shape.html
NET-js-api-protos http://127.0.0.1:$HP/JS-api-protos.html
NET-js-window-order http://127.0.0.1:$HP/JS-window-order.html
NET-js-document-shape http://127.0.0.1:$HP/JS-document-shape.html
NET-js-node-shape http://127.0.0.1:$HP/JS-node-shape.html
NET-js-descriptors http://127.0.0.1:$HP/JS-descriptors.html
NET-js-timer-nesting http://127.0.0.1:$HP/JS-timer-nesting.html
NET-js-resource-timing http://127.0.0.1:$HP/JS-resource-timing.html
NET-js-form-values http://127.0.0.1:$HP/JS-form-values.html
NET-js-form-named http://127.0.0.1:$HP/JS-form-named.html
NET-js-form-walk-cost http://127.0.0.1:$HP/JS-form-walk-cost.html
NET-js-form-target http://127.0.0.1:$HP/JS-form-target.html
NET-js-link-click http://127.0.0.1:$HP/JS-link-click.html
NET-js-block-oc-insert http://127.0.0.1:$HP/JS-block-oc-insert.html
NET-js-frames-local http://127.0.0.1:$HP/JS-frames-local.html
NET-css-frames-local-ref http://127.0.0.1:$HP/CSS-frames-local-ref.html
NET-js-flex-frame http://127.0.0.1:$HP/JS-flex-frame.html
NET-css-flex-frame-ref http://127.0.0.1:$HP/CSS-flex-frame-ref.html
NET-js-block-frame http://127.0.0.1:$HP/JS-block-frame.html
NET-css-block-frame-ref http://127.0.0.1:$HP/CSS-block-frame-ref.html
NET-js-charref http://127.0.0.1:$HP/JS-charref.html
NET-css-calc-nested http://127.0.0.1:$HP/CSS-calc-nested.html
NET-css-not-list http://127.0.0.1:$HP/CSS-not-list.html
NET-css-var-order http://127.0.0.1:$HP/CSS-var-order.html
NET-css-font-size-calc http://127.0.0.1:$HP/CSS-font-size-calc.html
NET-css-flex-auto-min-max http://127.0.0.1:$HP/CSS-flex-auto-min-max.html
NET-css-flex-blockify http://127.0.0.1:$HP/CSS-flex-blockify.html
NET-css-flex-item-width-contrib http://127.0.0.1:$HP/CSS-flex-item-width-contrib.html
NET-css-outline-alpha http://127.0.0.1:$HP/CSS-outline-alpha.html
NET
# Unit 403: GATE_REUSE_AUTOTEST=1 skips this run when every input is what
# the last PASSING gate's run had (autotest_key: the simulator binary, the
# app0: bundle, the network page list, the two helper servers, the settle
# knobs and this block itself), and restores that run's output instead --
# every check below still evaluates it. Off by default: a plain gate always
# runs it. A fresh run is cached only when the whole gate exits 0 (at the
# end), so a flaky failure is never frozen in. The bundle's ca-bundle.pem is
# Mozilla's plus this run's freshly made test CA, so it is keyed by the
# Mozilla file instead.
autotest_key() {
	{ sha256sum "$NS/nsvita-sim" | cut -c1-64
	  ( cd "$OUT/run/app0:" && find . -type f ! -path ./res/ca-bundle.pem | LC_ALL=C sort | \
	    while IFS= read -r f; do sha256sum "$f"; done )
	  sha256sum "$WORK/certs/ca-bundle.pem" "$ROOT/tools/vita-sim/httpd.py" \
		"$ROOT/tools/vita-netlog.py" | cut -c1-64
	  cat "$OUT/run/ux0:data/VitaBrowser/nettest.txt" "$OUT/run/ux0:data/VitaBrowser/netlog.cfg"
	  echo "${VITA_SETTLE_EXTRA_MS:-7000} ${NETLOG_LATE:-15} $VITA_SIM_REMOTE_PORT"
	  sed -n '/^# AUTOTEST RUN BEGIN/,/^# AUTOTEST RUN END/p' "$0"
	} | sha256sum | cut -c1-16
}
AC="$OUT/autotest-cache"; AKEY=; AFRESH=
[ "${GATE_REUSE_AUTOTEST:-0}" = 1 ] && AKEY=$(autotest_key)
if [ -n "$AKEY" ] && [ -f "$AC/$AKEY/ok" ]; then
	echo "  autotest: inputs unchanged (key $AKEY), reusing the last passing gate's run (GATE_REUSE_AUTOTEST=1)"
	rm -rf "$OUT/run/ux0:data/VitaBrowser" "$OUT/snaps" "$OUT/net"
	cp -r "$AC/$AKEY/VitaBrowser" "$OUT/run/ux0:data/VitaBrowser"
	cp -r "$AC/$AKEY/snaps" "$OUT/snaps"
	cp -r "$AC/$AKEY/net" "$OUT/net"
	cp "$AC/$AKEY/httpd.log" "$AC/$AKEY/netlog-receiver.log" "$OUT/"
else
# AUTOTEST RUN BEGIN
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
		--exit-when-done --timeout 1300 ) > "$OUT/netlog-receiver.log" 2>&1 &
	# (patch 425's gate: the receiver's timeout was 1000 s from its late
	# start; the run below may take its full 1200 s -- ~950 s of autotest
	# with this page list, more on a loaded machine -- and twice the
	# mirror lost the run's last lines and autotest.done to the
	# receiver's exit. It still exits as soon as the run is done.)
	RX=$!
	# patch 411: the engine log is not capped mid-run (16 MiB capped it
	# at page 267 of 277), and the run has room past 900 s (886 s with
	# 277 pages)
	( cd "$OUT/run" && VITA_SIM_AUTOTEST=1 VITA_SIM_SNAP="$OUT/snaps" \
		VITA_SETTLE_EXTRA_MS="${VITA_SETTLE_EXTRA_MS:-7000}" \
		VITA_SIM_ENGINE_LOG_CAP=256 \
		timeout 1200 "$NS/nsvita-sim" )
	wait $RX || true
	kill $HTTPD 2>/dev/null || true
# AUTOTEST RUN END
	if [ -n "$AKEY" ]; then
		# staged now (later sections read but do not write these); moved
		# into the cache only if the gate passes
		rm -rf "$OUT/autotest-fresh"; mkdir -p "$OUT/autotest-fresh"
		cp -r "$OUT/run/ux0:data/VitaBrowser" "$OUT/snaps" "$OUT/net" \
			"$OUT/httpd.log" "$OUT/netlog-receiver.log" "$OUT/autotest-fresh/"
		AFRESH=1
	fi
fi
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
# ...and it says why (patch 237: with mbedTLS it always said "An unknown
# error occurred while processing the certificate").
rogue_why=$(grep -o 'STR The certificate is self signed\.' "$R/21-NET-https-rogue.plot" 2>/dev/null | head -1)
echo "  21-NET-https-rogue reason: ${rogue_why:-MISSING (not \"The certificate is self signed.\")}"
if [ -f "$R/21-NET-https-rogue.plot" ] && [ "$rogue_title" = "Privacy error" ] && \
   [ -n "$rogue_why" ] && \
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

# Fetch/XHR request bodies (Patch 140; binary bodies and responseType 256; FormData files 257; multipart formData() 258; Request bodies 259): URLSearchParams serializes to
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
	[ "$r" = "JS fetch body: 30/30 passed" ] || fb_bad=$((fb_bad + 1))
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
# Capture listener on the event's own target (Patch 291): fires once at
# AT_TARGET even when the target also carries a non-capture registration.
ct=$(ls "$R"/*-JS-capture-target.plot 2>/dev/null | head -1)
ctr=$(sed -n 's/.*STR \(CAPTGT: [0-9]*\/[0-9]* passed\).*/\1/p' "$ct" 2>/dev/null | head -1)
echo "  JS-capture-target: ${ctr:-no summary}"
[ -n "$ct" ] && grep -o 'STR [0-9]* [^:]*: .*(want.*' "$ct" | sed 's/^STR /  /'
# eventPhase and the window steps of a document dispatch (Patch 298):
# a fresh event reads phase 0; document.dispatchEvent runs capture at
# window, at-target at document, bubble at window, honouring
# stopPropagation; the native element path is unchanged.
ep=$(ls "$R"/*-JS-event-phase.plot 2>/dev/null | head -1)
epr=$(sed -n 's/.*STR \(EVPHASE: [0-9]*\/[0-9]* passed\).*/\1/p' "$ep" 2>/dev/null | head -1)
echo "  JS-event-phase: ${epr:-no summary}"
[ -n "$ep" ] && grep -o 'STR [0-9]* [^:]*: .*(want.*' "$ep" | sed 's/^STR /  /'
ig=$(ls "$R"/*-CSS-inline-grid.plot 2>/dev/null | head -1)
igr=$(sed -n 's/.*STR \(INLINEGRID: [0-9]*\/[0-9]* passed\).*/\1/p' "$ig" 2>/dev/null | head -1)
echo "  CSS-inline-grid: ${igr:-no summary}"
op=$(ls "$R"/*-CSS-opacity.plot 2>/dev/null | head -1)
op_shown=$(grep -c 'STR SHOWNMARK' "$op" 2>/dev/null || true)
op_half=$(grep -c 'STR HALFMARK' "$op" 2>/dev/null || true)
op_hidden=$(grep -c 'HIDDENSPANMARK\|HIDDENBLOCKMARK' "$op" 2>/dev/null || true)
op_ldbox=$(awk '/PLOT RECT/ { if ($8 - $4 == 200 && $10 - $6 == 30) n++ } END { print n+0 }' "$op" 2>/dev/null)
# Patch 311: partial group opacity reaches text runs -- the plotter appends
# the fixes49 OPAQUE bucket to non-solid TEXT lines (.5 -> 2, .25 -> 1).
op_half_op2=$(grep -c 'STR HALFMARK OPAQUE 2$' "$op" 2>/dev/null || true)
op_outer_op3=$(grep -c 'STR OUTERMARK OPAQUE 3$' "$op" 2>/dev/null || true)
op_nested_op1=$(grep -c 'STR NESTEDMARK OPAQUE 1$' "$op" 2>/dev/null || true)
op_shown_opaque=$(grep -c 'STR SHOWNMARK.*OPAQUE' "$op" 2>/dev/null || true)
# Patch 314: partial group opacity reaches borders -- RECT sides of the
# 120-wide solid border (120x6 top/bottom, 6x32 sides) carry OPAQUE 2
# inside .half and no token outside; the double border's 8 POLYGONs and
# the dashed border's 4 LINEs likewise; the rgba(0,0,0,0.5) border is
# OPAQUE 2 standalone (colour alpha) and OPAQUE 1 inside .half (folded).
op_brect_h=$(awk '/PLOT RECT/ { if ($8 - $4 == 120 && $10 - $6 == 6 && /OPAQUE 2/) n++ } END { print n+0 }' "$op" 2>/dev/null)
op_brect_s=$(awk '/PLOT RECT/ { if ($8 - $4 == 6 && $10 - $6 == 32 && /OPAQUE 2/) n++ } END { print n+0 }' "$op" 2>/dev/null)
op_brect_ctl=$(awk '/PLOT RECT/ { if ($8 - $4 == 120 && $10 - $6 == 6 && !/OPAQUE/) n++ } END { print n+0 }' "$op" 2>/dev/null)
op_bdbl_op2=$(grep -c 'PLOT POLYGON.*OPAQUE 2' "$op" 2>/dev/null || true)
op_bdbl_all=$(grep -c 'PLOT POLYGON' "$op" 2>/dev/null || true)
# Patch 325: the dashed border's LINEs are the page's long ones (>= 20 px);
# the checkboxes' are 13 px or shorter.
op_bdash_op2=$(awk '/PLOT LINE/ { dx = $8 - $4; dy = $10 - $6; if (dx < 0) dx = -dx; if (dy < 0) dy = -dy; if ((dx >= 20 || dy >= 20) && /OPAQUE 2$/) n++ } END { print n+0 }' "$op" 2>/dev/null)
op_bdash_all=$(awk '/PLOT LINE/ { dx = $8 - $4; dy = $10 - $6; if (dx < 0) dx = -dx; if (dy < 0) dy = -dy; if (dx >= 20 || dy >= 20) n++ } END { print n+0 }' "$op" 2>/dev/null)
# Patch 325: the checked checkbox inside .half paints its 13x13 base RECT,
# four bevel LINEs and two tick LINEs at OPAQUE 2; the control outside
# paints the same seven ops with no token.
op_cbrect_op2=$(awk '/PLOT RECT/ { if ($8 - $4 == 13 && $10 - $6 == 13 && /OPAQUE 2$/) n++ } END { print n+0 }' "$op" 2>/dev/null)
op_cbrect_ctl=$(awk '/PLOT RECT/ { if ($8 - $4 == 13 && $10 - $6 == 13 && !/OPAQUE/) n++ } END { print n+0 }' "$op" 2>/dev/null)
op_cbline_op2=$(awk '/PLOT LINE/ { dx = $8 - $4; dy = $10 - $6; if (dx < 0) dx = -dx; if (dy < 0) dy = -dy; if (dx < 20 && dy < 20 && /OPAQUE 2$/) n++ } END { print n+0 }' "$op" 2>/dev/null)
op_cbline_all=$(awk '/PLOT LINE/ { dx = $8 - $4; dy = $10 - $6; if (dx < 0) dx = -dx; if (dy < 0) dy = -dy; if (dx < 20 && dy < 20) n++ } END { print n+0 }' "$op" 2>/dev/null)
op_balpha_op2=$(awk '/PLOT RECT/ { if ($8 - $4 == 100 && $10 - $6 == 6 && /OPAQUE 2/) n++ } END { print n+0 }' "$op" 2>/dev/null)
op_balpha_op1=$(awk '/PLOT RECT/ { if ($8 - $4 == 100 && $10 - $6 == 6 && /OPAQUE 1/) n++ } END { print n+0 }' "$op" 2>/dev/null)
# Patch 315 (doc 24 stage 1): bitmaps carry the composed group opacity in
# their flags -- the 20x20 no-repeat tile and the 16x16 tile repeated in
# both axes (blend mode set too) inside .half trace OPAQUE 2 and draw 1:1
# through the tint entry; the repeat control outside traces none. The
# radio's 2 DISCs + 2 ARCs and the inline SVG's PATH inside .half carry
# OPAQUE 2, the controls none. Pixels from the autotest snapshot: blue
# tile 127,127,255; red tiles 255,127,127 (first tile and the last row
# and column -- every tile faded); red control 255,0,0.
op_bg1=$(grep -c 'PLOT BITMAP .* WIDTH 20 HEIGHT 20 OPAQUE 2$' "$op" 2>/dev/null || true)
op_bgrep_op2=$(grep -c 'PLOT BITMAP .* WIDTH 16 HEIGHT 16 OPAQUE 2$' "$op" 2>/dev/null || true)
op_bgrep_ctl=$(grep -c 'PLOT BITMAP .* WIDTH 16 HEIGHT 16$' "$op" 2>/dev/null || true)
op_disc_op2=$(grep -c 'PLOT DISC .* OPAQUE 2$' "$op" 2>/dev/null || true)
op_disc_all=$(grep -c 'PLOT DISC' "$op" 2>/dev/null || true)
op_arc_op2=$(grep -c 'PLOT ARC .* OPAQUE 2$' "$op" 2>/dev/null || true)
op_arc_all=$(grep -c 'PLOT ARC' "$op" 2>/dev/null || true)
op_path_op2=$(grep -c 'PLOT PATH .* OPAQUE 2$' "$op" 2>/dev/null || true)
op_path_all=$(grep -c 'PLOT PATH' "$op" 2>/dev/null || true)
op_px=
op_snap=$(ls "$OUT"/snaps/N-*-CSS-opacity.png 2>/dev/null | head -1)
op_b20=$(grep -a -m1 -o 'PLOT BITMAP X [0-9]* Y [0-9]* WIDTH 20 HEIGHT 20 OPAQUE 2' "$op" 2>/dev/null || true)
op_b16=$(grep -a -m1 -o 'PLOT BITMAP X [0-9]* Y [0-9]* WIDTH 16 HEIGHT 16 OPAQUE 2' "$op" 2>/dev/null || true)
op_b16c=$(grep -a -m1 'PLOT BITMAP X [0-9]* Y [0-9]* WIDTH 16 HEIGHT 16$' "$op" 2>/dev/null | grep -o 'BITMAP X [0-9]* Y [0-9]*' || true)
if [ -n "$op_snap" ] && [ -n "$op_b20" ] && [ -n "$op_b16" ] && [ -n "$op_b16c" ]; then
	op_x20=$(echo "$op_b20" | awk '{print $4}'); op_y20=$(echo "$op_b20" | awk '{print $6}')
	op_x16=$(echo "$op_b16" | awk '{print $4}'); op_y16=$(echo "$op_b16" | awk '{print $6}')
	op_xc=$(echo "$op_b16c" | awk '{print $3}'); op_yc=$(echo "$op_b16c" | awk '{print $5}')
	op_px=$(python3 "$ROOT/tools/vita-sim/png-pixel.py" "$op_snap" \
		$((op_x20 + 10)),$((op_y20 + 10)) $((op_x16 + 8)),$((op_y16 + 8)) \
		$((op_x16 + 60)),$((op_y16 + 28)) $((op_xc + 8)),$((op_yc + 8)) | \
		awk '{printf "%s,%s,%s ", $2, $3, $4}')
fi
echo "  CSS-opacity: shown ${op_shown:-0} (1), half ${op_half:-0} (1), hidden ${op_hidden:-?} (0), light-dark box fills ${op_ldbox:-0} (>=1), half-text OPAQUE 2 ${op_half_op2:-?} (1), outer-text OPAQUE 3 ${op_outer_op3:-?} (1), nested-text OPAQUE 1 ${op_nested_op1:-?} (1), shown-text solid ${op_shown_opaque:-?} (0), half-border RECT ${op_brect_h:-?}/${op_brect_s:-?} (2/2), solid-border RECT ${op_brect_ctl:-?} (2), double-border POLYGON ${op_bdbl_op2:-?}/${op_bdbl_all:-?} (8/16), dashed-border LINE ${op_bdash_op2:-?}/${op_bdash_all:-?} (4/8), alpha-border OPAQUE 2/1 ${op_balpha_op2:-?}/${op_balpha_op1:-?} (2/2), bg-tile OPAQUE 2 ${op_bg1:-?} (1), bg-repeat OPAQUE 2/solid ${op_bgrep_op2:-?}/${op_bgrep_ctl:-?} (1/1), radio DISC ${op_disc_op2:-?}/${op_disc_all:-?} (2/4), radio ARC ${op_arc_op2:-?}/${op_arc_all:-?} (2/4), checkbox RECT OPAQUE 2/solid ${op_cbrect_op2:-?}/${op_cbrect_ctl:-?} (1/1), checkbox LINE ${op_cbline_op2:-?}/${op_cbline_all:-?} (6/12), svg PATH ${op_path_op2:-?}/${op_path_all:-?} (1/2), image pixels ${op_px:-none} (127,127,255 255,127,127 255,127,127 255,0,0)"
# Patch 319 (doc 24 stage 2): <img> fades with its opacity group, per
# image format the build decodes. CSS-opacity-image gives each blue
# fixture its own intrinsic size (png 20, gif 22, svg 24, bmp 26, ico 28,
# jpeg 30): at 1:1 inside .half each traces OPAQUE 2 (the tint entry), at
# 2x (40/44/48/52/56/60) OPAQUE 2 through the pre-multiplied scaled path;
# the SVG's PATHs likewise (2 faded + 1 solid control -- one PATH per
# <img>: the svg.c reformat no longer stacks the shapes). Controls (png 20
# and 40, jpeg 30) trace no token; the png inside opacity:0 (34) is not
# plotted; a 1x1 png stretched to 30x10 inside .half is image.c's 1x1
# RECT shortcut, OPAQUE 2 (control 32x10 solid); a background scaled
# 20 -> 36 and a 16 -> 24 background repeated in x, both inside .half,
# trace OPAQUE 2. Pixels from the autotest snapshot, at each leg's centre
# (positions from the trace): faded blue 127,127,255 (jpeg 127,127,254),
# solid 0,0,255 (jpeg 0,0,254), both background tiles 255,127,127, and
# white where the opacity:0 png sits. The standalone image document
# (IMG-standalone, opimg-20.png) must paint solid: one BITMAP 20x20, no
# OPAQUE token anywhere, centre 0,0,255.
echo "== image opacity (CSS-opacity-image, IMG-standalone) =="
oi=$(ls "$R"/*-CSS-opacity-image.plot 2>/dev/null | head -1)
oi_snap=$(ls "$OUT"/snaps/N-*-CSS-opacity-image.png 2>/dev/null | head -1)
oi_bad=
oi_n() { grep -c "$1" "$oi" 2>/dev/null || true; }
# one count per leg: "WIDTHxHEIGHT/suffix want"
for leg in 20/2/1 22/2/1 26/2/1 28/2/1 30/2/1 40/2/1 44/2/1 52/2/1 56/2/1 60/2/1 \
	   36/2/1 24/2/1 20/s/1 40/s/1 30/s/1 34/a/0; do
	w=${leg%%/*}; k=${leg#*/}; k=${k%/*}; want=${leg##*/}
	case "$k" in
		2) got=$(oi_n "PLOT BITMAP .* WIDTH $w HEIGHT $w OPAQUE 2\$") ;;
		s) got=$(oi_n "PLOT BITMAP .* WIDTH $w HEIGHT $w\$") ;;
		a) got=$(oi_n "PLOT BITMAP .* WIDTH $w HEIGHT $w") ;;
	esac
	[ "${got:-x}" = "$want" ] || oi_bad="$oi_bad bitmap$w/$k=${got:-none}"
done
oi_path2=$(oi_n 'PLOT PATH .* OPAQUE 2$'); oi_path=$(oi_n 'PLOT PATH')
[ "$oi_path2" = 2 ] && [ "$oi_path" = 3 ] || oi_bad="$oi_bad path=$oi_path2/$oi_path"
oi_r1=$(awk '/^PLOT RECT/ && $8 - $4 == 30 && $10 - $6 == 10 && / OPAQUE 2$/ { n++ } END { print n+0 }' "$oi" 2>/dev/null || true)
oi_r1c=$(awk '/^PLOT RECT/ && $8 - $4 == 32 && $10 - $6 == 10 && !/OPAQUE/ { n++ } END { print n+0 }' "$oi" 2>/dev/null || true)
[ "$oi_r1" = 1 ] && [ "$oi_r1c" = 1 ] || oi_bad="$oi_bad rect1x1=$oi_r1/$oi_r1c"
# Sample points, in a fixed order: the faded legs, the solid controls,
# the 1x1 pair, the background tiles, the opacity:0 spot.
oi_pts=
oi_c() {	# centre of the first BITMAP of size $1 with suffix $2 (+dx $3)
	grep -a -m1 -E "^PLOT BITMAP X [0-9]+ Y [0-9]+ WIDTH $1 HEIGHT $1$2\$" "$oi" 2>/dev/null | \
		awk -v dx="${3:-0}" '{ printf "%d,%d ", $4 + int($8 / 2) + dx, $6 + int($10 / 2) }'
}
oi_svg() {	# centre of the clip box before the Nth PATH with suffix $2
	awk -v want="$1" -v suf="$2" '/^PLOT CLIP/ { cx = int(($4 + $8) / 2); cy = int(($6 + $10) / 2) }
		/^PLOT PATH/ { s = ($0 ~ / OPAQUE 2$/) ? "2" : "s"; if (s == suf && ++n == want) { printf "%d,%d ", cx, cy; exit } }' "$oi" 2>/dev/null
}
if [ -n "$oi" ] && [ -n "$oi_snap" ]; then
	for w in 20 22 26 28 30 40 44 52 56 60; do oi_pts="$oi_pts$(oi_c $w ' OPAQUE 2')"; done
	oi_pts="$oi_pts$(oi_svg 1 2)$(oi_svg 2 2)"
	for w in 20 40 30; do oi_pts="$oi_pts$(oi_c $w '')"; done
	oi_pts="$oi_pts$(oi_svg 1 s)"
	oi_pts="$oi_pts$(awk '/^PLOT RECT/ && $8 - $4 == 30 && $10 - $6 == 10 && / OPAQUE 2$/ { printf "%d,%d %d,%d ", ($4 + $8) / 2, ($6 + $10) / 2, $4 - 23, $6 + 17; exit }' "$oi")"
	oi_pts="$oi_pts$(awk '/^PLOT RECT/ && $8 - $4 == 32 && $10 - $6 == 10 && !/OPAQUE/ { printf "%d,%d ", ($4 + $8) / 2, ($6 + $10) / 2; exit }' "$oi")"
	oi_pts="$oi_pts$(oi_c 36 ' OPAQUE 2')$(oi_c 24 ' OPAQUE 2')$(oi_c 24 ' OPAQUE 2' 24)"
	oi_px=$(python3 "$ROOT/tools/vita-sim/png-pixel.py" "$oi_snap" $oi_pts | \
		awk '{printf "%s,%s,%s ", $2, $3, $4}' || true)
fi
# faded: png gif bmp ico jpeg (1:1), the same at 2x, svg 1:1 + 2x;
# solid: png 20, png 40, jpeg, svg; 1x1 faded + the opacity:0 spot;
# 1x1 control; background scaled, repeat tile 1, tile 2.
oi_want="127,127,255 127,127,255 127,127,255 127,127,255 127,127,254 127,127,255 127,127,255 127,127,255 127,127,255 127,127,254 127,127,255 127,127,255 0,0,255 0,0,255 0,0,254 0,0,255 127,127,255 255,255,255 0,0,255 127,127,255 255,127,127 255,127,127 "
[ "${oi_px:-none}" = "$oi_want" ] || oi_bad="$oi_bad pixels"
echo "  CSS-opacity-image: counts ${oi_bad:+FAIL$oi_bad}${oi_bad:-ok} (16 bitmap legs, PATH ${oi_path2:-?}/${oi_path:-?} (2/3), 1x1 RECT ${oi_r1:-?}/${oi_r1c:-?} (1/1))"
echo "  pixels ${oi_px:-none}"
echo "  want   $oi_want"
sa=$(ls "$R"/*-IMG-standalone.plot 2>/dev/null | head -1)
sa_snap=$(ls "$OUT"/snaps/N-*-IMG-standalone.png 2>/dev/null | head -1)
sa_bm=$(grep -c 'PLOT BITMAP .* WIDTH 20 HEIGHT 20$' "$sa" 2>/dev/null || true)
sa_op=$(grep -c 'OPAQUE' "$sa" 2>/dev/null || true)
sa_px=
[ -n "$sa_snap" ] && sa_px=$(python3 "$ROOT/tools/vita-sim/png-pixel.py" "$sa_snap" \
	$(grep -a -m1 -o 'PLOT BITMAP X [0-9]* Y [0-9]* WIDTH 20 HEIGHT 20$' "$sa" | awk '{ printf "%d,%d", $4 + 10, $6 + 10 }') | \
	awk '{printf "%s,%s,%s", $2, $3, $4}' || true)
echo "  IMG-standalone: BITMAP 20x20 solid ${sa_bm:-?} (1), OPAQUE tokens ${sa_op:-?} (0), centre ${sa_px:-none} (0,0,255)"
[ -n "$oi" ] && [ -z "$oi_bad" ] && [ "${sa_bm:-0}" = 1 ] && [ "${sa_op:-1}" = 0 ] && \
	[ "$sa_px" = "0,0,255" ] || fail "image opacity (doc 24 stage 2)"

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
# Patches 326/327: math functions nest (clamp(24px, calc(100vw / 18),
# 80px)), a divisor may be followed by whitespace, and viewport/absolute
# units scale exactly (10vw = innerWidth/10, 45pt = 60px).
c326p=$(ls "$R"/*NET-css-calc-nested.plot 2>/dev/null | head -1)
c326r=$(sed -n 's/.*STR \(CALCNEST326: [0-9]*\/[0-9]* passed\).*/\1/p' "$c326p" 2>/dev/null | head -1)
echo "  css-calc-nested: ${c326r:-no summary}"
[ -n "$c326p" ] && grep -o 'STR [0-9]* [^"]*FAIL' "$c326p" | sed 's/^STR /  /'
# Patch 328: :not() takes a selector list (compound, list, complex).
n328p=$(ls "$R"/*NET-css-not-list.plot 2>/dev/null | head -1)
n328r=$(sed -n 's/.*STR \(NOTLIST328: [0-9]*\/[0-9]* passed\).*/\1/p' "$n328p" 2>/dev/null | head -1)
echo "  css-not-list: ${n328r:-no summary}"
[ -n "$n328p" ] && grep -o 'STR [0-9]* [^"]*FAIL' "$n328p" | sed 's/^STR /  /'
# Patch 329: a var() declaration competes at its own cascade position.
v329p=$(ls "$R"/*NET-css-var-order.plot 2>/dev/null | head -1)
v329r=$(sed -n 's/.*STR \(VARORDER329: [0-9]*\/[0-9]* passed\).*/\1/p' "$v329p" 2>/dev/null | head -1)
echo "  css-var-order: ${v329r:-no summary}"
[ -n "$v329p" ] && grep -o 'STR [0-9]* [^"]*FAIL' "$v329p" | sed 's/^STR /  /'
# Patch 330: a calc font-size that loses the cascade leaves the winner's
# calc expression alone.
f330p=$(ls "$R"/*NET-css-font-size-calc.plot 2>/dev/null | head -1)
f330r=$(sed -n 's/.*STR \(FSCALC330: [0-9]*\/[0-9]* passed\).*/\1/p' "$f330p" 2>/dev/null | head -1)
echo "  css-font-size-calc: ${f330r:-no summary}"
[ -n "$f330p" ] && grep -o 'STR [0-9]* [^"]*FAIL' "$f330p" | sed 's/^STR /  /'
# Patch 331: a flex item's automatic minimum is capped by its max-width.
f331p=$(ls "$R"/*NET-css-flex-auto-min-max.plot 2>/dev/null | head -1)
f331r=$(sed -n 's/.*STR \(FLEXAUTOMIN331: [0-9]*\/[0-9]* passed\).*/\1/p' "$f331p" 2>/dev/null | head -1)
echo "  css-flex-auto-min-max: ${f331r:-no summary}"
[ -n "$f331p" ] && grep -o 'STR [0-9]* [^"]*FAIL' "$f331p" | sed 's/^STR /  /'
# Patch 333: display:inline children of flex/grid containers blockify.
b333p=$(ls "$R"/*NET-css-flex-blockify.plot 2>/dev/null | head -1)
b333r=$(sed -n 's/.*STR \(FLEXBLOCKIFY333: [0-9]*\/[0-9]* passed\).*/\1/p' "$b333p" 2>/dev/null | head -1)
echo "  css-flex-blockify: ${b333r:-no summary}"
[ -n "$b333p" ] && grep -o 'STR [0-9]* [^"]*FAIL' "$b333p" | sed 's/^STR /  /'
# Patch 334: a flex item's specified width is its max-content contribution.
c334p=$(ls "$R"/*NET-css-flex-item-width-contrib.plot 2>/dev/null | head -1)
c334r=$(sed -n 's/.*STR \(FLEXCONTRIB334: [0-9]*\/[0-9]* passed\).*/\1/p' "$c334p" 2>/dev/null | head -1)
echo "  css-flex-item-width-contrib: ${c334r:-no summary}"
[ -n "$c334p" ] && grep -o 'STR [0-9]* [^"]*FAIL' "$c334p" | sed 's/^STR /  /'
# Patch 336: grid line names are not tracks; var() in
# grid-template-columns expands from this sheet (rem/em as 16px px).
g336p=$(ls "$R"/*NET-css-grid-named-var.plot 2>/dev/null | head -1)
g336r=$(sed -n 's/.*STR \(GRIDNAMES336: [0-9]*\/[0-9]* passed\).*/\1/p' "$g336p" 2>/dev/null | head -1)
echo "  css-grid-named-var: ${g336r:-no summary}"
[ -n "$g336p" ] && grep -o 'STR [0-9]* [^"]*FAIL' "$g336p" | sed 's/^STR /  /'
# Patch 337: fr sizing honours minmax floors as max(N, share); minmax(0, N)
# grows toward N before fr tracks share the rest.
g337p=$(ls "$R"/*NET-css-grid-fr-minmax.plot 2>/dev/null | head -1)
g337r=$(sed -n 's/.*STR \(GRIDFR337: [0-9]*\/[0-9]* passed\).*/\1/p' "$g337p" 2>/dev/null | head -1)
echo "  css-grid-fr-minmax: ${g337r:-no summary}"
[ -n "$g337p" ] && grep -o 'STR [0-9]* [^"]*FAIL' "$g337p" | sed 's/^STR /  /'
# Patches 338/339: mixed-sign calc() sums are exact; padding never negative.
c339p=$(ls "$R"/*NET-css-calc-negative.plot 2>/dev/null | head -1)
c339r=$(sed -n 's/.*STR \(CALCNEG339: [0-9]*\/[0-9]* passed\).*/\1/p' "$c339p" 2>/dev/null | head -1)
echo "  css-calc-negative: ${c339r:-no summary}"
[ -n "$c339p" ] && grep -o 'STR [0-9]* [^"]*FAIL' "$c339p" | sed 's/^STR /  /'
# Patch 340: grid track var() from another sheet; keyword tracks keep the
# list. Patches 341/342: nested grids do not inherit tracks; grid padding.
x340p=$(ls "$R"/*NET-css-grid-var-crosssheet.plot 2>/dev/null | head -1)
x340r=$(sed -n 's/.*STR \(GRIDXSHEET340: [0-9]*\/[0-9]* passed\).*/\1/p' "$x340p" 2>/dev/null | head -1)
echo "  css-grid-var-crosssheet: ${x340r:-no summary}"
[ -n "$x340p" ] && grep -o 'STR [0-9]* [^"]*FAIL' "$x340p" | sed 's/^STR /  /'
n341p=$(ls "$R"/*NET-css-grid-nested-padding.plot 2>/dev/null | head -1)
n341r=$(sed -n 's/.*STR \(GRIDNEST341: [0-9]*\/[0-9]* passed\).*/\1/p' "$n341p" 2>/dev/null | head -1)
echo "  css-grid-nested-padding: ${n341r:-no summary}"
[ -n "$n341p" ] && grep -o 'STR [0-9]* [^"]*FAIL' "$n341p" | sed 's/^STR /  /'
# Patch 345: an explicit min-width turns off the flex automatic minimum;
# a definite flex-basis 0 stays 0.
m345p=$(ls "$R"/*NET-css-flex-min-width-explicit.plot 2>/dev/null | head -1)
m345r=$(sed -n 's/.*STR \(FLEXMINW345: [0-9]*\/[0-9]* passed\).*/\1/p' "$m345p" 2>/dev/null | head -1)
echo "  css-flex-min-width-explicit: ${m345r:-no summary}"
[ -n "$m345p" ] && grep -o 'STR [0-9]* [^"]*FAIL' "$m345p" | sed 's/^STR /  /'
# Patch 347: BBC's grids -- calc max-width, repeat(24, 1fr), grid item
# sizing and margins, per-axis placement.
u347p=$(ls "$R"/*NET-css-grid-uniform-placement.plot 2>/dev/null | head -1)
u347r=$(sed -n 's/.*STR \(GRIDUNI347: [0-9]*\/[0-9]* passed\).*/\1/p' "$u347p" 2>/dev/null | head -1)
echo "  css-grid-uniform-placement: ${u347r:-no summary}"
[ -n "$u347p" ] && grep -o 'STR [0-9]* [^"]*FAIL' "$u347p" | sed 's/^STR /  /'
# Patch 348: grid placement in style="" and element.style.
i348p=$(ls "$R"/*NET-css-grid-inline-placement.plot 2>/dev/null | head -1)
i348r=$(sed -n 's/.*STR \(GRIDINL348: [0-9]*\/[0-9]* passed\).*/\1/p' "$i348p" 2>/dev/null | head -1)
echo "  css-grid-inline-placement: ${i348r:-no summary}"
[ -n "$i348p" ] && grep -o 'STR [0-9]* [^"]*FAIL' "$i348p" | sed 's/^STR /  /'
# Patch 349: grid items' margins/borders, outer-height alignment, the
# container's definite height.
o349p=$(ls "$R"/*NET-css-grid-item-offsets.plot 2>/dev/null | head -1)
o349r=$(sed -n 's/.*STR \(GRIDOFS349: [0-9]*\/[0-9]* passed\).*/\1/p' "$o349p" 2>/dev/null | head -1)
echo "  css-grid-item-offsets: ${o349r:-no summary}"
[ -n "$o349p" ] && grep -o 'STR [0-9]* [^"]*FAIL' "$o349p" | sed 's/^STR /  /'
# Patch 351: element.style setters for every supported property.
s351p=$(ls "$R"/*NET-js-style-setters.plot 2>/dev/null | head -1)
s351r=$(sed -n 's/.*STR \(STYLESET351: [0-9]*\/[0-9]* passed\).*/\1/p' "$s351p" 2>/dev/null | head -1)
echo "  js-style-setters: ${s351r:-no summary}"
[ -n "$s351p" ] && grep -o 'STR [0-9]* [^"]*FAIL' "$s351p" | sed 's/^STR /  /'
# Patch 353: empty text nodes render nothing.
e353p=$(ls "$R"/*NET-js-empty-text-nodes.plot 2>/dev/null | head -1)
e353r=$(sed -n 's/.*STR \(EMPTYTXT353: [0-9]*\/[0-9]* passed\).*/\1/p' "$e353p" 2>/dev/null | head -1)
echo "  js-empty-text-nodes: ${e353r:-no summary}"
[ -n "$e353p" ] && grep -o 'STR [0-9]* [^"]*FAIL' "$e353p" | sed 's/^STR /  /'
# Patch 335: outlines honour their colour's alpha and the group opacity.
# The five 200x20 boxes' 204x24 outline rects: the two transparent ones
# draw nothing, the 50% one and the one inside opacity:.5 trace OPAQUE 2,
# the opaque one no token (5 rects, no tokens, before the patch).
o335p=$(ls "$R"/*NET-css-outline-alpha.plot 2>/dev/null | head -1)
o335all=$(awk '/^PLOT RECT/ && $8 - $4 == 204 && $10 - $6 == 24 { n++ } END { print n + 0 }' "$o335p" 2>/dev/null)
o335op2=$(awk '/^PLOT RECT/ && $8 - $4 == 204 && $10 - $6 == 24 && /OPAQUE 2$/ { n++ } END { print n + 0 }' "$o335p" 2>/dev/null)
echo "  css-outline-alpha: outline rects ${o335all:-?} (3), OPAQUE 2 ${o335op2:-?} (2)"
# Patch 332: isolation: isolate creates a stacking context. The z-index:-1
# fill inside the isolated button paints black over its card; the control
# (isolation: auto) is covered by its card (white, and culled from the
# plot), as in Chromium. Pixels from the snapshot, 18px left of and 20px
# above each button's text mark (inside its fill).
i332p=$(ls "$R"/*-CSS-isolation.plot 2>/dev/null | head -1)
i332s=$(ls "$OUT"/snaps/N-*-CSS-isolation.png 2>/dev/null | head -1)
i332a=$(grep -a -o 'PLOT TEXT X [0-9]* Y [0-9]* STR ISOMARK' "$i332p" 2>/dev/null | awk '{ print $4 - 18 "," $6 - 20; exit }')
i332b=$(grep -a -o 'PLOT TEXT X [0-9]* Y [0-9]* STR CTLMARK' "$i332p" 2>/dev/null | awk '{ print $4 - 18 "," $6 - 20; exit }')
i332px=
if [ -n "$i332s" ] && [ -n "$i332a" ] && [ -n "$i332b" ]; then
	i332px=$(python3 "$ROOT/tools/vita-sim/png-pixel.py" "$i332s" \
		"$i332a" "$i332b" | awk '{printf "%s,%s,%s ", $2, $3, $4}')
fi
echo "  css-isolation: isolated fill / control ${i332px:-none} (0,0,0 255,255,255)"
# Patch 343: inline SVG viewBox applies (scaled, negative min-y, 960-unit
# Material box). Fixed layout; snapshot pixels.
v343s=$(ls "$OUT"/snaps/N-*-CSS-svg-viewbox.png 2>/dev/null | head -1)
v343px=
if [ -n "$v343s" ]; then
	v343px=$(python3 "$ROOT/tools/vita-sim/png-pixel.py" "$v343s" \
		36,66 12,42 24,106 24,170 24,140 | \
		awk '{printf "%s,%s,%s ", $2, $3, $4}')
fi
echo "  css-svg-viewbox: ${v343px:-none} (255,0,0 238,238,238 255,0,0 255,0,0 238,238,238)"
# Patch 344: relative t / q in inline SVG paths (libsvgtiny reflection).
q344s=$(ls "$OUT"/snaps/N-*-CSS-svg-smooth-quad.png 2>/dev/null | head -1)
q344px=
if [ -n "$q344s" ]; then
	q344px=$(python3 "$ROOT/tools/vita-sim/png-pixel.py" "$q344s" \
		72,72 72,46 24,50 | awk '{printf "%s,%s,%s ", $2, $3, $4}')
fi
echo "  css-svg-smooth-quad: ${q344px:-none} (255,0,0 238,238,238 255,0,0)"
# Patch 352: layered backgrounds keep the top layer; SVG viewBox honours
# preserveAspectRatio (HN's vote arrows).
b352s=$(ls "$OUT"/snaps/N-*-CSS-bg-layers-svg.png 2>/dev/null | head -1)
b352px=
if [ -n "$b352s" ]; then
	b352px=$(python3 "$ROOT/tools/vita-sim/png-pixel.py" "$b352s" \
		20,30 4,30 20,80 4,80 20,54 | awk '{printf "%s,%s,%s ", $2, $3, $4}')
fi
echo "  css-bg-layers-svg: ${b352px:-none} (153,153,153 255,255,255 153,153,153 255,255,255 255,255,255)"
# Patch 354: SVG arc flags without separators (YouTube's icons).
a354s=$(ls "$OUT"/snaps/N-*-CSS-svg-arc-flags.png 2>/dev/null | head -1)
a354px=
if [ -n "$a354s" ]; then
	a354px=$(python3 "$ROOT/tools/vita-sim/png-pixel.py" "$a354s" \
		24,64 24,51 4,44 | awk '{printf "%s,%s,%s ", $2, $3, $4}')
fi
echo "  css-svg-arc-flags: ${a354px:-none} (255,0,0 255,0,0 255,255,255)"
# Patch 355: WebP images decode (bbc.com story images).
w355s=$(ls "$OUT"/snaps/N-*-CSS-img-webp.png 2>/dev/null | head -1)
w355px=
if [ -n "$w355s" ]; then
	w355px=$(python3 "$ROOT/tools/vita-sim/png-pixel.py" "$w355s" \
		10,60 30,60 | awk '{printf "%s,%s,%s ", $2, $3, $4}')
fi
echo "  css-img-webp: ${w355px:-none} (255,0,0 0,0,255)"
# Patch 356: inline SVG takes the CSS fill it inherits.
f356s=$(ls "$OUT"/snaps/N-*-CSS-svg-fill-inherit.png 2>/dev/null | head -1)
f356px=
if [ -n "$f356s" ]; then
	f356px=$(python3 "$ROOT/tools/vita-sim/png-pixel.py" "$f356s" \
		20,60 20,92 20,124 20,156 20,188 20,220 | awk '{printf "%s,%s,%s ", $2, $3, $4}')
fi
echo "  css-svg-fill-inherit: ${f356px:-none} (255,0,0 0,0,255 255,128,0 0,170,0 255,255,255 0,0,255)"
# Patch 357: page CSS reaches inline SVG children.
c357s=$(ls "$OUT"/snaps/N-*-CSS-svg-child-css.png 2>/dev/null | head -1)
c357px=
if [ -n "$c357s" ]; then
	c357px=$(python3 "$ROOT/tools/vita-sim/png-pixel.py" "$c357s" \
		20,60 20,92 20,124 20,156 20,188 20,220 20,252 | awk '{printf "%s,%s,%s ", $2, $3, $4}')
fi
echo "  css-svg-child-css: ${c357px:-none} (255,136,0 0,170,0 255,255,255 255,136,0 255,0,255 0,170,0 255,0,255)"
# Patch 358: CSS stroke / stroke-width on inline SVG.
s358s=$(ls "$OUT"/snaps/N-*-CSS-svg-stroke.png 2>/dev/null | head -1)
s358px=
if [ -n "$s358s" ]; then
	s358px=$(python3 "$ROOT/tools/vita-sim/png-pixel.py" "$s358s" \
		8,72 24,72 8,128 12,184 8,240 | awk '{printf "%s,%s,%s ", $2, $3, $4}')
fi
echo "  css-svg-stroke: ${s358px:-none} (255,0,0 255,255,255 0,170,0 0,0,255 255,255,255)"
# Patch 359: antialiased SVG path fills -- a half-covered diagonal pixel
# and a 1px bar straddling two columns read 127 grey, as background and
# inline (the old centre-sampled filler drew one column solid, one empty).
a359s=$(ls "$OUT"/snaps/N-*-CSS-svg-aa.png 2>/dev/null | head -1)
a359px=
if [ -n "$a359s" ]; then
	a359px=$(python3 "$ROOT/tools/vita-sim/png-pixel.py" "$a359s" \
		5,75 35,45 10,50 60,60 61,60 10,98 60,108 61,108 | awk '{printf "%s,%s,%s ", $2, $3, $4}')
fi
echo "  css-svg-aa: ${a359px:-none} (0,0,0 255,255,255 127,127,127 127,127,127 127,127,127 127,127,127 127,127,127 127,127,127)"
# Patch 360: a column flex container counts its `flex: 1` item's content
# (the automatic minimum), so the footer after it stays below (google.com's
# search form was under its footer); getComputedStyle().flexGrow answers
# instead of overflowing the stack.
f360s=$(ls "$OUT"/snaps/N-*-CSS-flex-column-automin.png 2>/dev/null | head -1)
f360px=
if [ -n "$f360s" ]; then
	f360px=$(python3 "$ROOT/tools/vita-sim/png-pixel.py" "$f360s" \
		10,50 10,70 10,150 10,170 10,190 | awk '{printf "%s,%s,%s ", $2, $3, $4}')
fi
echo "  css-flex-column-automin: ${f360px:-none} (0,0,255 0,170,0 0,170,0 255,0,0 0,170,0)"
# Patch 361: el.style ignores a NaN/undefined write-back (an authored
# width:200px stays 200px wide) and reads the authored style attribute
# (style="display:none" reads 'none', so the toggle shows it).
s361s=$(ls "$OUT"/snaps/N-*-JS-style-invalid.png 2>/dev/null | head -1)
s361px=
if [ -n "$s361s" ]; then
	s361px=$(python3 "$ROOT/tools/vita-sim/png-pixel.py" "$s361s" \
		150,50 300,50 150,70 | awk '{printf "%s,%s,%s ", $2, $3, $4}')
fi
echo "  js-style-invalid: ${s361px:-none} (0,170,0 255,255,255 0,170,0)"
# Patch 363: rounded corners -- the four corners (shorthand, longhands,
# logical names), a solid one-colour border as a ring, a mixed border and
# its background kept square, a translucent ring.
r363s=$(ls "$OUT"/snaps/N-*-CSS-border-radius.png 2>/dev/null | head -1)
r363px=
if [ -n "$r363s" ]; then
	r363px=$(python3 "$ROOT/tools/vita-sim/png-pixel.py" "$r363s" \
		12,42 60,70 122,42 122,97 232,42 280,41 280,70 342,42 346,46 \
		452,42 547,42 562,42 610,41 | awk '{printf "%s,%s,%s ", $2, $3, $4}')
fi
echo "  css-border-radius: ${r363px:-none} (255,255,255 0,170,0 255,255,255 0,170,0 255,255,255 0,0,255 0,170,0 0,0,255 0,170,0 255,255,255 0,170,0 255,255,255 127,127,255)"
# Patch 346: libsvgtiny staged, its relative t / q fixed at source -- the
# same wave through the <img> path, no serializer rewrite.
r346s=$(ls "$OUT"/snaps/N-*-CSS-svg-reltq.png 2>/dev/null | head -1)
r346px=
if [ -n "$r346s" ]; then
	r346px=$(python3 "$ROOT/tools/vita-sim/png-pixel.py" "$r346s" \
		72,72 72,46 24,50 | awk '{printf "%s,%s,%s ", $2, $3, $4}')
fi
r346p=$(ls "$R"/*-CSS-svg-reltq.plot 2>/dev/null | head -1)
r346n=$(grep -c '^PLOT PATH' "$r346p" 2>/dev/null || true)
r346o=$(grep -c '^PLOT PATH .* OPAQUE' "$r346p" 2>/dev/null || true)
echo "  css-svg-reltq: dip/hump/background ${r346px:-none} (255,0,0 238,238,238 255,0,0), ${r346n:-0} paths drawn (>=1), ${r346o:-0} OPAQUE (0)"
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
# Patches 238-240 (github.com) share this loop: import.meta.url, import
# maps, custom element constructors + document.firstElementChild +
# PerformanceObserver entry lists.
# Patches 233-236 (make.wordpress.org's o2 app): a raw-text element's own
# innerHTML unescaped (233), offsetParent / offsetTop per CSSOM View (234),
# getComputedStyle for an element with no box (235), inline style outranks
# author rules whatever matched last (236, libcss).
o2_bad=
for g in "js-innerhtml-raw IHRAW 6" "js-offsetparent OFFPARENT 8" \
	 "js-computed-unboxed UNBOXED 7" "css-inline-outranks INLINE236 4" \
	 "js-import-meta IMPORTMETA 4" "js-importmap IMPORTMAP 4" \
	 "js-custom-elements CUSTOMEL 7" "js-perfobserver PERFOBS 2" \
	 "js-template-text TPLTEXT 4" "js-selector-list-long LONGLIST 4" \
	 "js-attach-shadow SHADOW 7" "css-late-link LATELINK 3" \
	 "js-xorigin-frame XFRAME 9" "js-scratch-doc SCRATCHDOC 6" \
	 "js-scratch-qsa SCRATCHQSA 6" "js-frame-xdoc XDOC 4" "js-frame-document XDOC2 10" \
	 "js-mo-delivery MODELIV 6" \
	 "js-form-shadow FORMSHADOW 6" \
	 "js-form-shadow-chain FSHADOW2 10" \
	 "js-element-instanceof INSTOF 6" "js-node-names NODENAME 8" \
	 "js-image-load IMGLOAD 11" "js-canvas-2d CANVAS251 22" \
	 "js-wasm WASM254 15" "js-frame-realm REALM 11" \
	 "css-important-operands IMPORTANT264 3" \
	 "css-style-edit STYLEEDIT 4" "css-gcs-props GCSPROPS 9" \
	 "css-flex-gap FLEXGAP 5" \
	 "js-xorigin-frame-early XEARLY 3" \
	 "js-builtins-native BUILTIN 8" "js-perf-timing PERFTIME 10" \
	 "js-device-honest DEVICE 6" "js-window-proto WINPROTO 6" \
	 "js-builtin-shape BSHAPE 8" "js-api-protos APIPROTO 7" \
	 "js-window-order WINORDER 5" "js-document-shape DOCSHAPE 6" \
	 "js-node-shape NODESHAPE 6" "js-descriptors DESCRIPTORS 7" \
	 "js-timer-nesting TIMERNEST 4" "js-resource-timing RESTIMING 9" \
	 "js-form-values FORMVAL 8" "js-form-named FORMNAMED 7" \
	 "js-form-target FORMTARGET 5" "js-charref CHARREF 6" \
	 "js-link-click LINKCLICK 5" "js-block-oc-insert OCINS 7"; do
	set -- $g
	gp=$(ls "$R"/*NET-$1.plot 2>/dev/null | head -1)
	gr=$(sed -n "s/.*STR \($2: [0-9]*\/[0-9]* passed\).*/\1/p" "$gp" 2>/dev/null | head -1)
	echo "  $1: ${gr:-no summary}"
	[ -n "$gp" ] && grep -o 'STR [0-9] [^"]*FAIL' "$gp" | sed 's/^STR /  /'
	[ "$gr" = "$2: $3/$3 passed" ] || o2_bad="$o2_bad $1"
done
# Patches 263 + 265: a form a script builds is submitted by a hidden submit
# button's click(), with its fields -- the page's dump is the gate httpd's
# /echo answer, the request body: three pre-checks passed, the submit
# event fired, the fields encoded. Before: nothing was submitted (263), or
# an empty body (265).
fsp=$(ls "$R"/*NET-js-form-submit.plot 2>/dev/null | head -1)
fsr=$(grep -a -o 'res=passed3of3&ev=fired&k=v+1' "$fsp" 2>/dev/null | head -1)
echo "  js-form-submit: ${fsr:-no echoed body (the form was not submitted)}"
[ "$fsr" = "res=passed3of3&ev=fired&k=v+1" ] || o2_bad="$o2_bad js-form-submit"
# Patch 251: the page's own canvas reaches the screen -- its bitmap is
# plotted at the canvas's size, and the autotest's snapshot shows the
# drawing there (the disc's blue at its centre, the yellow ground near a
# corner). Before 251 nothing was plotted at all.
cvp=$(ls "$R"/*NET-js-canvas-2d.plot 2>/dev/null | head -1)
cvb=$(grep -a -m1 -o 'PLOT BITMAP X [0-9]* Y [0-9]* WIDTH 240 HEIGHT 80' "$cvp" 2>/dev/null || true)
cvs=$(ls "$OUT"/snaps/N-*-NET-js-canvas-2d.png 2>/dev/null | head -1)
cvpx=
if [ -n "$cvb" ] && [ -n "$cvs" ]; then
	set -- $cvb
	cvpx=$(python3 "$ROOT/tools/vita-sim/png-pixel.py" "$cvs" \
		$(($4 + 40)),$(($6 + 40)) $(($4 + 230)),$(($6 + 5)) | \
		awk '{printf "%s,%s,%s ", $2, $3, $4}')
fi
echo "  js-canvas-2d on screen: ${cvb:-no canvas bitmap plotted}; pixels ${cvpx:-none}"
[ "$cvpx" = "0,85,170 255,204,0 " ] || o2_bad="$o2_bad js-canvas-2d-screen"
# Patch 254: JS-wasm's two long calls (about 5 s each) are sliced -- the
# frontend draws a frame every 200 ms of them (log: "wasm: a call ran N ms,
# M frames drawn during it"); without slicing the page sat frozen.
wsl=$(awk '/page [0-9]*\/[0-9]* NET-js-wasm: navigate/ {on=1; next}
	on && /page [0-9]*\/[0-9]* [^ ]*: navigate/ {on=0}
	on' "$R/log.txt" 2>/dev/null | grep -o 'wasm: a call ran [0-9]* ms, [0-9]* frames' || true)
wsn=$(printf '%s\n' "$wsl" | grep -c 'frames' || true)
wsf=$(printf '%s\n' "$wsl" | sed -n 's/.*ms, \([0-9]*\) frames/\1/p' | sort -n | head -1)
echo "  js-wasm slicing: ${wsn} long calls, fewest frames in one: ${wsf:-none}"
[ "${wsn:-0}" -ge 2 ] && [ "${wsf:-0}" -ge 10 ] || o2_bad="$o2_bad js-wasm-slices"
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
# Patch 364: a block holding images or form controls a script inserts is
# built alone and the page laid out once (JS-block-oc-insert's two
# inserts); before, each was a full box-tree rebuild.
ocl=$(grep -c 'LIFE rebuild local: blocks rebuilt ([0-9]* added, [0-9]* removed), full layout (new block holds images or form controls)' "$R/netsurf.log" || true)
echo "  JS-block-oc-insert: ${ocl} image/control blocks built alone (2 or more)"
[ "${ocl:-0}" -ge 2 ] || fail "image/control blocks built alone"
# Patch 365: floats a script inserts or removes among blocks are placed
# where the DOM has them (built alone, page laid out once). Each page
# must render as the same final DOM written statically, row for row (one
# insert: before, the float drew below the last block; eight inserts,
# moves and a removal), and the engine log must show the float path.
fl_rows() {
	fa=$(ls "$OUT"/snaps/N-*-"$1".png 2>/dev/null | head -1)
	fb=$(ls "$OUT"/snaps/N-*-"$2".png 2>/dev/null | head -1)
	if [ -n "$fa" ] && [ -n "$fb" ]; then
		python3 "$ROOT/tools/vita-sim/png-rows-diff.py" "$fa" "$fb"
	else
		echo missing
	fi
}
flr1=$(fl_rows JS-float-insert-one CSS-float-insert-one-ref)
flr8=$(fl_rows JS-float-insert CSS-float-insert-ref)
fll=$(grep -c 'LIFE rebuild local: blocks rebuilt ([0-9]* added, [0-9]* removed), full layout (\(a float\|floats\) among the blocks)' "$R/netsurf.log" || true)
echo "  JS-float-insert: rows differing from the static page: one $flr1 (0), eight $flr8 (0); ${fll} float changes built alone (4 or more)"
[ "$flr1" = 0 ] && [ "$flr8" = 0 ] && [ "${fll:-0}" -ge 4 ] ||
	fail "script floats placed as the static page"
# Patch 366: a script changing a table cell's text rebuilds the cell's
# content and lays the page out once (before: a full box-tree rebuild).
# The ten-step page renders row for row as the same steps run at parse
# time, and the engine log shows the cell path.
tcr=$(fl_rows JS-table-cell-text CSS-table-cell-text-ref)
tcl=$(grep -c 'LIFE rebuild local: rebuilt, full layout (a table cell)' "$R/netsurf.log" || true)
echo "  JS-table-cell-text: rows differing from the parse-time build $tcr (0); ${tcl} cell changes rebuilt alone (5 or more)"
[ "$tcr" = 0 ] && [ "${tcl:-0}" -ge 5 ] || fail "table cell text rebuilt alone"
# Patch 367: the same for a cell holding floats (before: a full rebuild,
# its float list made it "not one line container of plain content").
tfr=$(fl_rows JS-table-cell-float CSS-table-cell-float-ref)
tfl=$(grep -c 'LIFE rebuild local: rebuilt, full layout (a table cell with floats)' "$R/netsurf.log" || true)
echo "  JS-table-cell-float: rows differing from the parse-time build $tfr (0); ${tfl} cell-with-float changes rebuilt alone (5 or more)"
[ "$tfr" = 0 ] && [ "${tfl:-0}" -ge 5 ] || fail "table cell with floats rebuilt alone"
# Patch 368: a block holding form controls a script removes is unlinked
# locally, its controls released (before: a full rebuild). The page also
# changes a table cell's own class (still the full rebuild) and renders
# row for row as the same steps run at parse time.
rcr=$(fl_rows JS-remove-controls CSS-remove-controls-ref)
rcl=$(grep -c "LIFE rebuild local: removed block's controls released" "$R/netsurf.log" || true)
echo "  JS-remove-controls: rows differing from the parse-time build $rcr (0); ${rcl} control blocks removed locally (3 or more)"
[ "$rcr" = 0 ] && [ "${rcl:-0}" -ge 3 ] || fail "control blocks removed locally"
# Patch 369: a class change on a table cell's own box builds the cell's
# table again (before: a full rebuild); the nine-step page renders row for
# row as the same steps run at parse time.
tkr=$(fl_rows JS-table-cell-class CSS-table-cell-class-ref)
tkl=$(grep -c "LIFE rebuild local: table restyled, full layout (a cell's own class)" "$R/netsurf.log" || true)
echo "  JS-table-cell-class: rows differing from the parse-time build $tkr (0); ${tkl} cell class changes restyled with their table (5 or more)"
[ "$tkr" = 0 ] && [ "${tkl:-0}" -ge 5 ] || fail "cell class changes restyle the table"
# Patch 370: a style attribute change restyles locally, as a class change
# (before: always a full rebuild); the eleven-step page renders row for
# row as the same steps run at parse time.
sar=$(fl_rows JS-style-attr CSS-style-attr-ref)
sal=$(grep -c "LIFE rebuild local: style attribute change, as a class change" "$R/netsurf.log" || true)
echo "  JS-style-attr: rows differing from the parse-time build $sar (0); ${sal} style attribute changes taken locally (8 or more)"
[ "$sar" = 0 ] && [ "${sal:-0}" -ge 8 ] || fail "style attribute changes taken locally"
# Patch 372: a class or style change on a flex or grid container's own
# box builds the container again on its own and lays the page out whole
# (before: a full rebuild). The twelve-step page renders row for row as
# the same steps run at parse time; one made inline-flex and a class a
# sibling rule sees still take the full rebuild. Patch 375: a container
# holding an image is restyled alone too, its object entry carried over.
fxr=$(fl_rows JS-flex-restyle CSS-flex-restyle-ref)
fxl=$(grep -c "LIFE rebuild local: flex or grid box restyled, full layout" "$R/netsurf.log" || true)
fxo=$(grep -c "LIFE rebuild local: objects re-pointed [1-9]" "$R/netsurf.log" || true)
fxi=$(grep -c "LIFE rebuild local: restyled flex or grid box is no longer a block-level box here" "$R/netsurf.log" || true)
echo "  JS-flex-restyle: rows differing from the parse-time build $fxr (0); ${fxl} flex/grid containers restyled alone (8 or more); objects carried over ${fxo} (1 or more); declined: made inline ${fxi} (1 or more)"
[ "$fxr" = 0 ] && [ "${fxl:-0}" -ge 8 ] && [ "${fxo:-0}" -ge 1 ] &&
	[ "${fxi:-0}" -ge 1 ] || fail "flex and grid containers restyled alone"
# Patch 373: a change in a block with ::before/::after, or content
# arriving in an empty block, builds the block again on its own (before:
# a full rebuild, "block is not one line container"). Both pages render
# row for row as the same steps at parse time; a sibling rule testing
# :empty and a counting block (patch 374: its own ::before increments a
# counter) keep the full rebuild.
ger=$(fl_rows JS-gen-empty CSS-gen-empty-ref)
ges=$(fl_rows JS-gen-empty-sib CSS-gen-empty-sib-ref)
gel=$(grep -c "LIFE rebuild local: \(a block with generated content\|content in an empty block\), the block built again" "$R/netsurf.log" || true)
gee=$(grep -c "LIFE rebuild local: declined (a sibling rule tests :empty)" "$R/netsurf.log" || true)
gec=$(grep -c "LIFE rebuild local: declined (the restyled block takes part in counting)" "$R/netsurf.log" || true)
echo "  JS-gen-empty: rows differing from the parse-time build $ger (0), sibling/counter page $ges (0); ${gel} blocks built again (8 or more); declined: :empty sibling rule ${gee} (1 or more), counting block ${gec} (1 or more)"
[ "$ger" = 0 ] && [ "$ges" = 0 ] && [ "${gel:-0}" -ge 8 ] &&
	[ "${gee:-0}" -ge 1 ] && [ "${gec:-0}" -ge 1 ] ||
	fail "generated-content and empty blocks built again"
# Patch 374: on a page that shows a counter, local builds go on unless
# the rebuilt subtree takes part in counting (before: 369/372/373
# declined on any counter in page CSS, and the line path never checked).
# The nine-step page renders row for row as the same steps at parse time;
# its five non-counting changes are taken locally, a numbered heading, a
# line holding a span that shows or increments the counter, and a flex
# holding a counting item keep the full rebuild.
k374r=$(fl_rows JS-counters-local CSS-counters-local-ref)
k374l=$(awk '/ page [0-9]+\/[0-9]+ JS-counters-local: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log" |
	grep -c "LIFE rebuild local: \(rebuilt and laid out\|flex or grid box restyled\|table restyled\|.*the block built again\)" || true)
k374b=$(grep -c "LIFE rebuild local: declined (the restyled block takes part in counting)" "$R/netsurf.log" || true)
k374n=$(grep -c "LIFE rebuild local: declined (the line takes part in counting)" "$R/netsurf.log" || true)
k374f=$(grep -c "LIFE rebuild local: declined (the restyled flex or grid box takes part in counting)" "$R/netsurf.log" || true)
k374o=$(grep -c "LIFE rebuild local: declined (a counter shown in page CSS)\|could reach outside its \(table\|flex\)" "$R/netsurf.log" || true)
echo "  JS-counters-local: rows differing from the parse-time build $k374r (0); ${k374l} changes built locally on the page (5 or more); counting declines: block ${k374b}, line ${k374n}, flex ${k374f} (1 or more each); page-wide counter declines ${k374o} (0)"
[ "$k374r" = 0 ] && [ "${k374l:-0}" -ge 5 ] && [ "${k374b:-0}" -ge 1 ] &&
	[ "${k374n:-0}" -ge 1 ] && [ "${k374f:-0}" -ge 1 ] && [ "${k374o:-0}" = 0 ] ||
	fail "counters across a local build"
# Patch 374, objects: a local rebuild never frees a box an object entry
# points at (a CSS background image too: the entry's load callback and the
# full reconvert's relink read o->box -- rte crashed there). The page
# renders row for row as the same steps at parse time; the backgrounded
# line declines, the plain ones stay local. Patch 375: the backgrounded
# track is restyled alone, its entries moved to the new boxes.
k374bgr=$(fl_rows JS-bg-objects CSS-bg-objects-ref)
k374bgf=$(grep -c "LIFE rebuild local: declined (an object (a background) is in the restyled flex or grid box)\|declined (restyled flex or grid box holds objects" "$R/netsurf.log" || true)
k374bgl=$(grep -c "LIFE rebuild local: declined (an object (a background) is in the line)" "$R/netsurf.log" || true)
echo "  JS-bg-objects: rows differing from the parse-time build $k374bgr (0); flex declines on objects ${k374bgf} (0, patch 375); backgrounded line declined ${k374bgl} (1 or more)"
[ "$k374bgr" = 0 ] && [ "${k374bgf:-0}" = 0 ] && [ "${k374bgl:-0}" -ge 1 ] ||
	fail "local rebuilds keep the boxes objects point at"
# Patch 375: a restyled flex, block or table holding images or background
# images is rebuilt alone, its object entries moved to the new boxes
# (before: declined). The page renders row for row as the same steps at
# parse time -- every image still drawn -- with four changes local.
k375r=$(fl_rows JS-objects-relink CSS-objects-relink-ref)
k375l=$(awk '/ page [0-9]+\/[0-9]+ JS-objects-relink: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log" |
	grep -c "LIFE rebuild local: \(flex or grid box restyled\|block restyled\|table restyled\)" || true)
k375o=$(grep -c "LIFE rebuild local: objects re-pointed [1-9]" "$R/netsurf.log" || true)
echo "  JS-objects-relink: rows differing from the parse-time build $k375r (0); ${k375l} changes rebuilt locally on the page (4 or more); ${k375o} rebuilds re-pointed objects (2 or more)"
[ "$k375r" = 0 ] && [ "${k375l:-0}" -ge 4 ] && [ "${k375o:-0}" -ge 2 ] ||
	fail "objects carried over by local rebuilds"
# Patch 376: a class or style change on a block holding more than text
# (child blocks, images) builds the block again whole and lays the page
# out once (before: "restyled element is not a plain block of text", a
# full rebuild). The page renders row for row as the same steps at parse
# time; a list and a block holding a float keep the full rebuild.
k376r=$(fl_rows JS-block-subtree CSS-block-subtree-ref)
k376l=$(awk '/ page [0-9]+\/[0-9]+ JS-block-subtree: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log" |
	grep -c "LIFE rebuild local: block subtree restyled" || true)
k376d=$(grep -c "LIFE rebuild local: declined (restyled block holds floats or list markers)" "$R/netsurf.log" || true)
# (Patch 420: the list and the block holding a float are restyled alone
# too now -- 7 subtrees, no float/marker declines.)
echo "  JS-block-subtree: rows differing from the parse-time build $k376r (0); ${k376l} block subtrees restyled on the page (7 or more); floats/markers declines ${k376d} (0)"
[ "$k376r" = 0 ] && [ "${k376l:-0}" -ge 7 ] && [ "${k376d:-1}" -eq 0 ] ||
	fail "non-plain blocks restyled alone"
# Patch 377: blocks inserted into or removed from a parent that also
# holds flex/grid/table boxes, inline content or a <script> are placed
# locally and the page laid out whole (before: "parent holds more than
# blocks", a full rebuild). The page renders row for row as the same steps
# at parse time; a block that would split a line, a removal that would
# join two lines and a removed inline element keep the full rebuild.
k377r=$(fl_rows JS-mixed-siblings CSS-mixed-siblings-ref)
k377l=$(awk '/ page [0-9]+\/[0-9]+ JS-mixed-siblings: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log" |
	grep -c "LIFE rebuild local: blocks rebuilt ([0-9]* added, [0-9]* removed), full layout (\(flex, grid or table\|inline content\) among the blocks)" || true)
k377s=$(grep -c "LIFE rebuild local: declined (new block would split a line)" "$R/netsurf.log" || true)
k377j=$(grep -c "LIFE rebuild local: declined (removal would join two lines)" "$R/netsurf.log" || true)
k377e=$(grep -c "LIFE rebuild local: declined (inline content among the blocks lost an element)" "$R/netsurf.log" || true)
k377f=$(grep -c "LIFE rebuild local: new box normalised as a \(flex or grid\|table\)" "$R/netsurf.log" || true)
echo "  JS-mixed-siblings: rows differing from the parse-time build $k377r (0); ${k377l} block changes placed among mixed siblings (5 or more); declined: split ${k377s}, join ${k377j}, inline element lost ${k377e} (1 or more each); new flex boxes ${k377f} (1 or more)"
[ "$k377r" = 0 ] && [ "${k377l:-0}" -ge 5 ] && [ "${k377s:-0}" -ge 1 ] &&
	[ "${k377j:-0}" -ge 1 ] && [ "${k377e:-0}" -ge 1 ] && [ "${k377f:-0}" -ge 1 ] ||
	fail "block changes among mixed siblings"
# Patch 378: a child-list change that adds or removes no element with a
# box (a <script> appended to <body> or <html>) needs no rebuild, and an
# <iframe> or <img> appended at the end is built alone (before: full
# rebuilds, "new element is not a plain block"). Both pages render row for
# row as the same steps at parse time; a <script> that takes a <p>'s
# :first-child keeps the full rebuild, as does an <iframe> mid-page.
# Patch 404: that :first-child match is now answered by rebuilding the
# parent's subtree (405: or by restyling the matching sibling alone); the
# guard is counted where it fires (its structural check line) and must be
# answered by one of the paths, still row for row.
k378r=$(fl_rows JS-late-append CSS-late-append-ref)
k378s=$(fl_rows JS-late-append-struct CSS-late-append-struct-ref)
k378n=$(grep -c "LIFE rebuild local: child list changed only in elements with no box" "$R/netsurf.log" || true)
k378a=$(grep -c "LIFE rebuild local: an iframe or image appended at the end, built alone" "$R/netsurf.log" || true)
k378g=$(awk '/ page [0-9]+\/[0-9]+ JS-late-append-struct: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log" |
	grep -c "LIFE rebuild local: structural check: a structural rule matches a sibling" || true)
k378h=$(awk '/ page [0-9]+\/[0-9]+ JS-late-append-struct: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log" |
	grep -c "LIFE rebuild local: structural change: the parent's subtree rebuilt\|LIFE rebuild local: structural change: [0-9]* matching siblings\{0,1\} restyled alone\|LIFE rebuild local: declined (structural selectors or counters in page CSS)" || true)
echo "  JS-late-append: rows differing from the parse-time build $k378r (0), :first-child page $k378s (0); ${k378n} child-list changes needing no rebuild (2 or more); ${k378a} iframes/images appended alone (2 or more); :first-child guard ${k378g} (1 or more), answered ${k378h} (1 or more)"
[ "$k378r" = 0 ] && [ "$k378s" = 0 ] && [ "${k378n:-0}" -ge 2 ] &&
	[ "${k378a:-0}" -ge 2 ] && [ "${k378g:-0}" -ge 1 ] && [ "${k378h:-0}" -ge 1 ] ||
	fail "late appends and boxless child-list changes"
# Patch 379: the structural/counter check is scoped to the parent's
# children (before: page-wide, patch 192). On a page with :nth-child,
# :first-of-type, :first-child and counters, a block into an unreached box,
# a <script> and a <div> among first-of-type paragraphs stay local; an
# <li> into the striped list, a <p> among the paragraphs and the counting
# headings decline. Renders row for row as the same steps at parse time.
k379r=$(fl_rows JS-struct-scoped CSS-struct-scoped-ref)
k379seg=$(awk '/ page [0-9]+\/[0-9]+ JS-struct-scoped: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log")
k379l=$(printf '%s\n' "$k379seg" | grep -c "LIFE rebuild local: blocks placed\|LIFE rebuild local: child list changed only" || true)
k379s=$(printf '%s\n' "$k379seg" | grep -c "LIFE rebuild local: structural check: a structural rule matches a sibling" || true)
k379c=$(printf '%s\n' "$k379seg" | grep -c "declined (a removed block takes part in counting)\|building a new block takes part in counting" || true)
echo "  JS-struct-scoped: rows differing from the parse-time build $k379r (0); ${k379l} changes local on the page (3 or more); structural rule matches ${k379s} (2 or more); counting ${k379c} (2 or more)"
[ "$k379r" = 0 ] && [ "${k379l:-0}" -ge 3 ] && [ "${k379s:-0}" -ge 2 ] &&
	[ "${k379c:-0}" -ge 2 ] || fail "structural check scoped to the parent"
# Patch 380: a structural rule counting earlier siblings flips only after
# a change, one counting later siblings only before it, and :first-child /
# :last-child only for the child that is or was first or last. youtube's
# shape: a bare :first-child rule with <iframe>s and <script>s appended at
# the end. Renders row for row as the same steps at parse time; four
# changes local, three declined (two positional, a <script> removal
# whole).
k380r=$(fl_rows JS-struct-dir CSS-struct-dir-ref)
k380seg=$(awk '/ page [0-9]+\/[0-9]+ JS-struct-dir: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log")
k380l=$(printf '%s\n' "$k380seg" | grep -c "LIFE rebuild local: blocks rebuilt\|LIFE rebuild local: blocks placed\|LIFE rebuild local: child list changed only" || true)
k380p=$(printf '%s\n' "$k380seg" | grep -c "LIFE rebuild local: structural range positional" || true)
k380w=$(printf '%s\n' "$k380seg" | grep -c "LIFE rebuild local: structural range whole" || true)
# Patch 404: the structural matches are answered by rebuilding the
# parent's subtree, not the page (#box's new first child, #ps's new last
# child; <body>'s two removed scripts) -- still row for row as the
# parse-time build. Patch 405 answers #box's and #ps's by restyling the
# flipped sibling alone; either answer counts.
k404s=$(printf '%s\n' "$k380seg" | grep -c "LIFE rebuild local: structural change: the parent's subtree rebuilt\|LIFE rebuild local: structural change: [0-9]* matching siblings\{0,1\} restyled alone" || true)
echo "  JS-struct-dir: rows differing from the parse-time build $k380r (0); ${k380l} changes local on the page (5 or more); declines: positional ${k380p} (2 or more), whole range ${k380w} (1 or more); structural matches answered locally ${k404s} (2 or more)"
[ "$k380r" = 0 ] && [ "${k380l:-0}" -ge 5 ] && [ "${k380p:-0}" -ge 2 ] &&
	[ "${k380w:-0}" -ge 1 ] && [ "${k404s:-0}" -ge 2 ] || fail "structural check by direction"
# Patch 405: a structural match on a bounded compound with no sibling
# combinator after it restyles only the matching siblings -- in containers
# holding an <iframe> and a text field, where 404's whole-parent rebuild
# declines. Row for row as the parse-time build; the "+" case (an .item
# inserted first, .item:first-child + .item) still takes the full rebuild
# (patch 198's sibling check declines it before any narrowing).
k405r=$(fl_rows JS-struct-hits CSS-struct-hits-ref)
k405seg=$(awk '/ page [0-9]+\/[0-9]+ JS-struct-hits: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log")
k405n=$(printf '%s\n' "$k405seg" | grep -c "LIFE rebuild local: structural change: [0-9]* matching siblings\{0,1\} restyled alone" || true)
k405d=$(printf '%s\n' "$k405seg" | grep -c "LIFE rebuild local: declined (" || true)
k406l=$(printf '%s\n' "$k405seg" | grep -c "restyled alone in [0-9]* us ([0-9]* so far), leaf boxes in place" || true)
# Patch 406: the <iframe> under #c5 > :last-child is restyled in place,
# and the quoted-attribute compound stays bounded (restyled alone).
echo "  JS-struct-hits: rows differing from the parse-time build $k405r (0); matching siblings restyled alone ${k405n} (6 or more); leaf boxes restyled in place ${k406l} (1 or more); sibling-combinator case declined ${k405d} (1 or more)"
[ "$k405r" = 0 ] && [ "${k405n:-0}" -ge 6 ] && [ "${k406l:-0}" -ge 1 ] && [ "${k405d:-0}" -ge 1 ] || fail "structural matches restyled alone"
# Patch 407: a leaf element (an image, an iframe, a form control) inserted
# between blocks is built alone and given a line of its own; an image next
# to inline text still takes the full rebuild. Row for row as the
# parse-time build.
k407r=$(fl_rows JS-leaf-insert CSS-leaf-insert-ref)
k407seg=$(awk '/ page [0-9]+\/[0-9]+ JS-leaf-insert: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log")
k407a=$(printf '%s\n' "$k407seg" | grep -c "LIFE rebuild local: a leaf element inserted between blocks, built alone" || true)
k407m=$(printf '%s\n' "$k407seg" | grep -c "LIFE rebuild local: leaf element placed in a line of its own" || true)
k407d=$(printf '%s\n' "$k407seg" | grep -c "LIFE rebuild local: declined (" || true)
# (Patch 425: the image next to inline text no longer declines -- its
# block is built again whole.)
k407w=$(printf '%s\n' "$k407seg" | grep -c "new content is not plain inline, the block built again whole" || true)
echo "  JS-leaf-insert: rows differing from the parse-time build $k407r (0); leaves built alone ${k407a} (6 or more), moved into a line of their own ${k407m} (4 or more); next to inline text: block built whole ${k407w} (1 or more), declined ${k407d}"
[ "$k407r" = 0 ] && [ "${k407a:-0}" -ge 6 ] && [ "${k407m:-0}" -ge 4 ] && [ "${k407w:-0}" -ge 1 ] || fail "leaf elements inserted between blocks"
# Patch 408: on the page's flex container, a <script> appended and an
# inert attribute set need no rebuild (were: "nearest box is not a block").
k408c=$(printf '%s\n' "$k407seg" | grep -c "LIFE rebuild local: child list changed only in elements with no box" || true)
# (Patch 425: the earlier image step no longer takes a full rebuild, the
# timing moves, and the aria-expanded mark arrives alone: a render
# decline, no rebuild either -- both answers count.)
k408a=$(printf '%s\n' "$k407seg" | grep -c "LIFE rebuild local: attribute on a box that is not a block, nothing to rebuild\|LIFE render decline slot=[0-9]* kind=1 " || true)
echo "  JS-leaf-insert (flex container): box-less child-list no-op ${k408c} (1 or more); inert attribute no-op ${k408a} (1 or more)"
[ "${k408c:-0}" -ge 1 ] && [ "${k408a:-0}" -ge 1 ] || fail "flex container child list and inert attribute"
# Patch 409: on a sheet patch 186 gives up on (.q:hover + .q), style
# attribute changes decline only for a + or ~ after a [style] selector:
# the escaped-class / descendant-[style] page takes them locally, the
# [style*="display: none"] + p page still declines (its <p> turns red);
# both row for row as their parse-time builds. (Patch 410: the page list
# may hold 384.)
k409lr=$(fl_rows JS-style-sib-local CSS-style-sib-local-ref)
k409rr=$(fl_rows JS-style-sib-risk CSS-style-sib-risk-ref)
k409lseg=$(awk '/ page [0-9]+\/[0-9]+ JS-style-sib-local: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log")
k409rseg=$(awk '/ page [0-9]+\/[0-9]+ JS-style-sib-risk: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log")
k409l=$(printf '%s\n' "$k409lseg" | grep -c "LIFE rebuild local: style attribute change, as a class change" || true)
k409ld=$(printf '%s\n' "$k409lseg" | grep -c "declined (a sibling selector can match on the style attribute)" || true)
k409rd=$(printf '%s\n' "$k409rseg" | grep -c "declined (a sibling selector can match on the style attribute)" || true)
echo "  JS-style-sib: local page rows $k409lr (0), style changes local ${k409l} (3 or more), style-sibling declines ${k409ld} (0); risk page rows $k409rr (0), declines ${k409rd} (1 or more)"
[ "$k409lr" = 0 ] && [ "$k409rr" = 0 ] && [ "${k409l:-0}" -ge 3 ] && [ "${k409ld:-1}" -eq 0 ] &&
	[ "${k409rd:-0}" -ge 1 ] || fail "style attribute changes on a sheet the sibling scan gave up on"
# Patch 412: a selector the sibling parser cannot read but with no + ~
# :empty :has() leaves the sheet precise -- JS-sib-unreadable's inserts
# and removal are placed locally; the style-sib-risk page, whose sheet
# keeps an unreadable "+" selector, still declines its block insert.
k412r=$(fl_rows JS-sib-unreadable CSS-sib-unreadable-ref)
k412seg=$(awk '/ page [0-9]+\/[0-9]+ JS-sib-unreadable: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log")
k412l=$(printf '%s\n' "$k412seg" | grep -c "LIFE rebuild local: blocks placed\|LIFE rebuild local: blocks rebuilt" || true)
k412d=$(printf '%s\n' "$k412seg" | grep -c "declined (sibling combinator may restyle on insert/remove)" || true)
k412n=$(printf '%s\n' "$k409rseg" | grep -c "declined (sibling combinator may restyle on insert/remove)" || true)
echo "  JS-sib-unreadable: rows $k412r (0), block changes local ${k412l} (3 or more), sibling declines ${k412d} (0); style-sib-risk block insert declined ${k412n} (1 or more)"
[ "$k412r" = 0 ] && [ "${k412l:-0}" -ge 3 ] && [ "${k412d:-1}" -eq 0 ] && [ "${k412n:-0}" -ge 1 ] || fail "unreadable selectors without sibling syntax"
# Patch 413: a bare *, a comment before @font-face, a plain pseudo-class
# in a left compound no longer make the sheet conservative -- the block
# inserted into .u is placed locally -- while the .a inserted after the
# first-child .a still declines (broad matches of both cannot be compared).
k413r=$(fl_rows JS-sib-universal CSS-sib-universal-ref)
k413seg=$(awk '/ page [0-9]+\/[0-9]+ JS-sib-universal: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log")
k413l=$(printf '%s\n' "$k413seg" | grep -c "LIFE rebuild local: blocks placed\|LIFE rebuild local: blocks rebuilt" || true)
k413d=$(printf '%s\n' "$k413seg" | grep -c "declined (sibling combinator may restyle on insert/remove)" || true)
# (Patch 416: :has() never matches in this libcss, so .hb:has(> .hx) is
# dropped from the sibling scan -- the .hx insert is placed locally now;
# its border never showed, in the parse-time page either.)
echo "  JS-sib-universal: rows $k413r (0), block changes local ${k413l} (2 or more), the .a insert declined ${k413d} (1)"
[ "$k413r" = 0 ] && [ "${k413l:-0}" -ge 2 ] && [ "${k413d:-0}" -eq 1 ] || fail "universal, font-face comment, plain left pseudo, :has(> x)"
# Patch 414: class changes whose tokens no selector names restyle nothing
# (<html>, <body>, a div: 4); .dark on <html>, .md\3a hide and a [class*=]
# class still restyle -- those three are never answered as no-ops.
k414r=$(fl_rows JS-class-unnamed CSS-class-unnamed-ref)
k414seg=$(awk '/ page [0-9]+\/[0-9]+ JS-class-unnamed: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log")
k414n=$(printf '%s\n' "$k414seg" | grep -c "class change names no selector" || true)
k414ar=$(fl_rows JS-class-unnamed-attr CSS-class-unnamed-attr-ref)
k414aseg=$(awk '/ page [0-9]+\/[0-9]+ JS-class-unnamed-attr: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log")
k414an=$(printf '%s\n' "$k414aseg" | grep -c "class change names no selector" || true)
echo "  JS-class-unnamed: rows $k414r (0), class changes answered as no-ops ${k414n} (4); [class*=] page rows $k414ar (0), no-ops ${k414an} (0)"
[ "$k414r" = 0 ] && [ "${k414n:-0}" -eq 4 ] && [ "$k414ar" = 0 ] && [ "${k414an:-1}" -eq 0 ] || fail "class changes no selector names"
# Patch 415: sheet marks no longer make the batch coarse. A sheet that
# matches nothing, alone and beside a paragraph's new text, restyles
# nothing (2); a class change with the still-pending sheet that styles it,
# and a sheet that restyles the paragraphs, take the full rebuild (the
# re-cascade declines, 2).
k415r=$(fl_rows JS-sheet-noop CSS-sheet-noop-ref)
k415seg=$(awk '/ page [0-9]+\/[0-9]+ JS-sheet-noop: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log")
k415n=$(printf '%s\n' "$k415seg" | grep -c "sheet change restyles nothing" || true)
k415d=$(printf '%s\n' "$k415seg" | grep -c "sheet change: declined (an element's style changes" || true)
echo "  JS-sheet-noop: rows $k415r (0), sheet batches restyling nothing ${k415n} (2 or more), re-cascade declines ${k415d} (2 or more)"
[ "$k415r" = 0 ] && [ "${k415n:-0}" -ge 2 ] && [ "${k415d:-0}" -ge 2 ] || fail "sheet batches that restyle nothing"
# Patch 416: plain inline elements between blocks are built alone and
# moved into a line of their own (2), one appended after a block gets a
# line at the end (1); a span holding an image still declines (1).
k416r=$(fl_rows JS-inline-mid CSS-inline-mid-ref)
k416seg=$(awk '/ page [0-9]+\/[0-9]+ JS-inline-mid: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log")
k416m=$(printf '%s\n' "$k416seg" | grep -c "an inline element inserted between blocks, built alone" || true)
k416e=$(printf '%s\n' "$k416seg" | grep -c "an inline element appended at the end, built alone" || true)
k416p=$(printf '%s\n' "$k416seg" | grep -c "leaf element placed in a line of its own" || true)
k416d=$(printf '%s\n' "$k416seg" | grep -c "declined (new element is not a plain block" || true)
echo "  JS-inline-mid: rows $k416r (0), between blocks ${k416m} (2), lines of their own ${k416p} (2), appended ${k416e} (1), image span declined ${k416d} (1)"
[ "$k416r" = 0 ] && [ "${k416m:-0}" -eq 2 ] && [ "${k416p:-0}" -ge 2 ] && [ "${k416e:-0}" -eq 1 ] && [ "${k416d:-0}" -ge 1 ] || fail "inline elements between blocks"
# Patch 417: attributes a sheet can see, re-selected as a class change:
# data-state, aria-pressed, data-x (3) restyled locally; an attribute on a
# <style> renders nothing (1); data-y (a sibling rule) declines (1); the
# id change keeps the kind decline -- two full rebuilds on the page.
k417r=$(fl_rows JS-attr-restyle CSS-attr-restyle-ref)
k417seg=$(awk '/ page [0-9]+\/[0-9]+ JS-attr-restyle: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log")
k417a=$(printf '%s\n' "$k417seg" | grep -c "attribute change, as a class change" || true)
k417n=$(printf '%s\n' "$k417seg" | grep -c "attribute on an element that renders nothing" || true)
k417d=$(printf '%s\n' "$k417seg" | grep -c "declined (a sibling selector can match on the data-y attribute)" || true)
k417f=$(printf '%s\n' "$k417seg" | grep -c "LIFE BATCHCAUSE cause=" || true)
echo "  JS-attr-restyle: rows $k417r (0), re-selected ${k417a} (3 or more), renders nothing ${k417n} (1), sibling decline ${k417d} (1), full rebuilds ${k417f} (2)"
[ "$k417r" = 0 ] && [ "${k417a:-0}" -ge 3 ] && [ "${k417n:-0}" -eq 1 ] && [ "${k417d:-0}" -eq 1 ] && [ "${k417f:-0}" -eq 2 ] || fail "attributes a sheet can see"
# Patch 418: DOMParser's image/svg+xml document element is the <svg> (a
# text/html one keeps <html>); appended between blocks it is placed
# locally (417's replaced leaf), no full rebuild.
k418r=$(fl_rows JS-domparser-svg CSS-domparser-svg-ref)
k418p=$(ls "$R"/*-JS-domparser-svg.plot 2>/dev/null | head -1)
k418s=$(sed -n 's/.*STR \(DOMPARSER: [0-9]*\/[0-9]* passed\).*/\1/p' "$k418p" 2>/dev/null | head -1)
k418seg=$(awk '/ page [0-9]+\/[0-9]+ JS-domparser-svg: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log")
k418l=$(printf '%s\n' "$k418seg" | grep -c "a leaf element inserted between blocks, built alone" || true)
k418f=$(printf '%s\n' "$k418seg" | grep -c "LIFE BATCHCAUSE cause=" || true)
echo "  JS-domparser-svg: ${k418s:-no summary}; rows $k418r (0), svg placed locally ${k418l} (1), full rebuilds ${k418f} (0)"
[ "$k418s" = "DOMPARSER: 3/3 passed" ] && [ "$k418r" = 0 ] && [ "${k418l:-0}" -ge 1 ] && [ "${k418f:-1}" -eq 0 ] || fail "DOMParser svg document element"
# Patch 419: root changes that re-cascade to the same styles rebuild
# nothing (js-ready, data-theme=light: 2); the dark class, which restyles
# the body, declines into the full rebuild (1).
k419r=$(fl_rows JS-root-noop CSS-root-noop-ref)
k419seg=$(awk '/ page [0-9]+\/[0-9]+ JS-root-noop: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log")
k419n=$(printf '%s\n' "$k419seg" | grep -c "root change restyles nothing" || true)
k419d=$(printf '%s\n' "$k419seg" | grep -c "root change: declined (an element's style changes" || true)
echo "  JS-root-noop: rows $k419r (0), root changes restyling nothing ${k419n} (2), declined ${k419d} (1)"
[ "$k419r" = 0 ] && [ "${k419n:-0}" -eq 2 ] && [ "${k419d:-0}" -ge 1 ] || fail "root changes that restyle nothing"
# Patch 420: blocks holding floats or list markers restyled whole (the
# float block, two list items, a list: 4 or more), none declined for it.
k420r=$(fl_rows JS-float-marker CSS-float-marker-ref)
k420seg=$(awk '/ page [0-9]+\/[0-9]+ JS-float-marker: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log")
k420l=$(printf '%s\n' "$k420seg" | grep -c "block subtree restyled, full layout\|block restyled" || true)
k420d=$(printf '%s\n' "$k420seg" | grep -c "holds floats or list markers\|holds a list marker image" || true)
k420f=$(printf '%s\n' "$k420seg" | grep -c "LIFE BATCHCAUSE cause=" || true)
echo "  JS-float-marker: rows $k420r (0), restyled ${k420l} (4 or more), float/marker declines ${k420d} (0), full rebuilds ${k420f} (0)"
[ "$k420r" = 0 ] && [ "${k420l:-0}" -ge 4 ] && [ "${k420d:-1}" -eq 0 ] && [ "${k420f:-1}" -eq 0 ] || fail "blocks holding floats or list markers"
# Patch 421: a removed <style> whose rules match nothing: the re-cascade
# without it keeps every style, so the class change after it is local
# (no "detached stylesheet pruned" decline, no full rebuild). The 388-390
# pages, whose removed sheets do matter, keep their declines above.
k421r=$(fl_rows JS-style-detach-noop CSS-style-detach-noop-ref)
k421seg=$(awk '/ page [0-9]+\/[0-9]+ JS-style-detach-noop: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log")
k421n=$(printf '%s\n' "$k421seg" | grep -c "sheet removal restyles nothing" || true)
k421d=$(printf '%s\n' "$k421seg" | grep -c "declined (detached stylesheet pruned)" || true)
k421f=$(printf '%s\n' "$k421seg" | grep -c "LIFE BATCHCAUSE cause=" || true)
echo "  JS-style-detach-noop: rows $k421r (0), removals restyling nothing ${k421n} (1), pruned declines ${k421d} (0), full rebuilds ${k421f} (0)"
[ "$k421r" = 0 ] && [ "${k421n:-0}" -ge 1 ] && [ "${k421d:-1}" -eq 0 ] && [ "${k421f:-1}" -eq 0 ] || fail "a removed sheet that matched nothing"
# Patch 422: changes below a flex or grid box (a hidden item shown, in a
# flex and a grid container; the flex container's own text) rebuild the
# container whole: 2 or more, no "nearest box" declines, no full rebuild.
k422r=$(fl_rows JS-flex-below CSS-flex-below-ref)
k422seg=$(awk '/ page [0-9]+\/[0-9]+ JS-flex-below: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log")
k422b=$(printf '%s\n' "$k422seg" | grep -c "a change below a flex or grid box" || true)
k422d=$(printf '%s\n' "$k422seg" | grep -c "declined (nearest box is not a block)" || true)
k422f=$(printf '%s\n' "$k422seg" | grep -c "LIFE BATCHCAUSE cause=" || true)
# The last step (a block made display:inline beside another block's
# restyle) declines into the one full rebuild, its dropped inline run
# freed whole (the tree stays sound for the batch's other marks).
k422i=$(printf '%s\n' "$k422seg" | grep -c "no longer a block-level box here" || true)
echo "  JS-flex-below: rows $k422r (0), containers rebuilt ${k422b} (2 or more), nearest-box declines ${k422d} (0), made-inline drops ${k422i} (1), full rebuilds ${k422f} (1)"
[ "$k422r" = 0 ] && [ "${k422b:-0}" -ge 2 ] && [ "${k422d:-1}" -eq 0 ] && [ "${k422i:-0}" -ge 1 ] && [ "${k422f:-0}" -eq 1 ] || fail "changes below a flex or grid box"
# Patch 423: containers holding stateful controls (a form's and orphan
# ones) and a flex submit button restyle locally, the values kept (rows
# as the parse-time page): 3 restyles, no controls declines, no full
# rebuild.
k423r=$(fl_rows JS-control-restyle CSS-control-restyle-ref)
k423seg=$(awk '/ page [0-9]+\/[0-9]+ JS-control-restyle: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log")
k423l=$(printf '%s\n' "$k423seg" | grep -c "flex or grid box restyled\|block subtree restyled" || true)
k423d=$(printf '%s\n' "$k423seg" | grep -c "holds controls or frames" || true)
k423f=$(printf '%s\n' "$k423seg" | grep -c "LIFE BATCHCAUSE cause=" || true)
# (The first step sets the values: an input's own value mark may take one
# full rebuild -- not the restyles, which come after it.)
echo "  JS-control-restyle: rows $k423r (0), restyled ${k423l} (3), controls declines ${k423d} (0), full rebuilds ${k423f} (1 at most)"
[ "$k423r" = 0 ] && [ "${k423l:-0}" -ge 3 ] && [ "${k423d:-1}" -eq 0 ] && [ "${k423f:-2}" -le 1 ] || fail "stateful controls through a restyle"
# Patch 424: a script's .checked / .value after layout repaints the control
# from its element (checkbox, the radio pair, the text field): row for row
# as the parse-time page, the syncs in the log, no full rebuild.
k424r=$(fl_rows JS-control-js CSS-control-js-ref)
k424seg=$(awk '/ page [0-9]+\/[0-9]+ JS-control-js: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log")
k424s=$(printf '%s\n' "$k424seg" | grep -c "LIFE control [a-z]* synced from its element" || true)
k424f=$(printf '%s\n' "$k424seg" | grep -c "LIFE BATCHCAUSE cause=" || true)
echo "  JS-control-js: rows $k424r (0), controls synced ${k424s} (3 or more), full rebuilds ${k424f} (0)"
[ "$k424r" = 0 ] && [ "${k424s:-0}" -ge 3 ] && [ "${k424f:-1}" -eq 0 ] || fail "a script's checked and value repainted"
# Patch 425: blocks given an image, child blocks, a custom element are
# built again whole (3), no full rebuild, row for row as parse time.
k425r=$(fl_rows JS-content-whole CSS-content-whole-ref)
k425seg=$(awk '/ page [0-9]+\/[0-9]+ JS-content-whole: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log")
k425w=$(printf '%s\n' "$k425seg" | grep -c "new content is not plain inline, the block built again whole" || true)
k425f=$(printf '%s\n' "$k425seg" | grep -c "LIFE BATCHCAUSE cause=" || true)
echo "  JS-content-whole: rows $k425r (0), blocks built whole ${k425w} (3), full rebuilds ${k425f} (0)"
[ "$k425r" = 0 ] && [ "${k425w:-0}" -ge 3 ] && [ "${k425f:-1}" -eq 0 ] || fail "non-inline new content built whole"
# Patch 426: accessors read through the standard prototypes
# (Reflect.get(Node.prototype, 'parentElement', el) and 23 more) equal the
# direct reads and claude's ancestor walk ends; a microtask that loops
# forever is stopped by the job deadline and the run goes on.
k426p=$(ls "$R"/*-JS-reflect-proto.plot 2>/dev/null | head -1)
k426s=$(sed -n 's/.*STR \(REFLECTPROTO: [0-9]*\/[0-9]* passed\).*/\1/p' "$k426p" 2>/dev/null | head -1)
k426seg=$(awk '/ page [0-9]+\/[0-9]+ JS-reflect-proto: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log")
k426i=$(printf '%s\n' "$k426seg" | grep -c "LIFE job exc: InternalError: interrupted" || true)
echo "  JS-reflect-proto: ${k426s:-no summary}; endless microtask stopped ${k426i} (1)"
[ "$k426s" = "REFLECTPROTO: 25/25 passed" ] && [ "${k426i:-0}" -ge 1 ] || fail "prototype accessors and the job deadline"
# Patch 427: style attribute changes on an inline-block that leave its
# style as it is need no rebuild (3); the color change still takes one.
k427r=$(fl_rows JS-style-noop CSS-style-noop-ref)
k427seg=$(awk '/ page [0-9]+\/[0-9]+ JS-style-noop: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log")
k427n=$(printf '%s\n' "$k427seg" | grep -c "style attribute change leaves the style as it is" || true)
k427f=$(printf '%s\n' "$k427seg" | grep -c "LIFE BATCHCAUSE cause=" || true)
echo "  JS-style-noop: rows $k427r (0), style changes needing no rebuild ${k427n} (3 or more), full rebuilds ${k427f} (1)"
[ "$k427r" = 0 ] && [ "${k427n:-0}" -ge 3 ] && [ "${k427f:-0}" -eq 1 ] || fail "style changes that leave the style as it is"
# Patch 427 (unit 2): :not() / :is() / :where() in a left compound keep the
# sheet precise: the insert and the #m class change are local; the .off and
# .w class changes decline precisely (two full rebuilds), never conservatively.
k427br=$(fl_rows JS-sib-func CSS-sib-func-ref)
k427bseg=$(awk '/ page [0-9]+\/[0-9]+ JS-sib-func: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log")
k427bc=$(printf '%s\n' "$k427bseg" | grep -c "declined (page CSS needs conservative sibling check)" || true)
k427bm=$(printf '%s\n' "$k427bseg" | grep -c "declined (class change moves a sibling selector)" || true)
k427bf=$(printf '%s\n' "$k427bseg" | grep -c "LIFE BATCHCAUSE cause=local" || true)
echo "  JS-sib-func: rows $k427br (0), conservative declines ${k427bc} (0), precise class declines ${k427bm} (2 or more), full rebuilds after a decline ${k427bf} (2)"
[ "$k427br" = 0 ] && [ "${k427bc:-1}" -eq 0 ] && [ "${k427bm:-0}" -ge 2 ] && [ "${k427bf:-0}" -eq 2 ] || fail ":not() / :is() / :where() in sibling rules"
# Patch 428: a flex container holding a frame is restyled alone, the frame
# carried over to its new box (twice: shown, then hidden), and the page
# renders row for row as the same steps run at parse time.
k428r=$(fl_rows NET-js-flex-frame NET-css-flex-frame-ref)
k428seg=$(awk '/ page [0-9]+\/[0-9]+ NET-js-flex-frame: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log")
k428h=$(printf '%s\n' "$k428seg" | grep -c "frames handed to the new boxes" || true)
k428x=$(printf '%s\n' "$k428seg" | grep -c "flex or grid box restyled, full layout" || true)
k428d=$(printf '%s\n' "$k428seg" | grep -c "declined (restyled flex or grid box holds controls or frames)" || true)
echo "  NET-js-flex-frame: rows $k428r (0), container restyled alone ${k428x} (3 or more), frames handed over ${k428h} (2 or more), frame declines ${k428d} (0)"
[ "$k428r" = 0 ] && [ "${k428x:-0}" -ge 3 ] && [ "${k428h:-0}" -ge 2 ] && [ "${k428d:-1}" -eq 0 ] || fail "frames carried over in a restyled flex container"
# Patch 429: a new block holding an iframe (one nested a level down) is
# built alone, like a block holding images (364), and the page renders
# row for row as the same steps run at parse time.
k429r=$(fl_rows NET-js-block-frame NET-css-block-frame-ref)
k429seg=$(awk '/ page [0-9]+\/[0-9]+ NET-js-block-frame: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log")
k429l=$(printf '%s\n' "$k429seg" | grep -c "LIFE rebuild local: blocks rebuilt" || true)
k429d=$(printf '%s\n' "$k429seg" | grep -c "declined (new element is not a plain block" || true)
echo "  NET-js-block-frame: rows $k429r (0), blocks with frames built locally ${k429l} (2 or more), not-plain declines ${k429d} (0)"
[ "$k429r" = 0 ] && [ "${k429l:-0}" -ge 2 ] && [ "${k429d:-1}" -eq 0 ] || fail "new blocks holding frames built locally"
# Patch 381: on a sheet patch 198 cannot analyse (a pseudo-class in a
# sibling rule's left compound), changes at the parent's tail -- appends
# with only box-less tags after them, removals of the last -- skip the
# sibling-combinator check (nothing boxed follows); :empty still counts.
# Renders row for row as the same steps at parse time; four changes take
# the tail path, a first insertion and an :empty fill decline.
k381r=$(fl_rows JS-sib-tail CSS-sib-tail-ref)
k381seg=$(awk '/ page [0-9]+\/[0-9]+ JS-sib-tail: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log")
k381t=$(printf '%s\n' "$k381seg" | grep -c "LIFE rebuild local: sibling check at the tail" || true)
k381l=$(printf '%s\n' "$k381seg" | grep -c "LIFE rebuild local: blocks rebuilt\|LIFE rebuild local: child list changed only" || true)
k381d=$(printf '%s\n' "$k381seg" | grep -c "declined (sibling combinator may restyle on insert/remove)\|declined (a sibling rule tests :empty)" || true)
echo "  JS-sib-tail: rows differing from the parse-time build $k381r (0); ${k381t} tail checks (3 or more), ${k381l} changes local (4 or more), ${k381d} declines (2 or more)"
[ "$k381r" = 0 ] && [ "${k381t:-0}" -ge 3 ] && [ "${k381l:-0}" -ge 4 ] &&
	[ "${k381d:-0}" -ge 2 ] || fail "sibling check at the tail"
# Patch 382: a flex container (or a block holding more than text) whose
# subtree holds buttons is rebuilt alone, its controls handed to the new
# boxes (box construction finds them by element). Renders row for row as
# the same steps at parse time; the rebuilt button still clicks; a flex
# holding a typed text field keeps the full rebuild.
k382r=$(fl_rows JS-flex-buttons CSS-flex-buttons-ref)
k382seg=$(awk '/ page [0-9]+\/[0-9]+ JS-flex-buttons: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log")
k382h=$(printf '%s\n' "$k382seg" | grep -c "LIFE rebuild local: restyled box's controls handed to the new boxes" || true)
k382d=$(printf '%s\n' "$k382seg" | grep -c "LIFE rebuild local: declined (restyled flex or grid box holds controls or frames)" || true)
# (Patch 423: the typed text field is rebuilt too now, its value read
# back from the DOM -- no stateful-control decline.)
echo "  JS-flex-buttons: rows differing from the parse-time build $k382r (0); ${k382h} rebuilds handing controls over (2 or more); stateful-control declines ${k382d} (0)"
[ "$k382r" = 0 ] && [ "${k382h:-0}" -ge 2 ] && [ "${k382d:-1}" -eq 0 ] ||
	fail "buttons handed to rebuilt boxes"
# Patch 383: a child-list change on <head> needs no rebuild (a sheet that
# arrives marks for itself), nor an inert attribute (data-*, aria-*,
# role...) on a block of blocks. Renders row for row as the same steps at
# parse time -- the <style> appended to <head> still applies.
k383r=$(fl_rows JS-head-attr CSS-head-attr-ref)
k383seg=$(awk '/ page [0-9]+\/[0-9]+ JS-head-attr: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log")
k383h=$(printf '%s\n' "$k383seg" | grep -c "LIFE rebuild local: <head>'s children changed, nothing rendered" || true)
k383a=$(printf '%s\n' "$k383seg" | grep -c "LIFE rebuild local: attribute on a block of blocks, nothing to rebuild" || true)
echo "  JS-head-attr: rows differing from the parse-time build $k383r (0); ${k383h} <head> changes needing no rebuild (3 or more); ${k383a} inert attributes (2 or more)"
[ "$k383r" = 0 ] && [ "${k383h:-0}" -ge 3 ] && [ "${k383a:-0}" -ge 2 ] ||
	fail "head changes and inert attributes need no rebuild"
# Patch 385: fixes1135's cap defers class churn instead of dropping it.
# Four class changes 600 ms apart: the span's is local, the paragraph's
# three are full rebuilds and the third is past the cap. Before 385 it
# was dropped (14 stale rows); now it waits for its window and the page
# renders row for row as the same changes at parse time.
k385r=$(fl_rows JS-class-churn CSS-class-churn-ref)
k385seg=$(awk '/ page [0-9]+\/[0-9]+ JS-class-churn: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log")
k385d=$(printf '%s\n' "$k385seg" | grep -c "LIFE cosmetic rebuild deferred" || true)
k385l=$(printf '%s\n' "$k385seg" | grep -c "LIFE rebuild local: rebuilt and laid out" || true)
echo "  JS-class-churn: rows differing from the parse-time build $k385r (0); ${k385d} class rebuilds deferred past the cap (1 or more); ${k385l} answered locally (1 or more)"
[ "$k385r" = 0 ] && [ "${k385d:-0}" -ge 1 ] && [ "${k385l:-0}" -ge 1 ] ||
	fail "class churn past the cap is deferred, not dropped"
# Patch 386: <object>/<embed> survive a full rebuild. Three full
# rebuilds (one after an <object>'s block is removed) against a STATIC
# reference of the final state. Before 386 every object drew blank
# (180 rows); the relink retired the new tree's own entries.
k386r=$(fl_rows JS-object-rebuild CSS-object-rebuild-ref)
k386seg=$(awk '/ page [0-9]+\/[0-9]+ JS-object-rebuild: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log")
k386k=$(printf '%s\n' "$k386seg" | grep -c "LIFE full rebuild kept [0-9]* new object/embed entries" || true)
echo "  JS-object-rebuild: rows differing from the static final state $k386r (0); ${k386k} full rebuilds keeping the new tree's objects (2 or more)"
[ "$k386r" = 0 ] && [ "${k386k:-0}" -ge 2 ] ||
	fail "objects and embeds survive a full rebuild"
# Patch 388: the in-sim test 387's entry asked for -- a <style> that
# leaves the DOM during the page's lifetime stops cascading. The page
# inserts and removes two sheets (parse-time #sA, script-inserted
# #sB); each removal is a <head> no-op (383), so a class toggle on
# the watched paragraph forces the rebuild whose up-front prune must
# drop the detached entry -- the local path declines, the full
# reconvert paints without the sheet. Final state vs the static
# reference, row for row; the declines must be in the page's log.
# (The 387 walk read a removed node's cut chain as attached -- 388
# ends it on the document's type; without that fix both boxes stay
# red and the rows differ.)
k388r=$(fl_rows JS-style-detach CSS-style-detach-ref)
k388seg=$(awk '/ page [0-9]+\/[0-9]+ JS-style-detach: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log")
k388d=$(printf '%s\n' "$k388seg" | grep -c "LIFE rebuild local: declined (detached stylesheet pruned)" || true)
k388p=$(printf '%s\n' "$k388seg" | grep -c "WORK reconvert: pruned" || true)
echo "  JS-style-detach: rows differing from the static final state $k388r (0); ${k388d} local rebuilds declined on a pruned sheet (2 or more); full-reconvert prunes $k388p"
[ "$k388r" = 0 ] && [ "${k388d:-0}" -ge 2 ] ||
fail "a removed <style> stops cascading"
# Patch 389: a <link> that leaves the DOM stops cascading too. The
# 387/388 prune could not see a link's entry (created with node ==
# NULL), so a removed <link> kept cascading through every rebuild.
# 389 gives the entry its element and checks the sheet's content
# object: a settled sheet is released at the prune; a sheet removed
# mid-flight keeps its handle in the slot for the fetch's callback
# (whose lookup-by-handle would trip its assert on a NULLed slot).
# The page removes #b1's settled sheet and #b2's /slow/ sheet before
# it lands; the class toggle forces the rebuild whose up-front prune
# drops both. Final state vs the static reference, row for row.
k389r=$(fl_rows NET-js-link-detach CSS-link-detach-ref)
k389seg=$(awk '/ page [0-9]+\/[0-9]+ NET-js-link-detach: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log")
k389d=$(printf '%s\n' "$k389seg" | grep -c "LIFE rebuild local: declined (detached stylesheet pruned)" || true)
k389p=$(printf '%s\n' "$k389seg" | grep -c "WORK reconvert: pruned" || true)
k389s=$(sed -n 's/.*STR \(LINKDETACH: [0-9]*\/[0-9]* passed\).*/\1/p' "$(ls "$R"/*NET-js-link-detach*.plot 2>/dev/null | head -1)" 2>/dev/null | head -1)
echo "  NET-js-link-detach: rows differing from the static final state $k389r (0); ${k389d} local rebuilds declined on a pruned sheet (1 or more); full-reconvert prunes $k389p; ${k389s:-no summary}"
[ "$k389r" = 0 ] && [ "${k389d:-0}" -ge 1 ] && [ "$k389s" = "LINKDETACH: 3/3 passed" ] ||
fail "a removed <link> stops cascading"
# Unit 390: census -- a <link rel=preload as=stylesheet> never cascades:
# the rel check in html_css_process_link (strcasestr(rel, "stylesheet"))
# returns before any fetch, so no sheet entry exists and the 387/388/389
# prune has nothing to see. A real stylesheet with the same URL takes the
# normal path: it cascades after the page is DONE, and once it leaves the
# DOM the prune drops it. b1 stays blue through the whole preload phase,
# goes red only while the real sheet lives, blue again after its removal
# (the class toggle forces the rebuild whose up-front prune drops it).
# Final state vs the static reference, row for row.
k390r=$(fl_rows NET-js-link-preload CSS-link-preload-ref)
k390seg=$(awk '/ page [0-9]+\/[0-9]+ NET-js-link-preload: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log")
k390d=$(printf '%s\n' "$k390seg" | grep -c "LIFE rebuild local: declined (detached stylesheet pruned)" || true)
k390p=$(printf '%s\n' "$k390seg" | grep -c "WORK reconvert: pruned" || true)
k390s=$(sed -n 's/.*STR \(LINKPRELOAD: [0-9]*\/[0-9]* passed\).*/\1/p' "$(ls "$R"/*NET-js-link-preload*.plot 2>/dev/null | head -1)" 2>/dev/null | head -1)
echo "  NET-js-link-preload: rows differing from the static final state $k390r (0); ${k390d} local rebuilds declined on a pruned sheet (1 or more); full-reconvert prunes $k390p; ${k390s:-no summary}"
[ "$k390r" = 0 ] && [ "${k390d:-0}" -ge 1 ] && [ "$k390s" = "LINKPRELOAD: 3/3 passed" ] ||
fail "a preload never cascades; the same-URL stylesheet does, and prunes"
# Patch 371: a page with frames takes the local paths too (before: every
# change refused, "page has frames"). Its eleven steps render row for row
# as the same steps run at parse time; on that page the changes above and
# below the frame are rebuilt locally (laid out whole: a frame after the
# change keeps the relayout from moving it); a removed frame -- in a
# removed block, or below a line's top level in an inline-block -- still
# takes the full rebuild.
frr=$(fl_rows NET-js-frames-local NET-css-frames-local-ref)
frl=$(awk '/ page [0-9]+\/[0-9]+ NET-js-frames-local: navigate/ {on=1; next} on && / page [0-9]+\/[0-9]+ [^ ]+: navigate/ {on=0} on' "$R/netsurf.log" |
	grep -c "LIFE rebuild local: \(rebuilt\|block restyled\|blocks rebuilt\)" || true)
frd=$(grep -c "LIFE rebuild local: declined (old content has a frame)" "$R/netsurf.log" || true)
frb=$(grep -c "LIFE rebuild local: declined (removed block holds objects or frames)" "$R/netsurf.log" || true)
frn=$(grep -c "LIFE rebuild local: declined (page has frames)" "$R/netsurf.log" || true)
echo "  JS-frames-local: rows differing from the parse-time build $frr (0); ${frl} changes rebuilt locally on the page (7 or more); frame declines: in a line ${frd} (1 or more), in a removed block ${frb} (1 or more); 'page has frames' ${frn} (0)"
[ "$frr" = 0 ] && [ "${frl:-0}" -ge 7 ] && [ "${frd:-0}" -ge 1 ] &&
	[ "${frb:-0}" -ge 1 ] && [ "${frn:-0}" = 0 ] ||
	fail "changes on a page with frames taken locally"
[ -n "$lnp" ] && grep -aho 'STR [0-9] [^"]*FAIL' $lnp | sort -u | sed 's/^STR /  /'
# Structural/counter lists (Patch 192): inserting/removing a list item on a
# page whose CSS uses :nth-child() or CSS counters declines the local path
# (following siblings would keep stale styles/counter text) and a removed
# item's marker box is freed.
lsp=$(ls "$R"/*NET-js-list-structural*.plot 2>/dev/null)
lsr=$(sed -n 's/.*STR \(LISTSTRUCT: [0-9]*\/[0-9]* passed\).*/\1/p' $lsp 2>/dev/null | head -1)
# patch 379: the counter cases decline as the counting subtrees they are
lsd=$(grep -c 'LIFE rebuild local: declined (structural selectors or counters in page CSS)\|LIFE rebuild local: declined (a removed block takes part in counting)\|LIFE rebuild local: building a new block takes part in counting' "$R/netsurf.log" || true)
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
[ "$slr" = "SELECTORS: 89/89 passed" ] || { [ -n "$slp" ] && grep -aho 'STR [^"]*(want[^"]*' $slp | head -3 | sed 's/^STR /  /'; }
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
# Patch 309 (doc 20 stage 1): the 120-mark burst must trip the guard --
# with 200 paragraphs the initial-conversion budget is smaller than the
# burst's local cost, so the guard fires (guard=1) and the rest takes one
# full reconvert. The stage-0 census showed the innerHTML batch's full
# reconvert (local=1); the burst adds the guard trip. Both mechanisms are
# exercised: local answers where cheap, guard where expensive.
# Patch 376: the innerHTML batch (200 paragraphs into the empty #big) is
# now built locally -- 373's empty-block route meets 376's subtree rebuild
# -- so the guard trip is the only full reconvert left (total=1, local=0);
# the page still reads back BATCHBURST 3/3 from its own DOM.
bbl=$(awk '/page [0-9]*\/[0-9]* NET-js-batch-burst: navigate/ {on=1; next}
	on && /page [0-9]*\/[0-9]* [^ ]*: navigate/ {on=0}
	on' "$R/netsurf.log" 2>/dev/null | grep -a 'LIFE FULLCAUSE' | tail -1)
echo "  JS-batch-burst census: ${bbl:-no FULLCAUSE}"
case "$bbl" in
	*"total=1 over=0 nonode=0 kind=0 local=0 two=0 guard=1"*) ;;
	*) o2_bad="$o2_bad js-batch-burst-census";;
esac
# Patch 313: on the attr-local page, the load innerHTML batch commits a
# local-cause full reconvert and the setAttribute batch (9 data-x
# answered locally, 1 data-flag whose attribute a used sheet references)
# commits a kind-cause full reconvert via try_local's kind gate.
# BATCHCAUSE is logged synchronously at each flush, inside the page's
# own window -- unlike the patch-308 census, which prints at the next
# navigation reset and can split a page's causes across two windows.
acl=$(awk '/page [0-9]*\/[0-9]* NET-js-attr-local: navigate/ {on=1; next}
	on && /page [0-9]*\/[0-9]* [^ ]*: navigate/ {on=0}
	on' "$R/netsurf.log" 2>/dev/null | grep -a 'LIFE BATCHCAUSE cause=' || true)
acl_kind=$(printf '%s\n' "$acl" | grep -c 'cause=kind' || true)
acl_local=$(printf '%s\n' "$acl" | grep -c 'cause=local' || true)
# Patch 417: the data-flag change (a used sheet selects on it) is no
# longer a kind decline: it is re-selected as a class change, locally.
acl_flag=$(awk '/page [0-9]*\/[0-9]* NET-js-attr-local: navigate/ {on=1; next}
	on && /page [0-9]*\/[0-9]* [^ ]*: navigate/ {on=0}
	on' "$R/netsurf.log" 2>/dev/null | grep -a -c 'data-flag attribute change, as a class change' || true)
echo "  JS-attr-local batch causes: kind=${acl_kind} (0) local=${acl_local} (1 or more); data-flag re-selected ${acl_flag} (1)"
[ "$acl_kind" -eq 0 ] && [ "$acl_local" -ge 1 ] && [ "${acl_flag:-0}" -ge 1 ] || o2_bad="$o2_bad js-attr-local-batchcause"
# Patch 316 (doc 23 stage 1): the sheet census. Each committed full
# reconvert of a nodeless batch logs which stylesheet entries marked it
# ("LIFE SHEETCAUSE sheets=N", synchronous, inside the page's window).
# The census page edits one <style> (a sheets=1 batch), then two in one
# task (sheets=2), and checks both restyles landed.
scc=$(awk '/page [0-9]*\/[0-9]* NET-js-sheet-census: navigate/ {on=1; next}
	on && /page [0-9]*\/[0-9]* [^ ]*: navigate/ {on=0}
	on' "$R/netsurf.log" 2>/dev/null | grep -a 'LIFE SHEETCAUSE sheets=' || true)
scc_one=$(printf '%s\n' "$scc" | grep -c 'sheets=1$' || true)
scc_multi=$(printf '%s\n' "$scc" | grep -c 'sheets=[2-9]' || true)
# Patch 320 gate fix: read the BOTTOM dump. The page is now taller than
# the screen (7000 px spacer, like JS-attr-local), so the autotest takes
# the bottom pass, whose 7 s settle window covers the 1500 ms legs (this
# engine's JS timers run ~450 ms late; the top dump -- taken ~700 ms after
# the first leg's repaint -- shows the initial state).
scp=$(ls "$R"/*NET-js-sheet-census-bottom.plot 2>/dev/null | head -1)
scr=$(sed -n 's/.*STR \(SHEETCENSUS: [0-9]*\/[0-9]* passed\).*/\1/p' "$scp" 2>/dev/null | head -1)
# Patch 318 (doc 23 piece A): the marks carry the sheet's identity --
# the one-sheet edit's batch logs "SHEETID single", the two-sheet task's
# "SHEETID multi", and step 3 (one <style> edited twice 150 ms apart,
# the second before the first's batch flushed) "SHEETID stale": the
# first mark's modification counter no longer matches at the flush.
sci=$(awk '/page [0-9]*\/[0-9]* NET-js-sheet-census: navigate/ {on=1; next}
	on && /page [0-9]*\/[0-9]* [^ ]*: navigate/ {on=0}
	on' "$R/netsurf.log" 2>/dev/null | grep -a 'LIFE SHEETID ' || true)
sci_single=$(printf '%s\n' "$sci" | grep -c 'SHEETID single' || true)
sci_multi=$(printf '%s\n' "$sci" | grep -c 'SHEETID multi' || true)
sci_stale=$(printf '%s\n' "$sci" | grep -c 'SHEETID stale' || true)
echo "  JS-sheet-census: ${scr:-no summary}; sheet causes single=${scc_one} multi=${scc_multi}; identity single=${sci_single} multi=${sci_multi} stale=${sci_stale}"
# Patch 417: step 3's arming attribute (data-arm, which the sheet names)
# is answered locally now, not by a kind full rebuild that held the first
# edit's batch past the second edit: each edit may get its own batch (two
# "single" identities, counters 3 and 4) instead of one "stale" one.
[ "$scr" = "SHEETCENSUS: 3/3 passed" ] && [ "$scc_one" -ge 1 ] && [ "$scc_multi" -ge 1 ] && \
	[ "$sci_single" -ge 1 ] && [ "$sci_multi" -ge 1 ] && \
	{ [ "$sci_stale" -ge 1 ] || [ "$sci_single" -ge 3 ]; } || o2_bad="$o2_bad js-sheet-census"
# Patch 320 (doc 23 B0): a <style> edit's own precise mark is answered
# with no rebuild while the <style> has no box, so each edit costs only
# the sheet's batch. The page edits four sheets (textContent, CSSOM
# insertRule, a text node's data, and one beside a paragraph edit in the
# same task): all four restyle, the paragraph's new text is painted, at
# least four marks are absorbed, and every full reconvert in the page's
# window is a sheet batch (before 320: 4 local + 4 nonode).
sab=$(awk '/page [0-9]*\/[0-9]* NET-js-style-absorb: navigate/ {on=1; next}
	on && /page [0-9]*\/[0-9]* [^ ]*: navigate/ {on=0}
	on' "$R/netsurf.log" 2>/dev/null || true)
sab_abs=$(printf '%s\n' "$sab" | grep -a -c 'LIFE STYLETEXT absorbed' || true)
sab_full=$(printf '%s\n' "$sab" | grep -a -c 'LIFE BATCHCAUSE cause=' || true)
sab_sheet=$(printf '%s\n' "$sab" | grep -a -c 'LIFE BATCHCAUSE cause=nonode' || true)
# Patch 320 gate fix: the BOTTOM dump (tall page, 7 s bottom-settle
# window; see the sheet-census note above).
sap=$(ls "$R"/*NET-js-style-absorb-bottom.plot 2>/dev/null | head -1)
sar=$(sed -n 's/.*STR \(STYLEABS: [0-9]*\/[0-9]* passed\).*/\1/p' "$sap" 2>/dev/null | head -1)
sam=$(grep -c 'STR MIXED-AFTER' "$sap" 2>/dev/null || true)
echo "  JS-style-absorb: ${sar:-no summary}; absorbed=${sab_abs} full=${sab_full} (sheet batches ${sab_sheet}); paragraph painted=${sam:-0}"
[ "$sar" = "STYLEABS: 4/4 passed" ] && [ "${sam:-0}" -ge 1 ] && [ "$sab_abs" -ge 4 ] && \
	[ "$sab_full" -ge 1 ] && [ "$sab_full" -eq "$sab_sheet" ] || o2_bad="$o2_bad js-style-absorb"
# Patch 321 (doc 23 B1): the reach census, census only. Every
# single-identified current sheet batch logs "LIFE SHEETREACH bounded
# changed=K anchors=A roots=R walked=N" or "... unbounded reason=<cause>";
# the navigation reset prints "LIFE SHEETREACHCENSUS". Three pages, one
# <style> edit per leg, each leg also asserting its restyle (bottom dump,
# 7000 px spacer as at 320). The per-leg lines must match in order (walked
# is reported, not compared). A page's census line is printed at the NEXT
# page's navigation reset, so it is read from the following page's window;
# no-source=0 there means every first edit found the old sheet's source.
sr_lines() {
	awk -v p="$1" '$0 ~ "page [0-9]+/[0-9]+ " p ": navigate" {on=1; next}
		on && /page [0-9]+\/[0-9]+ [^ ]*: navigate/ {on=0}
		on' "$R/netsurf.log" 2>/dev/null | grep -a 'LIFE SHEETREACH \(un\)\{0,1\}bounded' |
		sed 's/.*LIFE SHEETREACH //; s/ walked=[0-9]*//' | paste -sd';' -
}
sr_walked() {
	awk -v p="$1" '$0 ~ "page [0-9]+/[0-9]+ " p ": navigate" {on=1; next}
		on && /page [0-9]+\/[0-9]+ [^ ]*: navigate/ {on=0}
		on' "$R/netsurf.log" 2>/dev/null | sed -n 's/.*LIFE SHEETREACH bounded.* walked=\([0-9]*\).*/\1/p' | paste -sd',' -
}
sr_census() {
	awk -v p="$1" '$0 ~ "page [0-9]+/[0-9]+ " p ": navigate" {st=1; next}
		st == 1 && /page [0-9]+\/[0-9]+ [^ ]*: navigate/ {st=2; next}
		st == 2 && /page [0-9]+\/[0-9]+ [^ ]*: navigate/ {exit}
		st == 2 && /LIFE SHEETREACHCENSUS / {sub(/.*LIFE SHEETREACHCENSUS /, ""); print; exit}' \
		"$R/netsurf.log" 2>/dev/null
}
sr_check() {	# page summary-expected lines-expected census-expected
	srp=$(ls "$R"/*"$1"-bottom.plot 2>/dev/null | head -1)
	srs=$(sed -n 's/.*STR \(SHEETSCOPE[-A-Z]*: [0-9]*\/[0-9]* passed\).*/\1/p' "$srp" 2>/dev/null | head -1)
	srl=$(sr_lines "$1"); src=$(sr_census "$1")
	echo "  ${1#NET-}: ${srs:-no summary}; reach: ${srl:-none} (walked $(sr_walked "$1"))"
	echo "    census: ${src:-none}"
	[ "$srs" = "$2" ] && [ "$srl" = "$3" ] && [ "$src" = "$4" ] || o2_bad="$o2_bad ${1#NET-}"
}
sr_check NET-js-sheet-scope "SHEETSCOPE: 5/5 passed" \
	"bounded changed=1 anchors=1 roots=3;bounded changed=1 anchors=1 roots=2;unbounded reason=unanchored;bounded changed=1 anchors=1 roots=1;bounded changed=2 anchors=1 roots=1" \
	"bounded=4 unbounded=1 at-rule=0 counter=0 nesting=0 escape=0 unanchored=1 too-many=0 admission=0 no-source=0"
sr_check NET-js-sheet-scope-unb "SHEETSCOPE-UNB: 5/5 passed" \
	"unbounded reason=at-rule;unbounded reason=counter;unbounded reason=nesting;unbounded reason=at-rule;unbounded reason=unanchored" \
	"bounded=0 unbounded=5 at-rule=2 counter=1 nesting=1 escape=0 unanchored=1 too-many=0 admission=0 no-source=0"
sr_check NET-js-sheet-scope-quirks "SHEETSCOPE-Q: 3/3 passed" \
	"bounded changed=1 anchors=1 roots=1;unbounded reason=admission;unbounded reason=admission" \
	"bounded=1 unbounded=2 at-rule=0 counter=0 nesting=0 escape=0 unanchored=0 too-many=0 admission=2 no-source=0"
# Patch 322: a DOM walk past a <form> no longer runs the named-control
# search per member read (patch 305 wraps Node / Element members for
# forms; theguardian.com spent ~130 s of CPU in one timer). The page times
# 20 attribute-selector queries (the polyfill's JS walk) over ~2000
# elements with forms and named images -- ~3.7 s before 322, ~0.3 s after,
# bound 1500 ms on the monotonic clock -- and keeps 305's semantics (a
# control named firstChild still shadows; document named access). Bottom
# dump: the summary sits below a 7000 px spacer, as on the 320 pages.
# Patch 323 adds leg 4: the members every node shares are not 305's form
# wrappers (they moved into the form-only Proxy layer). Patch 324 adds leg
# 5: the cached named check follows attach / rename / remove.
fwp=$(ls "$R"/*NET-js-form-walk-cost-bottom.plot 2>/dev/null | head -1)
fwr=$(sed -n 's/.*STR \(FORMWALK: [0-9]*\/[0-9]* passed\).*/\1/p' "$fwp" 2>/dev/null | head -1)
fwt=$(sed -n 's/.*STR 1 attribute query x20 with forms present: \([0-9]*\) ms.*/\1/p' "$fwp" 2>/dev/null | head -1)
echo "  JS-form-walk-cost: ${fwr:-no summary}; 20 queries ${fwt:-?} ms"
[ -n "$fwp" ] && grep -o 'STR [0-9] [^"]*FAIL' "$fwp" | sed 's/^STR /  /'
[ "$fwr" = "FORMWALK: 5/5 passed" ] || o2_bad="$o2_bad js-form-walk-cost"
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
# The page checks collected in o2_bad are one link of the compound chain
# below, whose fail label names only its last group -- so a TIMERNEST miss
# read "event order / inline-grid / group opacity" (gate-320, gate382).
# Fail on them first, by name.
[ -z "$o2_bad" ] || fail "page checks:$o2_bad"

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
[ "$c326r" = "CALCNEST326: 11/11 passed" ] && \
[ "$n328r" = "NOTLIST328: 10/10 passed" ] && \
[ "$v329r" = "VARORDER329: 9/9 passed" ] && \
[ "$f330r" = "FSCALC330: 3/3 passed" ] && \
[ "$f331r" = "FLEXAUTOMIN331: 5/5 passed" ] && \
[ "$b333r" = "FLEXBLOCKIFY333: 6/6 passed" ] && \
[ "$c334r" = "FLEXCONTRIB334: 5/5 passed" ] && \
[ "$g336r" = "GRIDNAMES336: 4/4 passed" ] && \
[ "$g337r" = "GRIDFR337: 5/5 passed" ] && \
[ "$c339r" = "CALCNEG339: 5/5 passed" ] && \
[ "$x340r" = "GRIDXSHEET340: 4/4 passed" ] && \
[ "$n341r" = "GRIDNEST341: 4/4 passed" ] && \
[ "$m345r" = "FLEXMINW345: 3/3 passed" ] && \
[ "$u347r" = "GRIDUNI347: 9/9 passed" ] && \
[ "$i348r" = "GRIDINL348: 8/8 passed" ] && \
[ "$o349r" = "GRIDOFS349: 7/7 passed" ] && \
[ "$s351r" = "STYLESET351: 6/6 passed" ] && \
[ "$e353r" = "EMPTYTXT353: 7/7 passed" ] && \
[ "${o335all:-0}" -eq 3 ] && [ "${o335op2:-0}" -eq 2 ] && \
[ "$i332px" = "0,0,0 255,255,255 " ] && \
[ "$v343px" = "255,0,0 238,238,238 255,0,0 255,0,0 238,238,238 " ] && \
[ "$q344px" = "255,0,0 238,238,238 255,0,0 " ] && \
[ "$b352px" = "153,153,153 255,255,255 153,153,153 255,255,255 255,255,255 " ] && \
[ "$a354px" = "255,0,0 255,0,0 255,255,255 " ] && \
[ "$w355px" = "255,0,0 0,0,255 " ] && \
[ "$f356px" = "255,0,0 0,0,255 255,128,0 0,170,0 255,255,255 0,0,255 " ] && \
[ "$c357px" = "255,136,0 0,170,0 255,255,255 255,136,0 255,0,255 0,170,0 255,0,255 " ] && \
[ "$s358px" = "255,0,0 255,255,255 0,170,0 0,0,255 255,255,255 " ] && \
[ "$a359px" = "0,0,0 255,255,255 127,127,127 127,127,127 127,127,127 127,127,127 127,127,127 127,127,127 " ] && \
[ "$f360px" = "0,0,255 0,170,0 0,170,0 255,0,0 0,170,0 " ] && \
[ "$s361px" = "0,170,0 255,255,255 0,170,0 " ] && \
[ "$r363px" = "255,255,255 0,170,0 255,255,255 0,170,0 255,255,255 0,0,255 0,170,0 0,0,255 0,170,0 255,255,255 0,170,0 255,255,255 127,127,255 " ] && \
[ "$r346px" = "255,0,0 238,238,238 255,0,0 " ] && [ "${r346n:-0}" -ge 1 ] && [ "${r346o:-0}" -eq 0 ] && \
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
[ "$slr" = "SELECTORS: 89/89 passed" ] && \
[ "$abr" = "ACCTBAR: 5/5 passed" ] && \
[ "$appr" = "APPEAR: 6/6 passed" ] && \
[ "$cdr" = "CHARDATA: 5/5 passed" ] && \
[ "$fhr" = "FLEXHDR: 6/6 passed" ] && \
[ "$rs_ok" != no ] && [ "${rs_local:-0}" -ge 4 ] && \
[ "${rs_full:-1}" -eq 0 ] && [ "${rs_max:-99999}" -lt 16000 ] && \
[ "$lzr" = "LAZYIMG: 4/4 passed" ] && \
[ "$ifr" = "IFACES: 9/9 passed" ] && \
[ "$eor" = "EVORDER: 5/5 passed" ] && [ "$ctr" = "CAPTGT: 7/7 passed" ] && [ "$epr" = "EVPHASE: 9/9 passed" ] && [ "$igr" = "INLINEGRID: 4/4 passed" ] && \
	[ "${op_shown:-0}" -ge 1 ] && [ "${op_half:-0}" -ge 1 ] && [ "${op_hidden:-1}" -eq 0 ] && \
	[ "${op_ldbox:-0}" -ge 1 ] && [ "${op_half_op2:-0}" -eq 1 ] && \
	[ "${op_outer_op3:-0}" -eq 1 ] && [ "${op_nested_op1:-0}" -eq 1 ] && \
	[ "${op_shown_opaque:-1}" -eq 0 ] && \
	[ "${op_brect_h:-0}" -eq 2 ] && [ "${op_brect_s:-0}" -eq 2 ] && \
	[ "${op_brect_ctl:-0}" -eq 2 ] && \
	[ "${op_bdbl_op2:-0}" -eq 8 ] && [ "${op_bdbl_all:-0}" -eq 16 ] && \
	[ "${op_bdash_op2:-0}" -eq 4 ] && [ "${op_bdash_all:-0}" -eq 8 ] && \
	[ "${op_balpha_op2:-0}" -eq 2 ] && [ "${op_balpha_op1:-0}" -eq 2 ] && \
	[ "${op_bg1:-0}" -eq 1 ] && [ "${op_bgrep_op2:-0}" -eq 1 ] && [ "${op_bgrep_ctl:-0}" -eq 1 ] && \
	[ "${op_disc_op2:-0}" -eq 2 ] && [ "${op_disc_all:-0}" -eq 4 ] && \
	[ "${op_arc_op2:-0}" -eq 2 ] && [ "${op_arc_all:-0}" -eq 4 ] && \
	[ "${op_cbrect_op2:-0}" -eq 1 ] && [ "${op_cbrect_ctl:-0}" -eq 1 ] && \
	[ "${op_cbline_op2:-0}" -eq 6 ] && [ "${op_cbline_all:-0}" -eq 12 ] && \
	[ "${op_path_op2:-0}" -eq 1 ] && [ "${op_path_all:-0}" -eq 2 ] && \
	[ "$op_px" = "127,127,255 255,127,127 255,127,127 255,0,0 " ] || fail "event order / inline-grid / group opacity"

# Script-made frames (Patch 143) and timer chains (Patch 141): a same-
# origin or blank frame a script makes fires load and has a same-realm
# contentWindow with eval (Google's BotGuard runs in one); a cross-origin
# one gets no made-up window (patch 267: it is fetched, and fires load when
# the fetch ends, failed or not, as in Chromium); 300 chained
# setTimeout(fn, 1) finish quickly.
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

# Patch 283: forms submitted by the engine's own form path -- tapped, as
# without script (multipart, url-encoded, a windows-1252 page, a file
# upload), and by script with each kind of submitter. One session taps
# each Send button (the upload's file comes from VITA_SIM_UPLOAD: the Vita
# has no file chooser, the simulator's file_gadget_open takes it); the
# gate server's /form-check answers "FORMCHECK <case> ok <digest>" for a
# well-formed body, the digest every entry byte for byte (not the
# boundary). Each must be Chromium's for the same form (tools/vita-sim/
# httpd.py; Chromium given the same file, 2026-10-13). Before 283:
# multipart lines LF, names' line breaks %0A, _charset_ its own value, no
# dirname entry, a disabled fieldset's control sent, a form="" control
# missing, the first submit button sent with no submitter, an image
# submitter abandoning the submission, windows-1252 "?" for the euro and
# for what it lacks, an unknown file type sent as text/plain. Patch 287
# ("values"): what a script set -- a textarea's value, a select's value,
# an option selected -- is what is sent; a drop-down with two options
# marked sends the last (it sent both).
echo "== scriptless form submissions =="
if [ "${GATE_SERIAL:-0}" = 1 ]; then bg_forms; else wait $FORMS_JOB || true; fi
FS="$OUT/forms"; FU="$FS/q\"uote é.dat"
frc=$(cat "$FS/rc" 2>/dev/null || echo 99)
bind_note "$FS"
fgot=$(sed -n 's/.*gw title: \(FORMCHECK .*\)/\1/p' "$FS/ux0:data/VitaBrowser/log.txt" 2>/dev/null | uniq)
fbad=
for w in "multipart ok fcd2da030618" "urlencoded ok 7e9ed1917f53" \
	 "w1252 ok 01804f0f31bf" "upload ok a866dd8b3405" \
	 "img ok f147644a4326" "imgnoname ok 9663aca848e0" \
	 "nosub ok 22de21b23e38" "submit ok 22de21b23e38" \
	 "button ok 0ded7fa40b3c" "values ok 6c222d589e0b"; do
	set -- $w
	g=$(printf '%s\n' "$fgot" | grep "^FORMCHECK $1 " | tail -1)
	echo "  $1: ${g:-no submission} (Chromium: FORMCHECK $w)"
	[ "$g" = "FORMCHECK $w" ] || fbad="$fbad $1"
done
ftap=$(sed -n 's/.*gw title: \(FORMTARGET tap .*\)/\1/p' "$FS/ux0:data/VitaBrowser/log.txt" 2>/dev/null | tail -1)
echo "  target: ${ftap:-no tapped submission arrived} (Chromium: FORMTARGET tap tapped,link)"
[ "$ftap" = "FORMTARGET tap tapped,link" ] || fbad="$fbad target"
[ "$frc" -eq 0 ] && [ -z "$fbad" ] || fail "form submissions:$fbad (exit $frc)"

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
# Neither SVG page sets opacity, so no path may carry an OPAQUE token: a
# token here is a skipped or faded draw. Patch 315 let svg.c's
# uninitialised path style through, and gate 318 traced IMG-svg's paths
# OPAQUE 0 (not drawn) while the count above still read 5 (fixed in 319).
npath_op=$(grep -c '^PLOT PATH .* OPAQUE' "$sv" 2>/dev/null || true)
echo "  IMG-svg: ${npath:-0} paths drawn, ${npath_op:-?} with an OPAQUE token (0)$(grep -q LOGO-NOT-DRAWN "$sv" 2>/dev/null && echo ', ALT TEXT SHOWN')"
# mask-image icons (patch 60): the two masked spans draw their SVG icon,
# not a 24x24 block; only the two unmasked ones (-webkit-mask with a size,
# which the background shorthand cannot take, and mask-image: none) do.
mk=$(ls "$R"/*-CSS-mask.plot 2>/dev/null | head -1)
# PLOT RECT X0 x0 Y0 y0 X1 x1 Y1 y1
nblk=$(awk '/^PLOT RECT/ { if ($8 - $4 == 24 && $10 - $6 == 24) n++ } END { print n + 0 }' "$mk" 2>/dev/null)
mpath_op=$(grep -c '^PLOT PATH .* OPAQUE' "$mk" 2>/dev/null || true)
echo "  CSS-mask: $nblk solid 24x24 blocks (2 expected: the unmasked spans), ${mpath_op:-?} icon paths with an OPAQUE token (0)"
[ "$nblk" = 2 ] && [ "${mpath_op:-1}" = 0 ] || fail "mask-image icons"
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
# block of its own width; 105 must not match, 198-199 must lose; 197
# (:not(:where())) matches since patch 328.
iw=$(ls "$R"/*-CSS-iswhere.plot 2>/dev/null | head -1)
iws=$(awk '/^PLOT RECT/ && $10 - $6 == 10 && $8 - $4 < 300 { print $8 - $4 }' "$iw" 2>/dev/null | sort -n | tr '\n' ' ')
echo "  CSS-iswhere: block widths [$iws] (101 102 103 104 106 107 108 109 197 expected)"
[ "$iws" = "101 102 103 104 106 107 108 109 197 " ] || fail ":is() / :where()"
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
# patch 363: b2's rounded border is one ring path at bucket 2, not bands
bxb2r=$(grep -c '^PLOT PATH VERTICIES [0-9]* WIDTH [0-9.]* OPAQUE 2$' "$bxplot" 2>/dev/null || true)
echo "  CSS-shadow: ring $bxs1, spread $bxs2, list+initial $bxs3, hsl(from) ring $bxs4 (2 each); invalid $bxs5 (0)"
# (MacSurf's old rounded-box frame was a stroke, and the plot stream records
# fills only, so its absence is not checkable here. Patch 363: a rounded
# box's solid one-colour border is one ring path -- bxb2r -- and the square
# bands bxb2 are gone.)
echo "  CSS-shadow borders: 0.5px $bxb1 (2), rounded 50% ring paths $bxb2r (1), square bands $bxb2 (0)"
[ "$bxs1" = 2 ] && [ "$bxs2" = 2 ] && [ "$bxs3" = 2 ] && [ "$bxs4" = 2 ] && [ "$bxs5" = 0 ] &&
	[ "$bxb1" = 2 ] && [ "$bxb2r" = 1 ] && [ "$bxb2" = 0 ] ||
	fail "box-shadow / borders"
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
# Patch 363: a rounded box (107's radius+bottom one) is drawn as a path,
# clipped to its border box: count it by that clip.
rpaths() {
	awk -v w="$2" -v h="$3" '/^PLOT CLIP/ { cw = $8 - $4; ch = $10 - $6 }
		/^PLOT PATH/ && cw == w && ch == h { n++ }
		END { print n + 0 }' "$1" 2>/dev/null
}
sprb=$(( $(rects "$spplot" 11 36) + $(rpaths "$spplot" 11 36) ))
echo "  CSS-spacing: abs in flex $(rects "$spplot" 170 50) (1); radius+bottom $sprb (1); @media $(rects "$spplot" 188 11)/$(rects "$spplot" 88 11) (1/0)"
# Round 10: range-syntax media queries -- (width>=350px) and the double
# range apply at the 960-wide viewport, (width>=961px) must not.
echo "  CSS-spacing: range media $(rects "$spplot" 251 11)/$(rects "$spplot" 253 11) (1/1); width>=961px $(rects "$spplot" 252 11) (0)"
[ "$spgap" = 51 ] && [ "$(rects "$spplot" 120 11)" = 1 ] &&
	[ "$(rects "$spplot" 133 11)" = 1 ] && [ "$(rects "$spplot" 333 11)" = 0 ] &&
	[ "$sph" = " 2 4 6 8 10" ] && { [ "$spbx" = 80 ] || [ "$spbx" = 81 ]; } &&
	[ "$spby" = 15 ] && [ "$(rects "$spplot" 170 50)" = 1 ] &&
	[ "$sprb" = 1 ] && [ "$(rects "$spplot" 188 11)" = 1 ] &&
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
	[ "${npath_op:-1}" = 0 ] && ! grep -q LOGO-NOT-DRAWN "$sv" || fail "real-site layout regressions"

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
if [ "${GATE_SERIAL:-0}" = 1 ]; then bg_slow; else wait $SLOW_JOB || true; fi
S2="$OUT/slow"
bind_note "$S2"
[ "$(cat "$S2/rc" 2>/dev/null || echo 99)" = 0 ] || fail "slow autotest run (exit $(cat "$S2/rc" 2>/dev/null || echo none))"
same=0; bad=0
for f in "$R"/[01][0-9]-*.plot; do
	n=${f##*/}
	case "$n" in 07-PM-animation*) continue ;; esac
	# [01]* meant the bundled pages (01-19) until the network list ran
	# past page 99: 100-* and up are network pages this run never
	# loads (it has only NET-http-local). Patch 379: the gate's own
	# pages ran past 99 too (JS-popup became 100-), so the glob takes
	# two-digit pages only -- the 01-19 this run loads.
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

# Unit 403: every check passed. A fresh main autotest run made under
# GATE_REUSE_AUTOTEST=1 becomes the one cached run (the latest only).
if [ -n "$AFRESH" ]; then
	rm -rf "$AC"; mkdir -p "$AC"
	mv "$OUT/autotest-fresh" "$AC/$AKEY"
	: > "$AC/$AKEY/ok"
	echo "  autotest output cached for GATE_REUSE_AUTOTEST=1 (key $AKEY)"
fi
