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
# Drop the runtime compat object into libcss and list it, so the two MacSurf
# helpers that ported code still calls have definitions at link time. Several
# callers declare them with a nested extern instead of including a header, so
# they cannot be macro'd away -- see compat/macsurf_compat.c.
if [ -d "$WORK/upstream/libcss/src/utils" ] && [ -z "$DRY" ]; then
	cp "$ROOT/compat/macsurf_compat.c" "$WORK/upstream/libcss/src/utils/"
	mk="$WORK/upstream/libcss/src/utils/Makefile"
	if [ -f "$mk" ] && ! grep -q macsurf_compat "$mk"; then
		sed -i 's/^\(DIR_SOURCES := .*\)$/\1 macsurf_compat.c/' "$mk"
	fi
fi

# Our own port fixes, applied after the generated MacSurf stack. Named
# NN-<lib>-<what>.patch and routed to <lib> by that middle field. These use
# a/ b/ prefixes, so -p1.
for p in "$ROOT"/patches/vitabrowser/*.patch; do
	[ -f "$p" ] || continue
	base=$(basename "$p" .patch)
	lib=$(echo "$base" | cut -d- -f2)
	tree="$WORK/upstream/$lib"
	[ -d "$tree" ] || { echo "SKIP $base (no $lib tree)"; continue; }
	if patch $DRY -p1 -d "$tree" --forward --no-backup-if-mismatch \
	         -i "$p" > /tmp/patchlog.$$ 2>&1; then
		ok=$((ok + 1))
	else
		bad=$((bad + 1))
		echo "FAIL vitabrowser/$base"
		sed 's/^/      /' /tmp/patchlog.$$ | head -6
	fi
	rm -f /tmp/patchlog.$$
done

echo
echo "applied: $ok   failed: $bad"
[ "$bad" -eq 0 ]
