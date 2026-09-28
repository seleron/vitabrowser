#!/bin/sh
# Re-capture every probe page and diff against its committed golden plotstream.
#
# A failure prints the changed plot operations -- which box moved, which text
# reflowed -- instead of a pixel count. See docs/phase-0/03-golden-plotstream.md
#
# Usage: MONKEY=<WORK>/vitabrowser-work/upstream/netsurf/nsmonkey tools/check-goldens.sh
set -e
MONKEY="${MONKEY:-$HOME/vitabrowser-work/upstream/netsurf/nsmonkey}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PAGES="$ROOT/testpages/pages"
GOLDEN="$ROOT/testpages/golden"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

[ -x "$MONKEY" ] || { echo "no nsmonkey at $MONKEY -- set MONKEY="; exit 2; }

fail=0
for page in "$PAGES"/*.html; do
	name=$(basename "$page" .html)
	gold="$GOLDEN/$name.plot"
	[ -f "$gold" ] || { echo "SKIP $name (no golden -- create with tools/plotstream.py)"; continue; }
	python3 "$ROOT/tools/plotstream.py" --monkey "$MONKEY" \
		--url "file://$page" --load-wait 6 --out "$TMP/$name.plot" 2>/dev/null
	# Skip the header's URL line: it embeds the checkout's absolute path,
	# so it differs on every machine. The op-count line below it is still
	# compared.
	tail -n +2 "$gold" > "$TMP/$name.gold"
	tail -n +2 "$TMP/$name.plot" > "$TMP/$name.cap"
	if diff -u "$TMP/$name.gold" "$TMP/$name.cap" > "$TMP/$name.diff"; then
		echo "PASS $name"
	else
		echo "FAIL $name"
		sed 's/^/      /' "$TMP/$name.diff" | head -40
		fail=1
	fi
done

# Network-backed goldens are checked separately: they can change under us.
if [ "${INCLUDE_NETWORK:-0}" = "1" ]; then
	for gold in "$GOLDEN"/*-com.plot "$GOLDEN"/*-net.plot; do
		[ -f "$gold" ] || continue
		url=$(sed -n '1s/^# plotstream \([^ ]*\) .*/\1/p' "$gold")
		name=$(basename "$gold" .plot)
		python3 "$ROOT/tools/plotstream.py" --monkey "$MONKEY" \
			--url "$url" --out "$TMP/$name.plot" 2>/dev/null
		if diff -u "$gold" "$TMP/$name.plot" > "$TMP/$name.diff"; then
			echo "PASS $name (network)"
		else
			echo "FAIL $name (network -- may be an upstream page change)"
			sed 's/^/      /' "$TMP/$name.diff" | head -20
			fail=1
		fi
	done
fi

exit $fail
