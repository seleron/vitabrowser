#!/bin/sh
# Regenerate the MacSurf-vs-upstream-NetSurf patch set (brief §14.4).
#
# MacSurf's five core libs are at the SAME COMPONENT_VERSION as upstream
# (verified 2026-09-20), so a plain recursive diff isolates exactly MacSurf's
# changes with no version drift mixed in.
#
# Upstream test suites are excluded: we do not port them, and libdom's tests
# alone account for 644 of its 935 changed files.
#
# Usage: WORK=<WORK>/vitabrowser-work tools/regen-patches.sh
set -e
WORK="${WORK:-$HOME/vitabrowser-work}"
UPSTREAM="$WORK/upstream"
MACSURF="$WORK/browser"
OUT="${OUT:-$WORK/patches}"

[ -d "$UPSTREAM" ] || { echo "no $UPSTREAM -- clone upstream first (see docs/phase-0/02-upstream-pivot.md)"; exit 1; }
[ -d "$MACSURF" ]  || { echo "no $MACSURF -- copy MacSurf's browser/ tree there"; exit 1; }

mkdir -p "$OUT"
printf '%-16s %8s %7s %s\n' LIBRARY LINES FILES "NEW macsurf_* FILES"
for l in libwapcaplet libparserutils libhubbub libcss libdom; do
	# Run from $WORK with relative operands so the diff headers carry
	# "upstream/<lib>/..." and "browser/<lib>/..." rather than absolute paths.
	# Patches are then portable and apply with -p2 inside a library tree.
	( cd "$WORK" && diff -urN \
		-x '.git' -x 'build-*' -x 'test' \
		-x '*.o' -x '*.a' -x '*.d' -x '*.pc' \
		"upstream/$l" "browser/$l" ) > "$OUT/$l.patch" 2>/dev/null || true
	lines=$(wc -l < "$OUT/$l.patch")
	files=$(grep -c '^diff ' "$OUT/$l.patch" || true)
	newf=$(grep '^diff ' "$OUT/$l.patch" | awk '{print $NF}' | grep -c macsurf || true)
	printf '%-16s %8s %7s %s\n' "$l" "$lines" "$files" "$newf"
done
echo
echo "total: $(cat "$OUT"/*.patch | wc -l) lines in $OUT"
