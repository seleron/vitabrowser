#!/bin/sh
# Real websites, end to end, in the simulator (docs/phase-0/11).
#
# Opens each site below in nsvita-sim -- the Vita frontend and engine, the
# Vita's curl + mbedTLS, DNS on the resolver's worker thread, QuickJS and
# MacSurf's bridge -- over the live network, and reports for each: when the
# document arrived, its extent once loaded, its title, blocked hosts, peak memory (host
# RSS: a 64-bit process, so an upper bound for the Vita's 32-bit one), and a
# screenshot in $OUT/live/<name>/shots/page-00.png once it settled.
#
# Fails if a page never gets a document, or has no title.
# Needs the internet, so it is not part of tools/run-vita-sim.sh; run that
# first (it builds nsvita-sim and the app0: bundle this reuses).
#
# Usage: WORK=<WORK>/vitabrowser-work tools/run-live-sites.sh [name url ...]
set -e
WORK="${WORK:-$HOME/vitabrowser-work}"
NS="$WORK/applytest/upstream/netsurf"
OUT="${OUT:-$WORK/vita-sim}"
# A live page draws nothing while it loads: each gets this long before the
# simulator may call it settled (tools/vita-sim VITA_SIM_MIN_MS).
MIN_MS="${MIN_MS:-15000}"

[ -x "$NS/nsvita-sim" ] && [ -d "$OUT/run/app0:" ] || \
	{ echo "run tools/run-vita-sim.sh first"; exit 2; }

if [ $# -eq 0 ]; then
	set -- \
	  example-http http://example.com/ \
	  wikipedia-article https://en.m.wikipedia.org/wiki/PlayStation_Vita \
	  wikipedia-main https://en.wikipedia.org/wiki/Main_Page \
	  hacker-news https://news.ycombinator.com/ \
	  cnn-lite https://lite.cnn.com/ \
	  ddg-search "https://lite.duckduckgo.com/lite/?q=playstation+vita"
fi

bad=0
printf '%-18s %6s %11s %5s %7s  %s\n' SITE DOC_MS EXTENT BLOCK RSS_MB TITLE
while [ $# -ge 2 ]; do
	name=$1 url=$2
	shift 2
	D="$OUT/live/$name"
	rm -rf "$D"
	mkdir -p "$D/ux0:data/VitaBrowser" "$D/shots"
	cp -r "$OUT/run/app0:" "$D/"
	echo off > "$D/ux0:data/VitaBrowser/netlog.cfg"
	( cd "$D" && VITA_SIM_MIN_MS="$MIN_MS" VITA_SIM_REMOTE_PORT=45181 \
		VITA_SIM_OUT="$D/shots" VITA_SIM_PAGES=1 \
		timeout 180 /usr/bin/time -v "$NS/nsvita-sim" "$url" \
		> "$D/out.log" 2>&1 ) || true
	L="$D/ux0:data/VitaBrowser/log.txt"
	doc=$(sed -n 's/.*: document after \([0-9]*\) ms (extent \([0-9x]*\)).*/\1 \2/p' "$L" | tail -1)
	# The extent once loaded (at "document after" it is mid-layout).
	fin=$(sed -n 's/.*: loaded, extent \([0-9x]*\).*/\1/p' "$L" | tail -1)
	[ -n "$fin" ] && [ -n "$doc" ] && doc="${doc%% *} $fin"
	title=$(sed -n 's/.*gw title: //p' "$L" | tail -1)
	blocked=$(grep -c 'blocked: ' "$D/ux0:data/VitaBrowser/netsurf.log" || true)
	rss=$(sed -n 's/.*Maximum resident set size (kbytes): \([0-9]*\)/\1/p' "$D/out.log")
	printf '%-18s %6s %11s %5s %7s  %s\n' "$name" "${doc%% *}" \
		"${doc#* }" "$blocked" "$(( ${rss:-0} / 1024 ))" "${title:-(none)}"
	if [ -z "$doc" ] || [ -z "$title" ]; then
		bad=$((bad + 1))
		echo "  FAILED: no document or no title; see $L"
	fi
done
[ "$bad" -eq 0 ]
