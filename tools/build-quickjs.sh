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
WORK="$WORK" "$ROOT/tools/fetch-wasm3.sh" >/dev/null
SRCS="quickjs libregexp libunicode dtoa"
# wasm3 (tools/fetch-wasm3.sh), WebAssembly for the bridge (macsurf_wasm.c):
# its interpreter core only -- no WASI, libc or tracer bindings. -O3: the
# interpreter is a chain of tail calls, and wasm3 is written for an
# optimising build. -fwrapv: wasm3 does i32/i64 arithmetic in signed C
# types and relies on overflow wrapping, as WebAssembly does; C leaves it
# undefined, and an optimiser may assume it away (UBSan, patch 254). It
# lands beside libquickjs (lib/libm3.a,
# include/wasm3/), so the frontend links both from one prefix.
W="$WORK/wasm3/source"
M3SRCS="m3_bind m3_code m3_compile m3_core m3_emit m3_env m3_exec m3_function
m3_info m3_module m3_optimize m3_parse"

# build_m3 CC AR PREFIX
build_m3() {
	obj="$3/obj-wasm3"
	rm -rf "$obj" "$3/include/wasm3"; mkdir -p "$obj" "$3/lib" "$3/include/wasm3"
	for f in $M3SRCS; do
		$1 -c -O3 -g -std=gnu11 -fwrapv -Wno-unused-function -I"$W" \
			"$W/$f.c" -o "$obj/$f.o" 2> "$obj/$f.log" || \
			{ echo "  wasm3 $f.c FAILED:"; grep -m5 error "$obj/$f.log"; exit 1; }
	done
	rm -f "$3/lib/libm3.a"
	$2 rcs "$3/lib/libm3.a" "$obj"/*.o
	cp "$W"/*.h "$3/include/wasm3/"
	cp "$WORK/wasm3/LICENSE" "$3/include/wasm3/LICENSE-wasm3"
	echo "  $3/lib/libm3.a ($(du -k "$3/lib/libm3.a" | cut -f1) KiB)"
}

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
	build_m3 gcc ar "$WORK/host-quickjs"
fi
if [ "$WHAT" = vita ] || [ "$WHAT" = all ]; then
	echo "== QuickJS-ng, arm-vita-eabi =="
	build "$VITASDK/bin/arm-vita-eabi-gcc" "$VITASDK/bin/arm-vita-eabi-ar" \
		"$VP" ""
	build_m3 "$VITASDK/bin/arm-vita-eabi-gcc" "$VITASDK/bin/arm-vita-eabi-ar" "$VP"
fi
