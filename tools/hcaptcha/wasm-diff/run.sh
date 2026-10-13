#!/bin/sh
# wasm3 against V8 on a real module (hCaptcha's hsw): every function whose
# call tree is import-free is exported and called three times with seeded
# arguments in both, one process per function; results (floats as bits),
# trap kinds and a CRC of linear memory after each call must match.
# 2026-10-13 on hsw (436 functions): 426 identical, the rest all memory.grow
# past wasm3's limit (V8 grows to ~3 GB for garbage sizes).
# Usage: WORK=<WORK>/vitabrowser-work tools/hcaptcha/wasm-diff/run.sh mod.wasm OUTDIR
set -e
H=$(cd "$(dirname "$0")" && pwd); WORK="${WORK:-$HOME/vitabrowser-work}"
M=$1; O=$2; Q="$WORK/host-quickjs"
mkdir -p "$O/out"
python3 "$H/gen.py" "$M" "$O/mod.wasm" "$O/calls.json"
python3 "$H/m3prep.py" "$O/calls.json" "$O/calls.txt" "$O/imports.txt"
gcc -O2 -I"$Q/include/wasm3" "$H/m3run.c" "$Q/lib/libm3.a" -lz -lm -o "$O/m3run"
N=$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))['calls']))" "$O/calls.json")
seq 0 $((N - 1)) | xargs -P 8 -I{} sh -c "
	timeout 10 node '$H/v8run.js' '$O/mod.wasm' '$O/calls.json' {} > '$O/out/v{}.txt' 2>&1 || echo TIMEOUT >> '$O/out/v{}.txt'
	IMPORTS='$O/imports.txt' timeout 10 '$O/m3run' '$O/mod.wasm' '$O/calls.txt' {} > '$O/out/m{}.txt' 2>&1 || echo TIMEOUT >> '$O/out/m{}.txt'"
same=0; diff=0
for i in $(seq 0 $((N - 1))); do
	if cmp -s "$O/out/v$i.txt" "$O/out/m$i.txt"; then same=$((same + 1)); else diff=$((diff + 1)); echo "differs: call set $i"; fi
done
echo "wasm-diff: $same identical, $diff differ (of $N)"
