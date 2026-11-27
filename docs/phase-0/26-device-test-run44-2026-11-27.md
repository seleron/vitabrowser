# Device test run 44 — 2026-11-27

## What is in the VPKs

- **Stack tip:** `689d158` — "patch 493: `\"str\".charCodeAt(i)` read in place
  by the interpreter (QuickJS 08)".
- **Baseline for this run:** `357c51d` = patch 475 (the run-43 stack, tool
  fix on top of it).
- `VitaBrowser-ext.vpk` (VBRW00002, **primary**): SHA256 `44486636dd6f8741…`
- `VitaBrowser.vpk` (VBRW00001, fallback): SHA256 `448814c92716cf27…`
- `nsvita.elf`: the extended build's ELF (288 MiB newlib heap), for
  crash-dump symbols. SHA256 `027a81e0e1ed5f31…`. Full sums in `SHA256SUMS`.
- `reference-dumps/`: the gate493 autotest dumps, built from exactly this
  stack (465 files) — `vita-netlog.py` diffs the Vita's logs against these.

## What changed since run 43 — headline first

### P1 — heavy-page performance (top priority per the 14:50Z directive)

The run-43 device numbers were bbc.com **125.7 s** and github.com
**286.4 s** full loads, with the heap at 80-88 MiB of a ~90 MiB arena and
the low-level cache thrashing (942 adds / 909 reclaims / 901 frees in one
session). Units that landed:

- **477** — the TLS CA store is parsed once and shared by every connection
  (a bbc load touches 17 HTTPS hosts; before, each connection re-parsed all
  122 certs). Sim: bbc heap at Done **102 → 92 MiB (-10%)**, CA-parse CPU
  **2.7% → 0**.
- **478** — a pending fetch released from a shared object no longer takes a
  snapshot copy. Sim: youtube llcache objects 79 → 64, same-page copies
  22 → 8 (the repeated Google-logo SVG / icon churn).
- **489** — the extended VPK gets its **own ELF with a 288 MiB newlib heap**
  (before, both VPKs shared a 192 MiB heap and ~110 MiB of the ext budget
  sat unused). The 4-page sim session peaks ~142 MiB: **74% of 192 MiB vs
  49% of 288 MiB**. The boot log prints `mem: newlib heap 288 MiB`.
- **490** — the low-level cache budget now scales with the heap
  (`memory_cache_size` = heap/8: 24 MiB standard, **36 MiB extended** →
  llcache 27 MiB, up from the NetSurf default 9 MiB). Sim, 4-page session:
  re-created network objects **95 → 1**, bbc objects re-fetched on the
  revisit **87 → 1**, bbc revisit **3.4 → 2.2 s**, peak heap +1%.
- **493** — the interpreter reads `\"str\".charCodeAt(i)` in place (no
  method-call frame). That is exactly styled-components' djb2 hash —
  17% of bbc's JS: its samples **481 → 314 (-35%)**, all JS samples
  2627 → 2468 (-6%).
- (476, 491, 492 were the measuring units behind these: JS is 61-69% of
  bbc's CPU, malloc 20%, one styled-components chunk 59% of all JS, with
  `flatten()` 23% and the djb2 hash 17%.)

**Sim profile (bbc, patch 493):** first Done ~2.9-3.3 s; heap at Done
**92 MiB** (128-135 MiB at the 476 baseline); heap peak **~96 MiB**
(135 MiB baseline).

**Expected on the device:** bbc and github full-load times down sharply
(bbc was 125.7 s, github 286.4 s); less or no memory-pressure thrash under
the 288 MiB heap with the 27 MiB llcache; readable content on github visible
much earlier (the session re-fetch churn that kept the page half-built is
gone).

### P2 — input focus / keyboard (shadow-DOM progress)

- **479** — a textarea's rows is its natural height; a tap on its border
  places the caret.
- **480** — a defined custom element's `addEventListener` is the bridge's,
  so its listeners are called (the old.reddit login options reach the
  hosts).
- **481** — events enter shadow trees through slots; a nested
  `dispatchEvent` really dispatches.
