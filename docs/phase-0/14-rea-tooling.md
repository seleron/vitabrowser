# 14 — REA (Reverse Engineer Anything) for VitaBrowser work

*2026-10-12. REA 6.4.0 (morluto/rea) at `~/Desktop/rea`; CLI
`node ~/Desktop/rea/scripts/rea.mjs <command>`, also registered as the MCP
server `rea` for new Claude Code sessions.*

## What works on this machine

`rea doctor`: not healthy. Ubuntu 22.04 is below REA's supported hosts
(24.04+), and no native analysis engine is configured (Ghidra, Hopper,
IDA). Commands tried on our own artifacts:

| command | target | result |
|---|---|---|
| `inspect-artifact` | run 31 VitaBrowser.vpk | works: hashed inventory of the zip (231 nodes). Every file is typed "file" -- eboot.bin is not recognised as a SELF -- and no follow-up probes are suggested. |
| `inspect-wasm-artifact` | a hand-made 41-byte module | works once `REA_WABT_BIN_DIRECTORY` points at WABT 1.0.42 (installed user-space at `~/opt/wabt-1.0.42/bin`, release checksum verified): validation, sections with byte ranges, imports, exports, decoded WAT, and the hash and arguments of each WABT tool used. |
| `inspect-binary-layout` | nsvita.elf | refused: "requires ELF64 little-endian objects". The Vita is 32-bit ARM, so pwntools (`REA_PWNTOOLS_PYTHON`) does not help; tried and removed. |
| `analyze`, `decompile` | nsvita.elf | refused: needs Ghidra 12.1.x (`GHIDRA_INSTALL_DIR`), Hopper or IDA. |
| web commands (`analyze-web-bundle`, `export-web-scripts`, `trace-web-source-location`, `recover-javascript-sources`) | -- | not run: they read a Chromium over CDP (`--remote-debugging-port`), i.e. a live site. |

## How we would use it

1. **hCaptcha's proof-of-work WebAssembly (most useful now).** Capture
   hsw.js and its module bytes as in `docs/wasm-hcaptcha-measurement.md`
   ("How to measure again"), then:

   ```sh
   REA_WABT_BIN_DIRECTORY=$HOME/opt/wabt-1.0.42/bin \
     node ~/Desktop/rea/scripts/rea.mjs inspect-wasm-artifact hsw.wasm \
     --glue_paths hsw.js --format json > hsw-evidence.json
   ```

   This replaces the measurement's scratch section walker with a
   reproducible record: imports (the 182 `"a".*` functions) tied to the
   glue, the 21 exports, the WAT to read the heavy functions in, and
   hashes that say which hsw build was measured (it changes per
   deploy). One caution: REA validates with `--enable-all`, so it cannot
   say "pure MVP"; for that, run WABT's `wasm-validate` with the
   post-MVP features disabled, or keep the opcode walk. A re-measurement
   before building WebAssembly support should start here.

2. **Minified site errors.** When a scored site throws inside a minified
   bundle (google's `$ra` at `{{0}}:307:407` took a de-minified read by
   hand, scorecard r4), capture the page in Chromium with
   `--remote-debugging-port`, `export-web-scripts`, and map the position
   with `trace-web-source-location` when the site ships source maps.
   Untested here; the scorecard already drives Playwright Chromium, so
   the endpoint is one launch flag away.

3. **What changed between hand-offs.** `inspect-artifact` on two VPKs
   gives two hashed inventories (`compare` takes Evidence bundles).
   Marginal over `unzip -l` plus `sha256sum`, but it is evidence a later
   session can re-verify.

4. **Vita userland binaries (the system browser, SceWebKit, as a
   reference for behaviour): not feasible yet.** They are encrypted SELFs
   that must be decrypted on the device first. REA's ELF layout is
   64-bit only, and `analyze` / `decompile` of a decrypted 32-bit ARM ELF
   needs Ghidra 12.1.x, which needs a JDK 21+ (we have only a JRE 25 in
   `~/opt`). Our own nsvita.elf has symbols and source, so readelf,
   objdump and `~/opt/gdb/gdb.sh` already cover it.

## Housekeeping

`rea doctor` also reports a stale installed skill and drifted
registrations for Hermes and pi; `rea setup` would rewrite those agents'
configs, so it was not run.
