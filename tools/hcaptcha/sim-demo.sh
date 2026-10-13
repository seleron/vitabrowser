#!/bin/sh
# hCaptcha's public demo in the simulator: tap the checkbox, report what
# getcaptcha answered (the refusal is ~0.8 KB of JSON, a challenge ~2.4 KB).
# Usage: WORK=<WORK>/vitabrowser-work tools/hcaptcha/sim-demo.sh OUTDIR [ua]
#   ua: a useragent.txt preset (chrome, firefox, safari, vita) or a string
set -e
D=$1; WORK="${WORK:-$HOME/vitabrowser-work}"
rm -rf "$D"; mkdir -p "$D/ux0:data/VitaBrowser" "$D/shots"
cp -r "$WORK/vita-sim/run/app0:" "$D/"
echo off > "$D/ux0:data/VitaBrowser/netlog.cfg"
[ -n "$2" ] && echo "$2" > "$D/ux0:data/VitaBrowser/useragent.txt"
# the checkbox sits at (62, 262) at 960x544 (the 20 px title bar included)
printf 'settle 12000\nshot before\ntap 62 262\nsettle 45000\nshot after\nquit\n' > "$D/script.txt"
cd "$D" && VITA_SIM_SCRIPT="$D/script.txt" VITA_SIM_OUT="$D/shots" \
	VITA_SIM_REMOTE_PORT=${PORT:-45391} timeout 400 \
	"$WORK/applytest/upstream/netsurf/nsvita-sim" https://accounts.hcaptcha.com/demo > out.log 2>&1 || true
L="$D/ux0:data/VitaBrowser/netsurf.log"
echo "getcaptcha sent $(grep -a 'xhr send.*getcaptcha' "$L" | grep -o 'bytes=[0-9]*' | tr '\n' ' ')answer $(grep -a 'xhr deliver.*getcaptcha' "$L" | grep -o 'bytes=[0-9]*' | tr '\n' ' ')"