- **482-484** — content-broadcast use-after-free fixes (wpblog/wikipedia
  interaction crashes 3/3 → 0).
- **485** — attribute names follow HTML's rule, so lit templates bind
  (this is why old.reddit was blank before: attribute names with `$` were
  dropped).
- **486** — `<slot>.assignedNodes` / `assignedElements` / `assignedSlot`.
- **487** — custom elements in shadow roots are upgraded; `isConnected` is
  shadow-including; `importNode` constructs.
- **488** — `innerHTML` keeps the text and comments before the first
  element. With it, **old.reddit renders through its shadow trees** (the
  login options are visible and reach the hosts), but
  `<faceplate-text-input>` (a lit part) renders no `<input>` yet — that one
  field type is still inert; the WIP is parked.

**Expected:** tap on the google search box opens the on-screen keyboard and
typing + search works; old.reddit login options respond to clicks (the
faceplate text field itself is the known gap above).

### Known non-issues from run 43 — do not re-report

- **google.com /sorry bot-check page** — Google-side, not fixable here.
- **youtube.com video playback** — no video decode on the Vita; text and
  thumbnails only.
- **claude.ai / claude.ai/code heaviness** — same engine constraints as
  github; expect the same order of improvement, not speed.

## Install and launch

**PRIMARY app from now on: the extended VPK (user directive 14:50Z).**

1. Copy `VitaBrowser-ext.vpk` and `VitaBrowser.vpk` to the Vita
   (`ux0:download/`), over VitaShell FTP (SELECT in VitaShell) or USB.
2. In VitaShell, highlight each VPK, press ✕ → install. Both install side by
   side ("VitaBrowser" and "VitaBrowser ext-mem"). Neither should ask for
   extended permissions. The ext build needs 3.65 HENkaku (where
   ATTRIBUTE2=12 works).
3. **Launch "VitaBrowser ext-mem"** (`VitaBrowser-ext.vpk`, VBRW00002,
   ATTRIBUTE2=12, ~365 MiB MAIN vs ~256 MiB for the standard). The boot log
   must show `mem: newlib heap 288 MiB`; if it says `192`, the standard VPK
   was launched — relaunch ext-mem.
4. The standard `VitaBrowser.vpk` ships alongside as a fallback only.

## Run procedure

1. **Start `receive-results.bat` on the PC FIRST** (Vita on the same Wi-Fi).
   It catches every launch into a fresh `results\net-<date>-<time>-<boot>\`.
2. Install the VPKs (step 1-2 above).
3. Launch **VitaBrowser ext-mem** and let the L1 page settle (HUD
   `1/18 L1-layout-basics`).
4. **Autotest:** on that first page press **SELECT+SQUARE once** and **do
   not touch the Vita** until it says **AUTOTEST DONE** (~8 minutes). It
   visits all 18 pages (HUD `n/18`), scrolls long pages, then measures font
   metrics and memory.
5. Then the manual site list below (SELECT+TRIANGLE for URL entry).

**Controls:** SELECT+SQUARE autotest · SELECT+CIRCLE dump ·
SELECT+CROSS screenshot · SELECT+TRIANGLE memory · SELECT+L2/R2 prev/next
test page · SELECT+START quit. Alone: SQUARE = zoom, CIRCLE = HUD,
TRIANGLE = URL entry, START = home.

## Manual test focus (run 43 order, all user-tested there)

1. **bbc.com** — how fast is the full load now, vs 125.7 s in run 43?
2. **github.com** — run 43 showed "a few icons" for 5+ minutes and was
   force-quit. Target: readable content within ~1 minute, full load under
   ~2 minutes.
3. **google.com** — tap the search box: does the keyboard appear? Type and
   search.
4. **youtube.com** — search box keyboard; the Shorts section.
5. **old.reddit.com** — login options: does tapping "use mobile number" etc.
   respond? (Known gap: the faceplate text field renders no `<input>` yet.)
6. **wpnews / wpblog** — interaction flicker check (should stay clean since
   the 435-469 fixes).
