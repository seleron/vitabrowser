#!/bin/sh
# The gate's interaction-bearing simulator runs, against an ASan binary
# (tools/build-asan-sim.sh): the main autotest (every bundled + network page
# and the interaction pass), the scriptless form submissions, and the
# Vita's-pace autotest (its interaction pass at 40 ms/frame). Unit 398, doc 10.
#
# Usage: WORK=<WORK>/vitabrowser-work tools/asan-autotest.sh <asan-sim> <dir>
#        [main|forms|slow ...]   (default: all three)
# Needs a prior gate run (tools/run-vita-sim.sh): it reuses that run's app0:
# bundle, network page list (ports moved to 45480+) and TLS test certs.
# The form-submission script mirrors run-vita-sim.sh's "scriptless form
# submissions" block -- keep the two in step.
# Exit 1 on any ASan error, a crash, or a pass/fail count short of the gate's.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK="${WORK:-$HOME/vitabrowser-work}"
SIM=$(cd "$(dirname "${1:?usage: asan-autotest.sh <asan-sim> <dir> [main|forms|slow]}")" && pwd)/$(basename "$1")
D="${2:?usage: asan-autotest.sh <asan-sim> <dir>}"; shift 2
WHAT="${*:-main forms slow}"
OUT="$WORK/vita-sim"; T="$OUT/tls"; HP=45480
export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0:halt_on_error=1}"
[ -f "$OUT/run/ux0:data/VitaBrowser/nettest.txt" ] || { echo "no gate run in $OUT: run tools/run-vita-sim.sh first"; exit 1; }
mkdir -p "$D"; D=$(cd "$D" && pwd)
bad=0
asan_check() {	# $1 = stdout log
	if grep -q "ERROR: AddressSanitizer" "$1"; then
		grep -m1 "ERROR: AddressSanitizer" "$1" | sed 's/^/  /'
		grep -E "^ +#[0-9] " "$1" | head -6
		bad=1
	fi
}
httpd() {	# extra args
	python3 "$ROOT/tools/vita-sim/httpd.py" --dir "$ROOT/testpages/pages" "$@" > "$D/httpd.log" 2>&1 &
	H=$!; sleep 1
}
fresh() {	# $1 = run dir
	rm -rf "$1"; mkdir -p "$1/ux0:data/VitaBrowser" "$1/snaps"
	cp -r "$OUT/run/app0:" "$1/"
	: > "$1/ux0:download"
	echo off > "$1/ux0:data/VitaBrowser/netlog.cfg"
}
for w in $WHAT; do case "$w" in
main)
	M="$D/main"; fresh "$M"
	sed -e "s/:45280\//:$HP\//g" -e "s/:45281\//:$((HP+1))\//g" -e "s/:45282\//:$((HP+2))\//g" \
		"$OUT/run/ux0:data/VitaBrowser/nettest.txt" > "$M/ux0:data/VitaBrowser/nettest.txt"
	httpd --http "$HP" --https $((HP + 1)) "$T/leaf.pem" "$T/leaf.key" \
		--https-bad $((HP + 2)) "$T/rogue.pem" "$T/rogue.key"
	( cd "$M" && VITA_SIM_AUTOTEST=1 VITA_SIM_SNAP="$M/snaps" VITA_SETTLE_EXTRA_MS=7000 \
		VITA_SIM_REMOTE_PORT=45490 timeout 3600 "$SIM" > "$M/stdout.log" 2>&1 ); rc=$?
	kill $H 2>/dev/null
	asan_check "$M/stdout.log"
	isum=$(sed -n 's/.*interact: \([0-9]*\/[0-9]*\) passed.*/\1/p' "$M/ux0:data/VitaBrowser/log.txt" | tail -1)
	np=$(ls "$M/ux0:data/VitaBrowser/"*.plot 2>/dev/null | wc -l); ng=$(ls "$OUT/reference/"*.plot | wc -l)
	echo "main: rc $rc, interaction ${isum:-none}, $np page dumps (gate $ng)"
	[ "$rc" = 0 ] && [ -n "$isum" ] && [ "${isum%/*}" = "${isum#*/}" ] && [ "$np" -ge "$ng" ] || bad=1 ;;
