#!/bin/sh
# Replay an hsw recording (chrome-demo.py --record: a full one, with memory
# writes) through V8 (node) and through the engine's own WebAssembly --
# wasm3 behind vita_polyfill.js, under ASan + UBSan, in tools/test-wasm.sh's
# harness. Both must print "IDENTICAL": the module then computed, from the
# same inputs, exactly what it computed in Chromium.
# Usage: WORK=<WORK>/vitabrowser-work tools/hcaptcha/replay.sh REC
set -e
H=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$H/../.." && pwd)
WORK="${WORK:-$HOME/vitabrowser-work}"
REC=$1; W="$WORK/wasm-fuzz"
[ -x "$W/harness" ] && [ -f "$W/poly.js" ] || WORK="$WORK" "$ROOT/tools/test-wasm.sh" >/dev/null
echo "V8:     $(node "$H/hsw-replay.js" "$REC" | head -3)"
T=$(mktemp -d)
{ printf 'var REC = '; python3 -c "import json,sys;print(json.dumps(open(sys.argv[1]).read())+';')" "$REC"
  cat "$H/hsw-replay.js"; } > "$T/replay.js"
echo "engine: $("$W/harness" "$W/poly.js" "$T/replay.js" 2>&1 | head -3)"
rm -rf "$T"
