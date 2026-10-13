#!/bin/sh
# Patch 254's WebAssembly (quickjs/macsurf_wasm.c + wasm3) under ASan +
# UBSan: the real glue, wasm3 and QuickJS-ng; the frontend's hooks stubbed
# (tools/wasm-fuzz/harness.c). It evaluates the WebAssembly part of
# vita_polyfill.js, then tools/wasm-fuzz/test.js: the gate page's checks
# without a DOM, 200 instances whose buffers, functions, tables and
# memories outlive them through collections, a call stopped from a slice,
# and 3000 mutated modules called with hostile arguments. The modules are
# tools/wasm-fuzz/*.wat (WABT 1.0.42's wat2wasm, REA_WABT_BIN_DIRECTORY or
# WABT=<dir>), the same ones testpages/pages/JS-wasm.html embeds.
#
# UBSan's alignment check is off: wasm3 keeps values in 4-byte slots
# (d_m3Use32BitSlots), so an i64 slot is 4-byte aligned -- C's rule, not
# the hardware's (ARMv7's LDRD needs word alignment only).
#
# Usage: WORK=<WORK>/vitabrowser-work tools/test-wasm.sh [seeds...]
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK="${WORK:-$HOME/vitabrowser-work}"
NS="$WORK/applytest/upstream/netsurf"
Q="$NS/content/handlers/javascript/quickjs"
QJ="$WORK/host-quickjs"
WABT="${WABT:-${REA_WABT_BIN_DIRECTORY:-$HOME/opt/wabt-1.0.42/bin}}"
OUT="${OUT:-$WORK/wasm-fuzz}"
[ -f "$Q/macsurf_wasm.c" ] || { echo "no $Q/macsurf_wasm.c (patch 254 not staged)"; exit 2; }
[ -x "$WABT/wat2wasm" ] || { echo "no $WABT/wat2wasm (WABT 1.0.42)"; exit 2; }
WORK="$WORK" "$ROOT/tools/fetch-wasm3.sh" >/dev/null
[ -f "$QJ/lib/libquickjs.a" ] || WORK="$WORK" "$ROOT/tools/build-quickjs.sh" host
W="$WORK/wasm3/source"
SAN="-g -O1 -fsanitize=address,undefined -fno-sanitize=alignment -fno-sanitize-recover=all -fno-omit-frame-pointer"
rm -rf "$OUT"; mkdir -p "$OUT/obj"
for f in m3_bind m3_code m3_compile m3_core m3_emit m3_env m3_exec m3_function \
	 m3_info m3_module m3_optimize m3_parse; do
	gcc $SAN -O2 -fwrapv -std=gnu11 -Wno-unused-function -I"$W" -c "$W/$f.c" -o "$OUT/obj/$f.o"
done
gcc $SAN -DWITH_QUICKJS -D_GNU_SOURCE -I"$Q" -I"$NS" -I"$NS/include" -I"$W" \
	-I"$QJ/include/quickjs" -I"$ROOT/compat" -include macsurf_core_decls.h \
	-c "$Q/macsurf_wasm.c" -o "$OUT/obj/macsurf_wasm.o"
gcc $SAN -DWITH_QUICKJS -I"$Q" -I"$QJ/include/quickjs" \
	-c "$ROOT/tools/wasm-fuzz/harness.c" -o "$OUT/obj/harness.o"
gcc $SAN -no-pie "$OUT"/obj/*.o "$QJ/lib/libquickjs.a" -lm -lpthread -o "$OUT/harness"
# the polyfill's WebAssembly section, with what it expects around it
{ echo 'var g = globalThis;'
  echo 'function define(o, n, v) { Object.defineProperty(o, n, { value: v, writable: true, configurable: true, enumerable: false }); }'
  # the polyfill's private per-object record (patch 276)
  echo 'var PRIV = { pv: new WeakMap() };'
  echo 'function PV(o) { if (o === null || (typeof o !== "object" && typeof o !== "function")) return {}; var r = PRIV.pv.get(o); if (!r) { r = {}; PRIV.pv.set(o, r); } return r; }'
  sed -n '/^\/\* ---- WebAssembly ----/,/^\/\* ---- canvas 2D: a real drawing context/p' "$Q/vita_polyfill.js" | sed '$d'
} > "$OUT/poly.js"
for m in basic imports memimport; do
	"$WABT/wat2wasm" "$ROOT/tools/wasm-fuzz/$m.wat" -o "$OUT/$m.wasm"
	echo "var W_$m = '$(base64 -w0 "$OUT/$m.wasm")';"
done > "$OUT/modules.js"
bad=0
for seed in ${*:-1 7 42 99 1234 31337}; do
	{ cat "$OUT/modules.js"; sed "s/var seed = SEED;/var seed = $seed;/" "$ROOT/tools/wasm-fuzz/test.js"; } > "$OUT/t$seed.js"
	r=$("$OUT/harness" "$OUT/poly.js" "$OUT/t$seed.js" 2>&1 | tail -2 | tr '\n' ' ')
	echo "  seed $seed: $r"
	case "$r" in *"fails 0 "*) ;; *) bad=$((bad + 1)) ;; esac
done
{ cat "$OUT/modules.js"; echo 'var STOP = true;'; sed "s/var seed = SEED;/var seed = 5;/" "$ROOT/tools/wasm-fuzz/test.js"; } > "$OUT/tstop.js"
r=$(STOP_AT=3 "$OUT/harness" "$OUT/poly.js" "$OUT/tstop.js" 2>&1 | tail -2 | tr '\n' ' ')
echo "  stopped from a slice: $r"
case "$r" in *"fails 0 "*) ;; *) bad=$((bad + 1)) ;; esac
[ "$bad" -eq 0 ] && echo "wasm: ASan + UBSan clean" || { echo "wasm: $bad run(s) FAILED"; exit 1; }
