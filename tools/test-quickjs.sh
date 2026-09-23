#!/bin/sh
# Host test of the QuickJS engine probe (frontends/vita/jsprobe.c): the
# same checks the Vita autotest runs, here under AddressSanitizer and
# UndefinedBehaviorSanitizer -- ES2023 features, promise jobs, Unicode
# regexps, the memory cap and the runaway-script interrupt (README §14.7),
# and a fib(25) benchmark. Exits non-zero if any check fails.
#
# Usage: WORK=<WORK>/vitabrowser-work tools/test-quickjs.sh
#        (after an apply of the stack: needs frontends/vita/jsprobe.c)
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK="${WORK:-$HOME/vitabrowser-work}"
NS="$WORK/applytest/upstream/netsurf"
Q="$WORK/quickjs"
OUT="${OUT:-${TMPDIR:-/tmp}/test_quickjs}"
WORK="$WORK" "$ROOT/tools/fetch-quickjs.sh" >/dev/null
mkdir -p "$OUT.obj"
SAN="-fsanitize=address,undefined -fno-omit-frame-pointer"
# The engine: its own objects, not ours to lint.
for f in quickjs libregexp libunicode dtoa; do
	[ "$OUT.obj/$f.o" -nt "$Q/$f.c" ] || \
	gcc -c -O1 -g $SAN -D_GNU_SOURCE -include pthread.h -I"$Q" -w \
		"$Q/$f.c" -o "$OUT.obj/$f.o"
done
# The probe is ours: warning-clean.
gcc -std=c99 -D_DEFAULT_SOURCE -O1 -g $SAN -Wall -Wextra -Werror \
	-I"$Q" -I"$NS/frontends" -o "$OUT" \
	"$ROOT/tools/test_quickjs.c" "$NS/frontends/vita/jsprobe.c" \
	"$NS/frontends/vita/qjs_hooks.c" \
	"$OUT.obj"/*.o -lm -lpthread
ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 "$OUT"
