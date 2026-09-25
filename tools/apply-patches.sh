#!/bin/sh
# Apply the MacSurf patch stack to a clean upstream NetSurf checkout and report.
#
# This is the test that the stack is real: every patch must apply to pristine
# upstream, in manifest order, with no fuzz.
#
# Usage: WORK=<WORK>/vitabrowser-work/applytest tools/apply-patches.sh [--dry-run]
# (normally run by tools/build-patched.sh, which stages $WORK/applytest).
#
# WORK is the directory whose upstream/<lib> trees get PATCHED. It must never
# be <WORK>/vitabrowser-work itself: those upstream trees are the pristine source
# that tools/split-patches.py diffs MacSurf against, and that build-patched.sh
# copies for staging. On 2026-09-25 22:05 this script ran with the old default
# (WORK=<WORK>/vitabrowser-work) and patched them in place; the next regeneration
# produced a gutted stack and the staged builds were unreliable (doc 11 §37).
set -e
WORK="${WORK:-$HOME/vitabrowser-work/applytest}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
case "$(cd "$WORK" 2>/dev/null && pwd)" in
"$(cd "$HOME/vitabrowser-work" 2>/dev/null && pwd)")
	if [ "${ALLOW_PRISTINE_PATCH:-}" != 1 ]; then
		echo "apply-patches.sh: refusing to patch the pristine trees in" \
		     "$WORK/upstream (use WORK=$WORK/applytest, or" \
		     "ALLOW_PRISTINE_PATCH=1 if you really mean it)" >&2
		exit 2
	fi
	;;
esac
DRY=""
[ "$1" = "--dry-run" ] && DRY="--dry-run"

ok=0; bad=0
# Apply one patch: prefer git apply (exact, reliable offset search), fall
# back to GNU patch (needed for --forward "already applied" skip semantics).
# GNU patch fails on some git-generated offsets (e.g. "succeeded at 1306
# (offset 1 line)" that git apply finds fine) — observed 2026-09-21 on
# netsurf/04 hunk #3 and libwapcaplet/02 hunk #3.
apply_patch() {
	# $1=tree  $2=strip  $3=patchfile
	if git -C "$1" apply ${DRY:+--check} "$2" "$3" 2>/dev/null; then
		return 0
	fi
	if patch $DRY "$2" -d "$1" --forward --no-backup-if-mismatch \
	         -i "$3" 2>&1; then
		return 0
	fi
	return 1
}
for lib in libwapcaplet libparserutils libhubbub libcss libdom netsurf; do
	dir="$ROOT/patches/$lib"
	[ -d "$dir" ] || continue
	tree="$WORK/upstream/$lib"
	[ -d "$tree" ] || { echo "missing tree: $tree"; exit 2; }
	for p in "$dir"/*.patch; do
		[ -f "$p" ] || continue
		name="$lib/$(basename "$p")"
		# -p2 strips the leading "upstream/<lib>/" that regen-patches.sh emits
		if apply_patch "$tree" -p2 "$p" > /tmp/patchlog.$$ 2>&1; then
			ok=$((ok + 1))
		else
			bad=$((bad + 1))
			echo "FAIL $name"
			sed 's/^/      /' /tmp/patchlog.$$ | head -6
		fi
		rm -f /tmp/patchlog.$$
	done
done
# Drop the runtime compat object into BOTH libcss and libdom, and list it.
# Static archives are searched in link order, so a definition only in libcss is
# already past when libdom's references come up. The symbols are weak, so
# carrying it twice is not a duplicate-definition error. See
# compat/macsurf_compat.c.
if [ -z "$DRY" ]; then
	for lib in libcss libdom; do
		dst="$WORK/upstream/$lib/src/utils"
		[ -d "$dst" ] || continue
		cp "$ROOT/compat/macsurf_compat.c" "$dst/"
		mk="$dst/Makefile"
		if [ -f "$mk" ] && ! grep -q macsurf_compat "$mk"; then
			sed -i 's/^\(DIR_SOURCES := .*\)$/\1 macsurf_compat.c/' "$mk"
		fi
	done
fi

# Our own port fixes, applied after the generated MacSurf stack. Named
# NN-<lib>-<what>.patch and routed to <lib> by that middle field. These use
# a/ b/ prefixes, so -p1.
# Numeric order: the glob sorts 100-* between 10-* and 11-*, which applied
# patch 100 before the patches it builds on. (No spaces in these paths.)
for p in $(ls "$ROOT"/patches/vitabrowser/*.patch | sort -V); do
	[ -f "$p" ] || continue
	base=$(basename "$p" .patch)
	lib=$(echo "$base" | cut -d- -f2)
	tree="$WORK/upstream/$lib"
	[ -d "$tree" ] || { echo "SKIP $base (no $lib tree)"; continue; }
	if apply_patch "$tree" -p1 "$p" > /tmp/patchlog.$$ 2>&1; then
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