forms)
	FS="$D/forms"; fresh "$FS"
	FU="$FS/q\"uote é.dat"; printf 'upload line 1\r\nline 2\n\000\001\376\377 end' > "$FU"
	FB="http://127.0.0.1:$HP"
	printf 'settle 3000\ntap 160 65\nsettle 3000\nnav %s/HTML-multipart-form.html\nsettle 3000\ntap 160 135\nsettle 3000\nnav %s/HTML-multipart-1252.html\nsettle 3000\ntap 160 65\nsettle 3000\nnav %s/HTML-multipart-upload.html\nsettle 3000\ntap 160 65\nsettle 1500\ntap 160 135\nsettle 3000\n' "$FB" "$FB" "$FB" > "$FS/script.txt"
	for c in img imgnoname nosub submit button values; do
		printf 'nav %s/JS-form-submitters.html?%s\nsettle 3000\n' "$FB" "$c" >> "$FS/script.txt"
	done
	printf 'nav %s/JS-form-target.html?tap\nsettle 3000\ntap 160 65\nsettle 2000\ntap 160 135\nsettle 3000\nquit\n' "$FB" >> "$FS/script.txt"
	httpd --http "$HP"
	( cd "$FS" && VITA_SIM_UPLOAD="$FU" VITA_SIM_SCRIPT="$FS/script.txt" VITA_SIM_OUT="$FS" \
		VITA_SIM_REMOTE_PORT=45590 timeout 900 "$SIM" "$FB/HTML-multipart-form.html" > "$FS/stdout.log" 2>&1 ); rc=$?
	kill $H 2>/dev/null
	asan_check "$FS/stdout.log"
	fgot=$(sed -n 's/.*gw title: \(FORMCHECK .*\)/\1/p' "$FS/ux0:data/VitaBrowser/log.txt" | uniq); ok=0
	for f in "multipart ok fcd2da030618" "urlencoded ok 7e9ed1917f53" "w1252 ok 01804f0f31bf" \
		 "upload ok a866dd8b3405" "img ok f147644a4326" "imgnoname ok 9663aca848e0" \
		 "nosub ok 22de21b23e38" "submit ok 22de21b23e38" "button ok 0ded7fa40b3c" "values ok 6c222d589e0b"; do
		set -- $f
		[ "$(printf '%s\n' "$fgot" | grep "^FORMCHECK $1 " | tail -1)" = "FORMCHECK $f" ] && ok=$((ok + 1))
	done
	ftap=$(sed -n 's/.*gw title: \(FORMTARGET tap .*\)/\1/p' "$FS/ux0:data/VitaBrowser/log.txt" | tail -1)
	echo "forms: rc $rc, $ok/10 submissions as Chromium, target '${ftap:-none}'"
	[ "$rc" = 0 ] && [ "$ok" = 10 ] && [ "$ftap" = "FORMTARGET tap tapped,link" ] || bad=1 ;;
slow)
	S2="$D/slow"; fresh "$S2"
	echo "NET-http-local http://127.0.0.1:$HP/L1-layout-basics.html" > "$S2/ux0:data/VitaBrowser/nettest.txt"
	httpd --http "$HP"
	( cd "$S2" && VITA_SIM_SLOW_MS=40 VITA_SIM_TEXT_UNBATCHED=1 VITA_SIM_AUTOTEST=1 \
		VITA_SIM_SNAP="$S2/snaps" VITA_SIM_REMOTE_PORT=45591 timeout 3600 "$SIM" > "$S2/stdout.log" 2>&1 ); rc=$?
	kill $H 2>/dev/null
	asan_check "$S2/stdout.log"
	isum=$(sed -n 's/.*interact: \([0-9]*\/[0-9]*\) passed.*/\1/p' "$S2/ux0:data/VitaBrowser/log.txt" | tail -1)
	jw=$(grep -c 'JS-window row 7 passed' "$S2/ux0:data/VitaBrowser/netsurf.log")
	echo "slow: rc $rc, interaction ${isum:-none}, JS-window $jw of 4"
	[ "$rc" = 0 ] && [ -n "$isum" ] && [ "${isum%/*}" = "${isum#*/}" ] && [ "$jw" -ge 4 ] || bad=1 ;;
*) echo "unknown run '$w' (main|forms|slow)"; exit 2 ;;
esac; done
[ "$bad" = 0 ] && echo "ASan autotest: clean" || echo "ASan autotest: FAILED"
exit $bad
