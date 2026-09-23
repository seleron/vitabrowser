#!/bin/sh
# Build QuickJS-ng (tools/fetch-quickjs.sh) as a static library, for the
# host and for the Vita:
#
#   host  -> $WORK/host-quickjs/{include/quickjs,lib/libquickjs.a}
#   vita  -> $VITA_PREFIX/{include/quickjs,lib/libquickjs.a}  (vita-prefix)
#
# The four engine files, with the flags MacSurf's Linux harness uses
# (docs/phase-0/01 §5.3), minus AddressSanitizer: -D_GNU_SOURCE and
# -include pthread.h (cutils.h uses pthread types without including it).
# Userspace only.
#
# Usage: WORK=<WORK>/vitabrowser-work tools/build-quickjs.sh [host|vita|all]
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK="${WORK:-$HOME/vitabrowser-work}"
VITASDK="${VITASDK:-$HOME/vitasdk}"
VP="${VITA_PREFIX:-$WORK/vita-prefix}"
Q="$WORK/quickjs"
WHAT="${1:-all}"
WORK="$WORK" "$ROOT/tools/fetch-quickjs.sh" >/dev/null
SRCS="quickjs libregexp libunicode dtoa"

# build CC AR PREFIX EXTRA_CFLAGS
build() {
	obj="$3/obj-quickjs"
	rm -rf "$obj"; mkdir -p "$obj" "$3/lib" "$3/include/quickjs"
	for f in $SRCS; do
		$1 -c -O2 -g -D_GNU_SOURCE -include pthread.h $4 -I"$Q" \
			"$Q/$f.c" -o "$obj/$f.o" 2> "$obj/$f.log" || \
			{ echo "  $f.c FAILED:"; grep -m5 error "$obj/$f.log"; exit 1; }
	done
	rm -f "$3/lib/libquickjs.a"
	$2 rcs "$3/lib/libquickjs.a" "$obj"/*.o
	cp "$Q/quickjs.h" "$3/include/quickjs/"
	cp "$Q/LICENSE" "$3/include/quickjs/LICENSE-QuickJS"
	echo "  $3/lib/libquickjs.a ($(du -k "$3/lib/libquickjs.a" | cut -f1) KiB)"
}

if [ "$WHAT" = host ] || [ "$WHAT" = all ]; then
	echo "== QuickJS-ng, host =="
	build gcc ar "$WORK/host-quickjs" ""
fi
if [ "$WHAT" = vita ] || [ "$WHAT" = all ]; then
	echo "== QuickJS-ng, arm-vita-eabi =="
	build "$VITASDK/bin/arm-vita-eabi-gcc" "$VITASDK/bin/arm-vita-eabi-ar" \
		"$VP" ""
fi
