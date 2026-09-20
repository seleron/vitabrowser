#!/bin/sh
# Apply the MacSurf patch stack to a clean upstream NetSurf checkout and report.
#
# This is the test that the stack is real: every patch must apply to pristine
# upstream, in manifest order, with no fuzz.
#
# Usage: WORK=<WORK>/vitabrowser-work tools/apply-patches.sh [--dry-run]
set -e
WORK="${WORK:-$HOME/vitabrowser-work}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DRY=""
[ "$1" = "--dry-run" ] && DRY="--dry-run"

ok=0; bad=0
for lib in libwapcaplet libparserutils libhubbub libcss libdom; do
	dir="$ROOT/patches/$lib"
	[ -d "$dir" ] || continue
	tree="$WORK/upstream/$lib"
	[ -d "$tree" ] || { echo "missing tree: $tree"; exit 2; }
	for p in "$dir"/*.patch; do
		[ -f "$p" ] || continue
		name="$lib/$(basename "$p")"
		# -p2 strips the leading "upstream/<lib>/" that regen-patches.sh emits
		if patch $DRY -p2 -d "$tree" --forward --no-backup-if-mismatch \
		         -i "$p" > /tmp/patchlog.$$ 2>&1; then
			ok=$((ok + 1))
		else
			bad=$((bad + 1))
			echo "FAIL $name"
			sed 's/^/      /' /tmp/patchlog.$$ | head -6
		fi
		rm -f /tmp/patchlog.$$
	done
done
echo
echo "applied: $ok   failed: $bad"
[ "$bad" -eq 0 ]
