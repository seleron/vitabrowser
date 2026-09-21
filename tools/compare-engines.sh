#!/bin/sh
# Render every probe page with two engines and diff the plot streams.
#
# The point: testpages/golden/*.plot were captured with pristine upstream
# NetSurf. Re-capturing them with MacSurf's patch stack applied turns "MacSurf
# has CSS fixes" into a measured, page-by-page statement -- which plot calls
# move, and how far.
#
# Usage:
#   UPSTREAM_MONKEY=<WORK>/vitabrowser-work/upstream/netsurf/nsmonkey \
#   PATCHED_MONKEY=<WORK>/vitabrowser-work/applytest/netsurf/nsmonkey \
#   tools/compare-engines.sh
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
UPSTREAM_MONKEY="${UPSTREAM_MONKEY:-$HOME/vitabrowser-work/upstream/netsurf/nsmonkey}"
PATCHED_MONKEY="${PATCHED_MONKEY:-$HOME/vitabrowser-work/applytest/netsurf/nsmonkey}"
OUT="${OUT:-$HOME/vitabrowser-work/engine-compare}"

[ -x "$PATCHED_MONKEY" ] || { echo "no patched nsmonkey at $PATCHED_MONKEY"; exit 2; }
mkdir -p "$OUT"

differs=0; same=0
for page in "$ROOT"/testpages/pages/*.html; do
	name=$(basename "$page" .html)
	gold="$ROOT/testpages/golden/$name.plot"
	[ -f "$gold" ] || continue
	python3 "$ROOT/tools/plotstream.py" --monkey "$PATCHED_MONKEY" \
		--url "file://$page" --load-wait 6 --out "$OUT/$name.patched.plot" 2>/dev/null
	if diff -u "$gold" "$OUT/$name.patched.plot" > "$OUT/$name.diff" 2>&1; then
		echo "SAME  $name"
		same=$((same + 1))
	else
		ops_gold=$(grep -c '^PLOT' "$gold" || true)
		ops_new=$(grep -c '^PLOT' "$OUT/$name.patched.plot" || true)
		changed=$(grep -cE '^[+-]PLOT' "$OUT/$name.diff" || true)
		echo "DIFFER $name  (plot ops $ops_gold -> $ops_new, $changed changed lines)"
		differs=$((differs + 1))
	fi
done

echo
echo "same: $same   differ: $differs   diffs in $OUT"
