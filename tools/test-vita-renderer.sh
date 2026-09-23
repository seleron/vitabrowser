#!/bin/sh
# Host-side test of the Vita frontend renderer (patch 31, frontends/vita).
#
# Builds tools/test_vita_plotter.c against the patched tree -- the REAL
# monkey plot.c (patches 25-27) as the contract reference, the Vita
# frontend's plot_geom.c / plot.c / replay.c, and a logging stub of
# <vita2d.h> -- then runs it over the hand cases, a 200k-case seeded fuzz,
# and every recorded plot stream. See docs/phase-0/09-vita-frontend.md.
#
# Usage: WORK=<WORK>/vitabrowser-work tools/test-vita-renderer.sh
#        (after tools/build-patched.sh, or any apply of the stack)
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK="${WORK:-$HOME/vitabrowser-work}"
UP="$WORK/applytest/upstream"
NS="$UP/netsurf"
OUT="${OUT:-${TMPDIR:-/tmp}/test_vita_plotter}"

[ -f "$NS/frontends/vita/plot.c" ] || {
	echo "no $NS/frontends/vita -- apply the stack first (tools/build-patched.sh)"
	exit 2
}

# -I order matters: the stub vita2d.h must shadow any real one. The engine
# libraries are -isystem: MacSurf's patched libwapcaplet.h has unused locals.
INC="-I$ROOT/tools/vita-stub -I$NS -I$NS/include -I$NS/frontends \
-isystem $UP/libwapcaplet/include -isystem $UP/libcss/include \
-isystem $UP/libdom/include"

# Monkey's plot.c is the reference, not ours to lint: its own object, no -Werror.
gcc -std=c99 -D_DEFAULT_SOURCE -O1 -g -w $INC \
	-c "$ROOT/tools/test_vita_monkey_tu.c" -o "$OUT-monkey.o"
# The frontend sources are ours and must stay warning-clean.
gcc -std=c99 -D_DEFAULT_SOURCE -O1 -g -Wall -Wextra -Wno-unused-parameter \
	-Werror $INC -o "$OUT" \
	"$ROOT/tools/test_vita_plotter.c" \
	"$NS/frontends/vita/plot_geom.c" \
	"$NS/frontends/vita/plot.c" \
	"$NS/frontends/vita/replay.c" \
	"$OUT-monkey.o" -lm
"$OUT" "$ROOT"

# The text engine (frontends/vita/text.c): real FreeType, real fonts.
FONTS="$WORK/fonts"
[ -f "$FONTS/DejaVuSans.ttf" ] || WORK="$WORK" "$ROOT/tools/fetch-fonts.sh"
gcc -std=c99 -D_DEFAULT_SOURCE -O1 -g -Wall -Wextra -Wno-unused-parameter \
	-Werror $INC $(pkg-config --cflags freetype2) -o "$OUT-text" \
	"$ROOT/tools/test_vita_text.c" \
	"$NS/frontends/vita/text.c" $(pkg-config --libs freetype2)
"$OUT-text" "$FONTS"
