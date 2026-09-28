#!/bin/sh
# Re-capture the patched-engine probe streams and diff against the fixtures.
#
# testpages/golden/ is the PRISTINE engine's output (tools/check-goldens.sh);
# testpages/patched-streams/ is the PATCHED engine's, for the probe pages
# whose plotters the stack adds (gradient, shadow, animation, shadow clip).
# tools/test-vita-renderer.sh asserts properties of these fixtures (replay,
# and the patch-32 ink clip), so they must track the live engine: this
# script fails when they drift. UPDATE=1 rewrites them instead.
#
# Usage: MONKEY=<WORK>/vitabrowser-work/applytest/upstream/netsurf/nsmonkey \
#        tools/check-patched-streams.sh
set -e
MONKEY="${MONKEY:-$HOME/vitabrowser-work/applytest/upstream/netsurf/nsmonkey}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PAGES="$ROOT/testpages/pages"
FIX="$ROOT/testpages/patched-streams"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

[ -x "$MONKEY" ] || { echo "no patched nsmonkey at $MONKEY -- run tools/build-patched.sh"; exit 2; }

fail=0
for fix in "$FIX"/*.plot; do
	name=$(basename "$fix" .plot)
	python3 "$ROOT/tools/plotstream.py" --monkey "$MONKEY" \
		--url "file://$PAGES/$name.html" --load-wait 6 --out "$TMP/$name.plot" 2>/dev/null
	# Normalize the machine-specific source-path header (first line:
	# "# plotstream file:///abs/path/...") before diffing, so the check
	# compares plot ops, not checkout locations.
	sed '1s|^# plotstream file://.*|# plotstream|' "$fix" > "$TMP/$name.fix.norm"
	sed '1s|^# plotstream file://.*|# plotstream|' "$TMP/$name.plot" > "$TMP/$name.new.norm"
	if [ -n "$UPDATE" ]; then
		cp "$TMP/$name.plot" "$fix"
		echo "UPDATED $name"
	elif diff -u "$TMP/$name.fix.norm" "$TMP/$name.new.norm" > "$TMP/$name.diff"; then
		echo "PASS $name"
	else
		echo "FAIL $name"
		sed 's/^/      /' "$TMP/$name.diff" | head -40
		fail=1
	fi
done
exit $fail
