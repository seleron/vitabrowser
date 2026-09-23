# 10 — First hardware test plan

**Date:** 2026-09-22 · **Build:** patches 29–33 · **Artifacts:** `C:\Users\seleron\<PC>\VitaBrowser-hwtest\`

The first run of VitaBrowser on a real PS Vita. Everything up to now was
proven on the build machine (09 §3). This run answers what only hardware
can: does it boot; do the PGF font size, baseline and clip edges match the
assumptions (09 §6); how fast is it; how much memory does the app really
get (pre-phase-0 §1, still open).

The test build carries its own instrumentation (patch 33, `vita/diag.c`).
Almost every question below is answered by a **file the Vita writes**, not
by eye. The visual checks are there for what files cannot show.

## What was built for the run

| Item | Where |
|---|---|
| `VitaBrowser.vpk` (title `VBRW00001`, default memory budget) | hand-off folder |
| `VitaBrowser-ext.vpk` (title `VBRW00002`, `ATTRIBUTE2=12`: the extended 365 MiB budget) | hand-off folder |
| 15 reference screenshots from the host simulator (same code, DejaVu font instead of PGF) | `reference-screenshots\` |
| exact `nsvita.elf` (for crash-dump symbols), SHA256 sums, the simulator's reference `log.txt` + plot dumps | `<WORK>/vitabrowser-work/hwtest-2026-09-22/` |

SHA256 (first 12 hex digits; full sums in `hwtest-2026-09-22/SHA256SUMS`):
`VitaBrowser.vpk` `0ab65b70c9c5`, `VitaBrowser-ext.vpk` `6a22c474457b`,
`nsvita.elf` `e156ce9ed6a4`.

**Diagnostics the build writes** to `ux0:data/VitaBrowser/`:
- `log.txt`: timestamped and flushed per line, so a crash leaves everything
  up to it. It records the title id, CPU/GPU clocks, each init stage's result,
  and free memory per pool. For every page it logs navigation, load time,
  first-frame time, CPU and GPU ms per frame, draw calls, extent and memory.
  It also records the PGF font metrics and the allocate-until-failure probe
  (newlib heap, USER_RW, CDRAM, PHYCONT, `sceAppMgrGetBudgetInfo`).
- `NN-<page>.plot` (+ `-bottom` for long pages): the frame's plot stream in
  the nsmonkey format. It diffs line for line against the simulator's
  reference dumps; text-width differences show PGF vs DejaVu metrics
  directly.
- `autotest.done`: marker written when the autotest finishes.

**Controls:** D-pad / left stick scroll · L / R previous / next page ·
□ autotest · SELECT dump this page · △ memory probe · ○ toggle HUD ·
START quit. The HUD (bottom bar) shows page n/15, first-frame ms, CPU/GPU ms
of the last frame, and draw calls.

## The plan

Allow **30–40 minutes**. Record answers in the results template at the end.
If something fails, **stop at that step, do step 8 (collect), and send
what you have**: a partial log is still useful.

### Step 0 — Setup facts (record, no action)

- Model: PCH-1000 (OLED) / PCH-2000 (slim) / PSTV.
- Firmware version (Settings → System → System Information).
- Exploit: Enso / h-encore / HENlo, and HENkaku version.
- Storage: Sony memory card or SD2Vita, and free space (≥ 50 MB).
- taiHEN plugins loaded, **especially overclock plugins** (PSVshell,
  oclockvita…): they change every timing number.
- VitaShell version.

### Step 1 — Install

1. Copy `VitaBrowser.vpk` and `VitaBrowser-ext.vpk` to the Vita, e.g.
   `ux0:downloads/`, over VitaShell's FTP (SELECT in VitaShell) or USB mode.
2. If `ux0:data/VitaBrowser/` exists from an earlier try, delete it, so the
   log starts clean.
3. In VitaShell, highlight each VPK, press ✕ → install. Neither should ask
   for extended permissions: the eboot is built "safe" (`vita-make-fself -s`).
4. **Record:** install result for each. Do two bubbles appear ("VitaBrowser"
   and "VitaBrowser ext-mem"), each with a blue square icon, and does the
   LiveArea open (blue background, a "start" gate)?

### Step 2 — Boot (T1)

Launch **VitaBrowser** (not ext-mem).

- **Expected:** within a few seconds, a white page with "L1 heading", a grey
  block, a paragraph, a float and a small table; a dark HUD bar at the
  bottom reading `1/15 L1-layout-basics | …`.
- **Record:** time from tapping the gate to the page (rough stopwatch), and
  what you see.
- **If it fails:**
  - System error dialog (e.g. `C2-12828-1`): note the code. A crash dump
    `ux0:data/psp2core-*.psp2dmp` should exist; keep it.
  - Blue text "VitaBrowser: … failed (n)": photograph it, press START.
  - Black or frozen screen for > 30 s: hold PS to close. Note it.
  - In every case, go to step 8.

### Step 3 — Autotest (T2)

On the L1 page, press **□ once** and **do not touch the Vita** until it says
**AUTOTEST DONE**. It visits all 15 pages. A cyan message box shows
`AUTOTEST page n/15`. Long pages scroll to the bottom by themselves. At the
end it measures font metrics and memory. The simulator needs about 21 s;
expect longer on the Vita.

- **Record:** did it reach DONE; total time (stopwatch); if it stalls,
  the page number and how long you waited (give it 2 minutes per page).
- Do **not** quit yet.

### Step 4 — Visual checks with screenshots (T3)

Use **L / R** to visit each page. On each, take a **screenshot**: press the
**PS button and START together**. They land in `ux0:picture/SCREENSHOT/`,
and are pixel-exact, which matters for calibration. If screenshots don't
work for this app, take phone photos instead and say so.

Compare each with its reference in `reference-screenshots\` (NN matches
the HUD's page number). The references use a different font, so **text
will differ in size and width**. Everything else should match. Answer:

| # | Page | Check |
|---|---|---|
| 1 | L1-layout-basics | layout as the reference? table borders visible? |
| 2 | L2-macsurf-css | "rounded + shadow" box has a thin dark shadow right/bottom; form input box with border |
| 3 | L3-grid | a stacked list G1a…G6d **is expected** (standard grid not implemented, 06 §7) |
| 4 | L4-flex | six rows; rows 2/4/6 spread items apart |
| 5 | PM-gradient | smooth(ish) red→blue vertical band, black→white horizontal, solid yellow box |
| 6 | PM-shadow | red box with a grey 8 px shadow on its right edge; blue box below it |
| 7 | PM-animation | red vertical bar crossing a 50%-blue box (overlap purple); green box |
| 8 | PM-macsurf-grid | 3×2 bordered cells C1…C6 |
| 9 | PM-tagtype | a label, a select "optA", an input "hello" |
| 10 | PM-link | link text renders |
| 11 | PM-shadow-clip | red and green boxes each with a full 10 px grey shadow; blue box's shadow cut at the bottom (right side showing is a known, separate bug) |
| 12 | **VT-calibration** | see step 4a, the most important page |
| 13 | VT-text | see step 4b |
| 14 | VT-images | four colour-bar images (PNG/JPEG/GIF/BMP), one ×2, a tiled strip, a repeat-x strip, and a box split **dark red \| pink** |
| 15 | VT-scroll | orange wide bar + "Row 1…" stripes; see step 5 |

**4a — VT-calibration (page 12).** Take **two** screenshots of this page.
For each item, answer yes/no, or describe:

- A. **Ticks:** 11 thin tick marks along the very top, 100 px apart,
  the last at the right edge?
- B. **Shared edge:** the red and blue boxes touch with no gap and no
  darker/overlapping line?
- C. **Hairlines:** four thin horizontal lines, equally spaced and equally
  thick, none missing?
- D. **Clip:** the green box near the top at x = 700 (100 × 40) has a black
  border on its **top and left only**, none on its right or bottom?
- E. **Text size / baseline:** seven yellow strips labelled 10px…48px. For
  each, is the text about as tall as its strip? Is it **too big**
  (spilling out), **too small**, **too high** (tops cut or above) or
  **too low** (sitting on or below the bottom edge)? The 48px and 20px
  strips matter most.
- F. **Width agreement:** four grey boxes at the right (MMMMMMMMMM,
  iiii…, "The quick brown fox", "a b c d…"). Does the text end **exactly**
  where the grey ends? If not, which way (text past the grey, or grey past
  the text), and by roughly how many letters?
- G. **Wrapping:** in the light-blue box, does any line run past its right
  edge?

**4b — VT-text (page 13).** For each line, does it render correctly, show
empty boxes, show nothing, or show garbage?
Latin-1 accents · Greek · Cyrillic · Japanese · Korean · Chinese · emoji.
Also: is **bold** distinguishable from regular (expected: no, weight isn't
implemented)? Are the underline and strike-through lines in sensible
places? Are there bullets and numbers on the lists?

### Step 5 — Controls, scrolling, HUD (T4)

On **VT-scroll** (page 15):
- D-pad down: does it scroll smoothly to "Bottom of the page"? Any tearing,
  flicker, stale stripes or garbage? Rate smoothness 1–5.
- Left stick: scrolls, speed proportional to tilt? D-pad right / stick
  right: reaches "END" of the orange bar?
- **Record** the HUD's `cpu … gpu … ms` while scrolling (read a typical
  value).

Anywhere:
- ○ hides and shows the HUD.
- SELECT → message "dumped manual-….plot".
- △ → "memory probe…", then "memory probe done". Record how long it takes
  and whether the app survives.
- **START** → the app exits back to LiveArea **without an error dialog**.
  Record exactly what happens.

### Step 6 — Extended-memory variant (T5)

Launch **VitaBrowser ext-mem**.
- Does it launch at all? (`ATTRIBUTE2=12` has not been confirmed on your
  firmware; an error dialog here is a valid, useful result: note the code.)
- If it runs: press **△**, wait for "memory probe done", then **START**.
  That's all: its numbers go into the same `log.txt` under title
  `VBRW00002`.

### Step 7 — Robustness (T6)

Launch **VitaBrowser** again, open **VT-scroll** (R until page 15):
- scroll up and down continuously for about 1 minute;
- press the **power button briefly** (suspend), wait 10 s, wake the Vita:
  does the app come back and still draw and scroll?
- press **PS** to go to the home screen, then return to the app: same
  question;
- then START to quit.

### Step 8 — Collect and send

Copy to `C:\Users\seleron\<PC>\VitaBrowser-hwtest\results\` (VitaShell
FTP or USB):
1. the whole folder `ux0:data/VitaBrowser/`: `log.txt`, all `*.plot`,
   `autotest.done`;
2. your screenshots from `ux0:picture/SCREENSHOT/` (the VitaBrowser ones);
3. any crash dumps: `ux0:data/psp2core-*.psp2dmp`;
4. photos, if you took any.

Then paste the filled-in template below into the chat and say the files
are in place. The analysis side (the log, dump diffs against
`hwtest-2026-09-22/sim-reference/`, crash dumps against the archived ELF)
is on me.

## Results template

```
VITABROWSER HW TEST 2026-09-22 — RESULTS

STEP 0  model:            firmware:         exploit/HENkaku:
        storage + free:   plugins (overclock?):     VitaShell:
STEP 1  install VitaBrowser: ok/fail ...   install ext-mem: ok/fail ...
        bubbles + icons + LiveArea: ...
STEP 2  boot: ok/fail   time to page: ~ s   notes/error code:
STEP 3  autotest reached DONE: y/n   total time: ~ s   stalled at page:
STEP 4  screenshots work: y/n (photos instead?)
        pages 1-11 (anything different from the reference other than text):
          1: 2: 3: 4: 5: 6: 7: 8: 9: 10: 11:
        4a VT-calibration  A ticks:  B shared edge:  C hairlines:  D clip:
           E text size/baseline per strip (10/12/16/20/24/32/48):
           F width agreement (4 boxes):
           G wrapping:
        4b VT-text  Latin-1:  Greek:  Cyrillic:  Japanese:  Korean:  Chinese:  emoji:
           bold distinguishable:  underline/strike:  bullets/numbers:
        14 VT-images  PNG/JPEG/GIF/BMP:  x2:  tiles:  dark red|pink:
STEP 5  scroll smoothness 1-5:   artefacts:   stick:   reaches END:
        HUD cpu/gpu while scrolling:   O hud:   SELECT dump:
        TRIANGLE probe time + survived:   START exit clean:
STEP 6  ext-mem launches: y/n (error code?)   probe done:
STEP 7  1-min scroll:   suspend/resume:   PS home + return:
STEP 8  files copied to results\: y/n   crash dumps: y/n
OTHER   anything else you noticed:
```

## What each answer decides

| Result | Decides |
|---|---|
| boot / init stages in the log | whether the next session fixes start-up or moves on |
| E (text size/baseline) + the logged PGF metrics | `VITA_PGF_EM_PX` and the baseline convention (09 §6) |
| F (width) + `.plot` text diffs | whether layout and drawing agree on PGF (glyph-advance method) |
| B, C, D, ticks | vita2d rect coverage and clip-edge semantics (09 §6) |
| page timings, CPU/GPU ms | first real performance numbers vs the brief's §1 estimates |
| memory probe (both VPKs) | the measured budget: closes pre-phase-0 §1's open item, and whether `ATTRIBUTE2=12` works here |
| VT-text scripts | how much of the web the system font can show before freetype/harfbuzz |
| step 7 | whether suspend/resume needs GXM handling before daily use |

## Run 1 — results (2026-09-22, PCH-2000, firmware 3.65 HENkaku, no overclock)

Files: `<WORK>/vitabrowser-work/hwtest-2026-09-22/device-results/` (log,
17 plot dumps, 2 screenshots); the tester's filled-in template is quoted in
the session.

**What works on hardware.** Install (both VPKs), LiveArea, boot in about
0.5 s to the first frame, every init stage (`vita2d_init_advanced -> 1`,
PGF font, `netsurf_register`, `nsoption_init`, messages, `netsurf_init`
all OK), GPU drawing (the HUD), input (L/R, ○, SELECT, △, START), the
memory probe, clean exit, suspend/resume and PS-home/return. No crash, no
crash dump.

**The failure: no page ever loads.** Every page logs `load not finished`
after the 20 s settle timeout, with `extent 0x0` and 1 draw call; every
dump is `CLIP` + one full-screen `RECT`, the core's placeholder when it has
no document. So the fetch never completes, and it does not fail either: a
failure would have produced an error page. The same code loads every page
in the host simulator (~165 ms each).

What was ruled out:
- **The file fetcher itself.** `stat` / `fopen` / `fread` would report an
  error, not hang, and setup only converts the path.
- **Miscompiled implicit calls.** A clean cross build has exactly one
  implicit declaration, `strcasecmp` (returns `int`, ABI-safe).
- **Init.** Every stage returned OK on the device.

> **Corrected after run 2: this hypothesis was wrong.** The fetch
> completes in about 100 ms; HTML creation fails because vitaSDK's newlib
> has an empty `iconv`. See §Run 2 — results.

**Leading hypothesis (wrong, see above): fetches stranded by the
scheduler-only fetch poll.**
Upstream frontends call `fetch_fdset()` every loop iteration (monkey, gtk),
which also dispatches queued fetches and polls every fetcher. MacSurf's core
documents fetches getting stranded when the self-rescheduling poll goes
dormant, and its own event loop calls `fetch_pump()` every iteration
(`content/fetch.c`, fixes90). The Vita loop did neither. It is not yet
explained why the simulator escapes it, so run 2 is built to show the
mechanism rather than assume it.

**Measured memory (closes pre-phase-0 §1's open item):**

| | default VPK (VBRW00001) | `ATTRIBUTE2=12` VPK (VBRW00002) |
|---|---|---|
| free USER at boot, after the 192 MiB heap + 4 MiB stack | 51 MiB | — |
| newlib heap free to `malloc` | 190 MiB | 190 MiB |
| USER_RW blocks beyond the heap | **40 MiB** | **149 MiB** |
| app MAIN total, approx. | **≈ 256 MiB** | **≈ 365 MiB** |
| CDRAM free (after vita2d's framebuffers) | 89 MiB (112 MiB before `vita2d_init`) | 89 MiB |
| PHYCONT | 26 MiB | 26 MiB |

The documented budgets hold on 3.65 HENkaku: 256 MiB default and
**365 MiB with `ATTRIBUTE2=12`, which works here** (+109 MiB).
`sceAppMgrGetBudgetInfo` is refused to a normal app (`0x8080201f`), as its
header says. vita2d and the engine's init take about 13 MiB of USER and
23 MiB of CDRAM.

**Other readings.**
- Clocks read ARM 333 MHz and GPU 41 MHz (as returned by
  `scePowerGetGpuClockFrequency`; probably a power-managed idle reading).
- The first blank frame took 52 ms of CPU and 4 ms of GPU.
- The HUD did not update on L/R: the loop only repainted when the page
  invalidated, and with no document it never did. Fixed in run 2.
- VitaShell 2.02 showed "this package requests extended permissions" for
  both VPKs. The eboot's authid is the safe `0x2F00000000000002` (file
  offset 0x80), and none of the libraries VitaShell's current source flags
  (`SceVshBridge`, `ScePromoterUtil`, `SceShellSvc`) are imported. The one
  unusual import is `SceGxmInternalForVsh`, from libvita2d, which is the
  likeliest trigger. Unverified and harmless; open.

## Run 2 — the diagnostics-2 build (patch 34)

The same VPK names in the hand-off folder, rebuilt (SHA256 first 12:
`VitaBrowser.vpk` `0683dfb74f4d`, `VitaBrowser-ext.vpk` `7cbcc9129308`,
`nsvita.elf` `60314993b2ca`; archive
`<WORK>/vitabrowser-work/hwtest-2026-09-23-run2/`).

What it adds:
- `netsurf.log`: the engine's own log, with NetSurf's NSLOG at every level
  plus MacSurf's engine traces. It is buffered, flushed each second, and
  capped at 16 MB. A full simulator autotest writes about 0.5 MB.
- Once a second until a page's document arrives: `load status … loading,
  extent, sched pending (added, fired), pump on/off`. This shows directly
  whether scheduled callbacks, including the fetch poll, run on the Vita.
- Window events, status text and URL changes in `log.txt`.
- **Stall rescue.** If a page has no document 1.5 s after navigating, the loop
  logs `fetch stalled?` and calls `fetch_pump()` every iteration for that
  page. The log then says whether the document arrived with the pump on.
  Verified safe in the simulator by forcing the pump on for every page:
  16/16 loads, dumps byte-identical, documents arrive sooner (117 ms vs
  165 ms).
- The HUD and messages repaint on their own.

Run 2 is short:
1. Install the new **VitaBrowser.vpk** over the old one (the ext-mem VPK
   isn't needed this time).
2. Delete `ux0:data/VitaBrowser/`.
3. Launch VitaBrowser and wait 10 s on L1. **Does the page render now?**
4. Press □ (autotest), wait for AUTOTEST DONE, then START.
5. Copy `ux0:data/VitaBrowser/` (now including `netsurf.log`) into
   `results\`.
6. If pages render, also redo the checklist's steps 4, 4a, 4b, 5 and 7 with
   screenshots.

## Run 2 — results (2026-09-23)

Files: `<WORK>/vitabrowser-work/hwtest-2026-09-23-run2/device-results/`.
Pages still did not render. `netsurf.log` (13.5 MB, the engine's own log)
settled the cause.

**The fetch was never the problem.** For every page the engine log reads:

```
llcache: Starting fetch ... Fetch event 2/3/4    (headers, data, done)
MS fetch FINISHED                                (~100 ms after navigating)
MS html create
MS hlcache content create FAILED
MS NAV: ERROR ... -> error page                  (about:query/fetcherror)
MS html create
MS hlcache content create FAILED                 (the error page is HTML too)
... repeated: 6111 times in 5 minutes
```

**Root cause: vitaSDK's newlib ships `iconv` with no converters.** Its alias
table is a single empty string, its CCS table is empty, and its encoding
handler tables are two empty NULL-terminated lists (`arm-vita-eabi-nm`/
`objdump` on `libc.a`). So every `iconv_open()` fails, even UTF-8 → UTF-8.
libparserutils' input filter calls `iconv_open()` for every input stream,
UTF-8 included (`src/input/filter.c` `filter_set_encoding`). No HTML or CSS
parser can be created. The host simulator linked glibc, whose `iconv` works,
which is why only the device failed.

**Reproduced on the host, and the fix proven there:**
- With `iconv_open()` forced to fail (an `LD_PRELOAD` shim), the simulator
  produces the device's exact trace (`html create` → `content create
  FAILED` → error page, looping).
- With libparserutils built `-DWITHOUT_ICONV_FILTER`, an upstream option
  that uses its own codecs (UTF-8/16, ISO-8859-x, Windows-125x), and
  `iconv_open()` still failing: **0 failures, 16/16 documents, every dump
  byte-identical** to the reference made with a working `iconv`.

**What changed for run 3:**
- `tools/build-vita.sh` builds libparserutils `-DWITHOUT_ICONV_FILTER` and
  fails the build if the archive still references `iconv_open`.
- **The simulator now models the gap.** `vitasim.c` defines an
  `iconv_open()` that always fails, like newlib, and `run-vita-sim.sh`
  links a libparserutils built exactly as the Vita's. If that overlay ever
  stops being linked, no page loads and the run fails. (Its own check
  caught a stale-object mistake while it was being written.) Lesson: the
  simulator stands in for the SDK's *libc* as well as its GPU.
- **Patch 35: the error-page loop is guarded.** When the page that failed
  is `about:query/fetcherror` itself, the core stops the load instead of
  retrying forever. This is upstream behaviour, not MacSurf's. Verified in
  the broken configuration: two failures per page (the page, then its
  error page), then `STOP_THROBBER`.
- **Patch 36:** the automatic fetch pump from run 2 is removed (its
  hypothesis was wrong); the load-status lines stay.
- **`log.txt` stayed untouched in run 2** (its timestamp moved; its bytes did
  not), while `netsurf.log` and the dumps were written, and the
  `autotest.done` marker was not refreshed. Not explained yet, so patch 36
  instruments it: one line-buffered handle, every write checked, failures
  reported with their errno in `netsurf.log`, and every line mirrored there
  as `DIAG …`.
  > **Corrected after run 3: not a Vita bug.** The copy to the PC served
  > cached old versions of every filename it had seen before (see §Run 3).
  > Patch 36's instrumentation is harmless and stays.
- **Still using `iconv`:** NetSurf's form-submission encoding
  (`utils/utf8.c`, from `html/form.c`) for non-UTF-8 charsets. Irrelevant
  until forms and networking exist, then it needs a converter (libiconv,
  or libparserutils' codecs).

## Run 3 — the iconv fix (patches 35–36)

Hand-off VPKs rebuilt (SHA256 first 12: `VitaBrowser.vpk`
`fbf54ea178b3`, `VitaBrowser-ext.vpk` `2f03b5c184ee`, `nsvita.elf`
`0bd94a0eaee2`; archive `<WORK>/vitabrowser-work/hwtest-2026-09-23-run3/`).
Clean checkout: applied 119 + the known 2; L1 SAME; fixtures 4/4; 93/93;
simulator 15/15 pages with newlib's `iconv` modelled.

This time the full checklist applies:
1. Install the new **VitaBrowser.vpk** over the old one, and delete
   `ux0:data/VitaBrowser/`.
2. Launch it. L1 should render within about a second.
3. Work through the checklist from step 3 (autotest) to step 8, clearing its
   old answers first.
4. Copy `ux0:data/VitaBrowser/` and the screenshots into `results\`.

## Run 3 — results (2026-09-23): pages render on hardware

**Every page renders.** The tester's checklist:
- Autotest completed in about a minute, with no stalls.
- Pages 1–11 pass against the references.
- **All seven VT-calibration checks pass** (ticks, shared edge, hairlines,
  clip, text size and baseline, width agreement, wrapping).
- Latin-1, Greek, Cyrillic, Japanese and Chinese render; PNG, JPEG, GIF, BMP,
  ×2 scaling, tiling and alpha are correct.
- D-pad scrolling rated 5/5 with no artefacts; the stick works and reaches
  the far right.
- HUD, dumps, memory probe, clean exit, the ext-mem VPK, a 1-minute scroll,
  suspend/resume and PS-home all pass.

Files: `<WORK>/vitabrowser-work/hwtest-2026-09-23-run3/device-results-partial/`.

**Issues seen:**
- **Korean** renders as blanks. The default PGF set that
  `vita2d_load_default_pgf()` loads evidently lacks Hangul; the system has
  a separate Korean font to try.
- **Emoji** render as blanks (expected: no colour-glyph font).
- **Bold** is not distinguishable (known: weight is not implemented).
- The **strike-through** line sits a little high, towards the top of the
  lower-case letters.
- **Performance while scrolling** (HUD): CPU 2–3 ms, but **GPU 31–37 ms**
  per frame. The "GPU" figure is `vita2d_end_drawing()` →
  `vita2d_wait_rendering_done()`. A blank frame measured 4 ms in run 1, so
  the cost grows with content: either display-queue / vblank waiting is
  counted in it, or `vita2d_set_clip_rectangle` is expensive (a page issues
  about 100 clips per frame). Needs its own look before real pages.

**The file-copy problem, and the run-2 "log.txt bug" explained.** In the
copied `results\`, every file whose name already existed on the card from
an earlier run came back **byte-identical to that earlier run's copy**.
That covers `log.txt` (= run 1), `netsurf.log` (= run 2), the top-of-page
dumps (= run 2's placeholders) and `autotest.done`, even though the listing
showed this run's times. Every *new* filename has new content: the
`-bottom` dumps and the two new manual dumps. The screenshots from this run
were not visible either. The Vita writes correctly; the PC-side copy served
cached files and listings for known names, which is typical of Windows
Explorer's FTP view. That is also what run 2's untouched `log.txt` was.

**What the fresh files show.** The device's `-bottom` dumps match the host
simulator's reference structurally (same op and rect counts). The only
differences are text widths: PGF's glyphs are about a pixel wider than
DejaVu's in places, so shrink-to-fit boxes (flex items, table cells) come
out a pixel wider and everything around them shifts consistently. Pages
without shrink-to-fit text (L3-grid, PM-gradient) are **byte-identical to
the simulator** at the scrolled bottom, so scrolled redraw is correct on
hardware.

### Run 3 — the full data (re-copied past the cache)

Files: `<WORK>/vitabrowser-work/hwtest-2026-09-23-run3/device-results/` (log,
engine log, 22 dumps, 7 screenshots). All 9 boots of the run-3 build report
`log.txt: open (errno 0)` with no write failures, and the engine log has no
HTML failures from run 3 (its 6111 are all run 2's, appended to), which
confirms the copy-cache explanation above.

**Timings on hardware (333 MHz ARM, no overclock):**

| | measured |
|---|---|
| boot to first frame | ~0.5 s |
| navigate → document (bundled pages) | **344–1403 ms**, most 400–700 ms (simulator: ~165 ms) |
| CPU per frame (layout walk + plot submit) | **1–7 ms** |
| GPU per frame (`end_drawing` → `wait_rendering_done`) | **12–69 ms**, growing with draw calls: 7-call PM-link 12 ms, 123-call VT-calibration 69 ms |

**The GPU figure is the performance problem.** About 0.5 ms per draw call is
far slower than the GXM should be. Two suspects, both cheap to test:
- the boot log reads **GPU clock 41 MHz** (`scePowerGetGpuClockFrequency`);
  homebrew ports commonly raise it with `scePowerSetGpuClockFrequency`;
- the per-call cost of `vita2d_set_clip_rectangle` (a page issues 30–160
  clips a frame).

CPU is not the constraint.

**PGF font metrics:** `text_height("Hg")` at scale 1 is 17 px (34 at scale
2), and "M" advances 17 px. Advances measured `"a"c"a" − "aa"` equal the
raw single-glyph widths for every printable ASCII character, space
included (6 px). The workaround in `layout.c` for PGF under-reporting
ink-less glyphs is therefore unnecessary on hardware, though harmless.
Calibration E and F passed visually with `VITA_PGF_EM_PX = 20`.

**Memory:** as in runs 1–2 (≈ 40 MiB USER_RW beyond the heap, 84–89 MiB
CDRAM, 26 MiB PHYCONT).

**Screenshots** (pixel-exact, from the Vita) show five rendering issues,
none of which the checklist asked about:
1. **Stray marks above some glyphs** (`Caf̄é`, `f̄açade`, `d̄ash`,
   `J̄apanese`, `C̄hinese`): pieces of neighbouring glyphs from vita2d's PGF
   atlas, sampled with linear filtering at a non-integer scale. Large
   headings are also soft (bitmap glyphs scaled up).
2. **Greek and Cyrillic are spaced out** (`Ε λ λ η ν ι κ _`), and accented
   `ά` is missing: the Latin system font lacks them, so they come from the
   Japanese font as full-width glyphs. Simplified Chinese is partial
   (`_体中文`: `简` missing). Korean and emoji are blank.
3. **A gap before punctuation after inline elements** (`Bold text ,
   italic text ,`). The host simulator shows it too, so it is a layout bug
   in the engine, not a device issue.
4. The strike-through sits a little high (tester).
5. One screenshot is completely black (probably taken mid-transition; not
   reproducible from the log).

Issues 1 and 2 argue for drawing text with FreeType from a TTF with
broad coverage (vita2d's `vita2d_font`, already linked) instead of the
system PGF, and for measuring with the same face.

## Next actions after run 3

1. **GPU time:** raise the GPU clock and measure; then measure clip cost,
   and batch or avoid clips.
2. **Text:** FreeType + a broad-coverage TTF for drawing and layout (fixes
   the atlas marks, Greek/Cyrillic/CJK coverage, and the soft headings).
   **Done in patch 38 (§Run 5).**
3. **Inline punctuation gap:** reproduce on the desktop (it shows in the
   simulator) and fix in the engine.
   **Gone in the simulator with patch 38** (a PGF measuring artefact, §Run 5);
   confirm on the device.
4. **Transfers:** copy results over USB or with a client that doesn't cache
   (FileZilla, WinSCP), or rename the folder on the Vita first.

## Run 4 — GPU time: clipping on the CPU, and the GPU clock (patch 37)

**Why run 3's GPU time was so high.** libvita2d clips with the stencil
buffer, and `vita2d_set_clip_rectangle()` rewrites the whole stencil every
time: a full 960×544 rectangle to clear it, then the clip rectangle
(libvita2d `vita2d.c`, read upstream). `vita2d_enable_clipping()` calls it
too. The plotter called **both for every core clip**: four stencil fills,
two of them full-screen, per clip, at 30–160 clips a frame. That fits both
the 12–69 ms and its growth with page complexity. `vita2d_wait_rendering_done()`
is `sceGxmFinish()`, so the number is real GPU work, not a vblank wait.

**The fix (patch 37, `frontends/vita/plot.c`): clip on the CPU.**
- Axis-aligned fills (backgrounds, gradient bands, shadows, borders, most
  calls) are intersected with the clip exactly on the CPU.
- A primitive wholly outside the clip is skipped; one wholly inside needs
  nothing.
- Only a primitive that crosses the clip edge (a quad, text, a texture or
  a line) uses the stencil, and the stencil is rewritten only when the clip
  changed since it was last written.
- Clipping is left off at the end of each frame, so
  `vita2d_start_drawing()` doesn't rewrite it before the next.
- The old behaviour stays selectable (`VITA_CLIP_STENCIL`) for measuring
  against.

**The GPU clock.** The run-1 and run-3 boot logs read "gpu 41 MHz". The build
now logs ARM, bus, GPU and GPU-crossbar clocks at boot, and the **browsing
profile sets the GPU to 222 MHz (crossbar 166)**, leaving the ARM as booted.
Every change is logged with its return code and the clocks read back.

**Verified on the host:**
- Unit test 100/100: new checks for each clipping path (cut, skipped,
  inside, crossing → stencil set once for many primitives, clipping off at
  frame end, stencil mode unchanged). Two planted mutations (no stencil
  cache, no CPU cut) are caught.
- Simulator: CPU clipping is **pixel-identical to the stencil clip on all
  14 comparable pages**. PM-animation changes by itself over time (its
  rotation is clock-driven: it differs even between two stencil-mode
  passes), so the harness reports it as time-varying and skips it. The
  harness now fails if any other page differs.
- Stencil writes per frame, same pages (simulator):

| page | clips | stencil writes, run-3 behaviour | CPU clip |
|---|---|---|---|
| VT-calibration | 169 | 338 | **25** (18 crossing primitives) |
| VT-scroll | 90 | 180 | **2** (1 crossing) |
| average over 15 pages | 77 | 154 | **13** |

- Plot dumps are byte-identical to run 3's reference, except
  PM-animation's animated box (time).
- Clean checkout: applied 120 + the known 2; L1 SAME; fixtures 4/4.

**The run-4 autotest measures both changes on the device.** It runs **four
passes** over all 15 pages, each page timed over 5 redraws (min/avg/max),
with a `pass X summary` line per pass in `log.txt`:

| pass | clipping | clocks | isolates |
|---|---|---|---|
| A | stencil per clip (run 3) | as booted | the baseline (≈ run 3) |
| B | stencil per clip | GPU 222 / crossbar 166 | the GPU clock alone |
| C | CPU | as booted | CPU clipping alone |
| D | CPU | ARM 444, bus 222, GPU 222, crossbar 166 | both, plus the ARM for load time |

Hand-off VPKs rebuilt (SHA256 first 12: `VitaBrowser.vpk` `83290de32e4f`,
`VitaBrowser-ext.vpk` `4233dac74fe0`, `nsvita.elf` `bdb66bef8a3a`; archive
`<WORK>/vitabrowser-work/hwtest-2026-09-23-run4/`, with the simulator's
reference log, dumps and per-pass snapshots).

Run 4 on the device (about 5 minutes):
1. Install the new **VitaBrowser.vpk**, and **delete
   `ux0:data/VitaBrowser/`** first.
2. Launch, press □, wait for AUTOTEST DONE (four passes, a few minutes),
   then START.
3. Scroll VT-scroll for a few seconds and note the HUD's `cpu … gpu … ms`
   and `… st` (stencil writes).
4. Copy `ux0:data/VitaBrowser/` into `results\` over USB mode or a
   non-caching FTP client (FileZilla / WinSCP), not Explorer's FTP view
   (§Run 3).

What decides the next step: pass B vs A (the clock), C vs A (the clipping),
and D (both). Whether GPU 222 needs anything beyond a safe homebrew
(`scePowerSetGpuClockFrequency` return codes in the log).

### Run 4 — results: not received (checked 2026-09-23)

`VitaBrowser-hwtest\results\` was **empty** when checked for the run-4
data: no `log.txt`, no `autotest.done`, nothing newer than the hand-off
(03:06), and no stray copy elsewhere under `VitaBrowser-hwtest\`. The
four-pass timings (clock vs clipping) are therefore **still unmeasured**.
Nothing was waited for. The next build (text, below) keeps the same
four-pass autotest, so one device run can measure both.

## Run 5 — text with FreeType and bundled fonts (patch 38), plus run 4's timings

**Why.** Run 3's text problems all came from the system PGF font. vita2d
rasterises it once and scales it: the scaled atlas bled marks next to
glyphs. Its fallback put Greek and Cyrillic in the Japanese font at full
width, and it has no Hangul, no emoji and no `简`. Patch 38 replaces it with
one FreeType engine, `frontends/vita/text.c` ([09 §11](09-vita-frontend.md)):
- **Fonts:** DejaVu Sans/Serif/Mono with real bold and italic faces; per
  code point, fallback to DroidSansFallbackFull (kana, CJK) and NanumGothic
  (Hangul).
- **Glyphs:** rasterised at the exact size and drawn unscaled from an alpha
  atlas with a 1-pixel empty gap.
- **Advances:** one set, used by layout and drawing alike.

The fonts (11 MB, three licences) are fetched by `tools/fetch-fonts.sh`,
pinned and SHA256-checked, and bundled in `res/fonts/`. The VPK is now
10.3 MB.

**Host results** (sim screenshots: `img/10-run5/`):

| run-3 problem | cause | now (simulator) |
|---|---|---|
| marks beside glyphs | scaled glyphs sampled past their atlas cell | exact-size glyphs with an empty border, point-sampled; the test checks every border texel |
| Greek/Cyrillic full-width | PGF fallback to the Japanese font | DejaVu Sans: `Ελληνικά`, `Кириллица` at proportional width |
| Korean, emoji, `简` blank | not in the PGF fonts | NanumGothic, DejaVu (😀 as an outline), Droid |
| gap before punctuation after inline elements | layout's PGF advances (`width("a"+c+"a") − width("aa")`) ≠ what was drawn | **gone**: measured = drawn (below) |
| strike-through too high | PGF ascent vs the engine's baseline guess | through the x-height (below); confirm on device |
| soft headings | no bold face (PGF regular only) | real DejaVu Bold (≥ 600) and Oblique |

![VT-text in the simulator](img/10-run5/VT-text.png)

Before (run-3 simulator reference) and after, the same line at 2×:

![before](img/10-run5/punct-before.png)
![after](img/10-run5/punct-after.png)

- `tools/test_vita_text.c` **30/30**. It uses the real engine, FreeType and
  fonts. Three mutations were planted and each is caught.
- `test_vita_plotter.c` **101/101**.
- Clip modes: still pixel-identical, 14/14 comparable pages.
- Atlas over the whole 4-pass autotest: **3 pages, 0 flushes, 0 drops, 1
  missing** (the U+E000 probe).
- `VT-calibration`: every grey width box ends with its text, and every
  yellow row holds its descenders.
- Clean checkout: applied 121 + the known 2; L1 PASS; fixtures 4/4;
  101/101 + 30/30; simulator 15/15; cross build `-Werror` clean, no PGF
  symbols in the ELF.
- Seen, not changed: on `VT-calibration` the in-flow paragraph paints over
  the absolutely positioned 200 px box. The pixels are identical before
  patch 38, so this is a paint-order issue, not a text one.

**Hand-off.** Built from the clean chain: `VitaBrowser.vpk` `bba81d5cdce7`,
`VitaBrowser-ext.vpk` `353b963ade0b`, `nsvita.elf` `59e5942ccdd7` (SHA256,
first 12). They are copied to `VitaBrowser-hwtest\`, replacing run 4's,
which stay in `<WORK>/vitabrowser-work/hwtest-2026-09-23-run4/`. Archive:
`<WORK>/vitabrowser-work/hwtest-2026-09-23-run5/` (VPKs, ELF, SHA256SUMS, the
simulator's reference log, dumps, shots and per-pass snapshots).
`VitaBrowser-hwtest\reference-screenshots\` is refreshed with the new
simulator shots.

**Run 5 on the device** (about 6 minutes). It keeps run 4's four-pass
autotest, so one run measures both:
1. Install the new **VitaBrowser.vpk** over the old one, and **delete
   `ux0:data/VitaBrowser/`** first.
2. Launch. The boot log should read `init: fonts (app0:/res/fonts/) -> 0`.
   If the fonts cannot be opened there is nothing to draw an error with, so
   the app returns straight to LiveArea; `log.txt` then ends at
   `init: fonts … -> <non-zero>`.
3. Press □ and wait for AUTOTEST DONE (four passes), then START.
4. Open **VT-text** (R to cycle) and compare it with
   `reference-screenshots\13-VT-text.png`:
   - Greek, Cyrillic, Japanese, Korean, Chinese and the emoji outline are
     all present;
   - no marks beside glyphs;
   - no gap before commas;
   - the strike-through crosses the middle of the lowercase letters;
   - bold and italic are distinct.
   Take a screenshot (PS + START).
5. Scroll VT-scroll and note the HUD's `cpu … gpu … ms` and `… st`.
6. Copy `ux0:data/VitaBrowser/` and the screenshots into `results\` over USB
   or with FileZilla/WinSCP.

**What decides the next step:**
- **The four passes (run 4's question):** pass B vs A is the GPU clock, C
  vs A is CPU clipping, and D is both.
- **Text cost:** each page's `first frame` ms against run 3. The first
  frame now rasterises glyphs, and VT-text's first frame also opens the
  Droid and Nanum faces.
- **The atlas line** in `log.txt` (`font: atlas … pages, … flushes, …
  dropped`). Any flushes or drops on the device mean the atlas needs more
  pages or an LRU.

### Run 5 — results: not received (checked 2026-09-23 03:48–03:52)

`VitaBrowser-hwtest\results\` was **empty** again: no `VitaBrowser\`
folder, no `log.txt`, no `autotest.done`, no screenshots. A search of the
whole user profile and drives D:–F: found nothing newer than the run-5
hand-off (03:31) apart from files this project wrote. The hand-off was 17
minutes old at the check, so the device run may simply not have happened
yet. Run 5 (text) and run 4 (timings) are both **still unmeasured**; the
VPKs in `VitaBrowser-hwtest\` stay valid.

Twice now the results did not arrive through the manual copy step (plus
run 2's stale Explorer-FTP copies). That is one more reason for the next
task: the Vita sends its log and plot dumps over the network itself
(§Run 6).

## Run 6 — results over the network (patch 39), plus runs 4 and 5

**Why.** Three runs have now lost results between the Vita and the PC:
- run 2's copies were stale, served from Explorer's FTP cache;
- runs 4 and 5 never reached `results\`.

Doc 03 also anticipated an on-device plot-stream log "over the UDP log"
([09 §7](09-vita-frontend.md)), and until now the formatter had no
transport.

**Patch 39 (`frontends/vita/netlog.c`)** sends everything the frontend
writes under `ux0:data/VitaBrowser/` to a receiver on the PC as it is
written: `log.txt` lines live, `netsurf.log` about once a second, and each
plot dump and `autotest.done` as it closes. The files on the memory card
are written exactly as before, so the network copy is an addition, not a
replacement.
- **Finding the PC:** the Vita broadcasts on UDP port 45100 until a
  receiver answers, then sends to the receiver alone. Nothing needs
  configuring. `ux0:data/VitaBrowser/netlog.cfg` can hold `off` or an
  address.
- **Checking:**
  - Every datagram carries a sequence number, so losses are counted.
  - Every finished file carries its length and CRC-32, and the receiver
    checks both.
  - Each launch gets its own folder (`results\net-<date>-<time>-<boot>\`),
    so a result can never be an old copy.
- **Safety:**
  - Sockets are non-blocking; only a full send buffer is retried (up to
    8 ms).
  - Bursts are paced at 2 ms per ~10 KB.
  - Sending pauses after 16 failures in a row and retries every 3 s.
  - A network failure is never fatal.
- **The receiver (`tools/vita-netlog.py`):**
  - Python stdlib only, for the PC's Python 3.12.10 (`py -3`).
  - It prints `log.txt` as it arrives.
  - With `--reference`, it compares each plot dump with the simulator's
    (SAME / DIFF + first differing line). That is the on-device diff the
    plot-stream item asked for.

**Host FreeType now matches the Vita's.** The simulator and the text test
used the host's FreeType 2.11.1, but the Vita has 2.14.3.
`tools/build-host-freetype.sh` builds 2.14.3 into `$WORK/host-freetype`
(userspace, no sudo). The SHA256 matched from both official mirrors, and
the simulator and the text test link it. Result: all 23 plot dumps are
byte-identical under both releases, and so are all 15 page screenshots
(only the HUD's timing numbers differ). So the fonts and sizes used today
hint the same in both. The pin stays as a guard, so a device-vs-simulator
DIFF means a real difference.

**Verified on the host:**
- The simulator's autotest sends to a local receiver, the same code path as
  after a receiver answers on the Vita. Result: **23/23 files byte-identical
  to the simulator's memory card** (log.txt, netsurf.log 2.0 MB, 20 dumps,
  autotest.done), **3 613 datagrams, 0 lost**, and a clean goodbye.
  `run-vita-sim.sh` now fails if any file differs or any datagram is lost.
- **The first attempt lost 5 datagrams, and the test caught it.** netsurf.log
  grows at ~32 KB/s, the old tail step, so a backlog went out at exit as
  one unpaced burst and overflowed the receiver's socket buffer. Pacing and
  a 64 KB/s tail fixed it. The cost is 450 pacing pauses (≈0.9 s) over a
  64 s autotest.
- **What the mirror costs the measurements (simulator):**
  - Frame times are unchanged: the mirror sends between frames.
  - Page-load averages rise by **≈7 ms** (160 → 167 ms in every pass), from
    the log lines and netsurf.log tails that land during loading.
  - All four passes pay it alike, so pass-vs-pass comparisons still hold.
  - For absolute load times on the device, put `off` in `netlog.cfg`.
- **Windows side:** the receiver ran under the PC's own Python 3.12.10
  (bound to 127.0.0.1, so no firewall prompt). It answered the hello, and
  all 22 files replayed to it arrived byte-identical, with matching CRCs.
- The `netlog.cfg` `off` path runs in the screenshot pass.
- Clean checkout: applied 122 + the known 2; L1 PASS; fixtures 4/4;
  101/101 + 30/30; simulator 15/15 with clip modes 14/14 identical; cross
  build `-Werror` clean; the ELF imports `sceNetInit`, `sceNetCtlInit` and
  `sceNetSendto`.

**Not verifiable without the device:**
- broadcast on real Wi-Fi, and whether the router passes it;
- Windows Firewall on the user's network profile;
- whether newlib translates sceNet's errno values (both forms are
  handled);
- sceNet start-up on 3.65 HENkaku (the result code is logged).

If nothing arrives, the memory-card copy is unaffected, and `log.txt` says
why: its `netlog:` lines.

**Hand-off.** SHA256, first 12: `VitaBrowser.vpk` `890c37c6d7bf`,
`VitaBrowser-ext.vpk` `b8b4a7746f01`, `nsvita.elf` `efac32b43687`. They
replace run 5's in `VitaBrowser-hwtest\`; run 5's stay in
`<WORK>/vitabrowser-work/hwtest-2026-09-23-run5/`. Archive:
`<WORK>/vitabrowser-work/hwtest-2026-09-23-run6/` (VPKs, ELF, SHA256SUMS,
the simulator's reference files, shots and received mirror). New in
`VitaBrowser-hwtest\`:
- `receive-results.bat`
- `vita-netlog.py`
- `reference-dumps\`: the simulator's 20 plot dumps for this build.

**Run 6 on the device** covers runs 4, 5 and 6 in one go (about 6 min):
1. On the PC, double-click **`receive-results.bat`** in
   `VitaBrowser-hwtest\`. If Windows asks whether Python may use the
   network, allow **private** networks. Leave the window open.
2. The Vita must be on the same Wi-Fi as the PC. Install the new
   **VitaBrowser.vpk** and **delete `ux0:data/VitaBrowser/`** first.
3. Launch. Within a few seconds the window should print
   `== boot … from 192.168.…` and the Vita's log lines.
4. Press □ and wait for AUTOTEST DONE. The Vita's message should say
   `results sent to <PC address>`. Then START (a clean exit sends the rest
   of netsurf.log and a goodbye).
5. As in run 5: open VT-text, compare it with
   `reference-screenshots\13-VT-text.png`, and take a screenshot. Also
   scroll VT-scroll and note the HUD numbers.
6. **Results:**
   - The receiver's folder `results\net-…\` is the run. Its
     `receiver.txt` lists every file with OK/INCOMPLETE and each dump's
     SAME/DIFF.
   - Screenshots still need copying: USB, or FileZilla/WinSCP.
   - If nothing arrived over the network, copy `ux0:data/VitaBrowser/`
     as before.

**What decides the next step:**
- **The four passes:** B vs A is the GPU clock, C vs A is CPU clipping,
  D is both.
- **Text:** VT-text on the device (run 5's checks).
- **The dump comparison.** SAME on all 20 means the device lays out and
  plots exactly like the simulator. Each DIFF points at a line to
  investigate.
- **`receiver.txt`'s loss count on real Wi-Fi.** If it isn't 0, add
  retransmission.

### Run 6 — results: none arrived; the receiver was not running (checked 2026-09-23 04:56)

What is on the PC, checked directly rather than inferred:
- `VitaBrowser-hwtest\results\` is **empty** (mtime 03:06). Nothing in
  `VitaBrowser-hwtest\` is newer than the run-6 hand-off (04:06).
- **No receiver ever ran.** Nothing is listening on UDP 45100. The only
  `python.exe` processes on Windows are the Hermes voice bridges
  (`desktop_bridge.py`, `audio_bridge.py`, started 2026-09-22 21:42).
  `receive-results.bat` was not started.
- **The firewall is not the cause.** Windows has `python.exe` (Python312)
  rules that **allow inbound on Private** and block on Public. The PC's
  only LAN interface is wired `Ethernet` at 192.168.x.x/24, category
  **Private**. So a running receiver would have been reachable, provided
  the router passes broadcast from Wi-Fi to the wired LAN (untested).
- **There is no evidence that a device run happened.** The supervising
  watchdog records that the "run 6 results are in" message it relayed was
  never actually submitted. Only the Vita's own
  `ux0:data/VitaBrowser/log.txt` could show whether the app ran and what
  its `netlog:` lines said.

**Finding: the network mirror fails silently when no receiver listens.**
- UDP needs no connection, so the Vita's sends succeed and Windows drops
  the datagrams unseen.
- A receiver started later gets only what is sent after it starts: the
  earlier log lines and dumps are never re-sent.
- On the PC nothing shows that anything was missed.
- The Vita does show it: AUTOTEST DONE says "copy ux0:data/VitaBrowser/"
  instead of "results sent to …". But that message appears only at the end
  of the run, and nothing on screen says so earlier.

Fix, next (§Run 7):
1. When a receiver answers, the Vita re-sends everything this launch has
   written so far, so a receiver started late still gets the whole run.
2. The HUD shows the mirror's state from the first frame ("net: waiting
   for PC", "net → 192.168.x.x"), so a receiver that is not running is
   obvious at launch, not at the end.

Runs 4, 5 and 6 remain **unmeasured**. The run-6 VPKs in
`VitaBrowser-hwtest\` stay valid until run 7's replace them.

## Run 7 — a late receiver still gets everything (patch 40)

This fixes run 6's silent failure (above).

**Patch 40:**
- **Catch-up:** when a receiver first answers, the Vita re-sends this
  launch's files from the start: `log.txt` (read back from the card), every
  finished plot dump and marker, and `netsurf.log`, re-tailed from its
  start at the usual pace. The hello repeats every 3 s, so a receiver
  started at any point before the app exits gets the whole run.
  A receiver that was already listening gets the same bytes at the same
  offsets again, which changes nothing.
- **HUD:** the bottom line shows `net waiting for PC`, `net <PC address>`,
  `net no network` or `net off` from the first frame. A receiver that isn't
  running is visible at launch.
- **Receiver:** losses are counted from the first datagram it heard;
  anything earlier matters only if the re-sent files come out incomplete,
  and `receiver.txt` checks each file.

**Verified on the host:**
- `run-vita-sim.sh` now starts the receiver **15 s late**, as a stand-in
  for run 6's receiver that never started. By then about 800 datagrams had
  gone to nobody. The receiver's first answer got 26 KB of `log.txt` and 17
  finished files re-sent. Result: **23/23 files byte-identical, 0 lost
  after joining**.
- **Mutation:** with the catch-up disabled, the same test fails with
  **18 of 23 files missing or incomplete**.
- Clean checkout: applied 123 + the known 2; L1 PASS; fixtures 4/4;
  101/101 + 30/30; simulator 15/15, clip modes 14/14. The dumps are
  identical to run 6's.
- The cross build needed one fix: GCC 15's `-Wformat-truncation` counts a
  row of a 2-D array as the whole array, so the path now uses `%.63s`.
  The host compiler did not warn.

**Hand-off.** SHA256, first 12: `VitaBrowser.vpk` `963b53636073`,
`VitaBrowser-ext.vpk` `e7d0d958613e`, `nsvita.elf` `7c808fb35289`. In
`VitaBrowser-hwtest\` with the updated `vita-netlog.py`. Archive:
`<WORK>/vitabrowser-work/hwtest-2026-09-23-run7/`.

**Run 7 on the device** is run 6's procedure, with a check at launch:
1. Double-click `receive-results.bat`. The window must say
   `listening on UDP 0.0.0.0:45100`.
2. Install the new VPK, delete `ux0:data/VitaBrowser/`, and launch.
3. **Look at the HUD.**
   - `net 192.168.x.x` (this PC's wired address) means it works.
   - `net waiting for PC` for more than a few seconds means the broadcast
     is not reaching the PC. Either the router does not pass broadcast
     from Wi-Fi to the wired LAN, or the Vita is on another network.
     Write the PC's address into `ux0:data/VitaBrowser/netlog.cfg`
     (`192.168.x.x`, set once via VitaShell) and relaunch.
   - `net no network` means the Vita's Wi-Fi is off.
4. Then as in run 6: □, AUTOTEST DONE, START; a VT-text screenshot.

Everything is still on the memory card whatever happens to the network.

## Run 8 — http and https: libcurl on mbedTLS (patches 41–42)

Phase 1's networking item: pages from the web, not only from `app0:`.

**The TLS stack.** vdpm offers two builds of curl:
- `curl`: 8.17 on **OpenSSL 1.0.2**, end-of-life and without TLS 1.3;
- `curl-mbedtls`: **8.22.0 on mbedTLS 3.6.5**, the current LTS, with
  TLS 1.3.

The build uses `curl-mbedtls`, installed with vdpm (userspace, no sudo).
NetSurf's curl fetcher already works without OpenSSL: it detects the
backend at start-up, and its OpenSSL hooks only add certificate-chain
display. So `NETSURF_USE_OPENSSL` stays off.
- **Entropy:** the Vita has no `/dev/urandom`. vitaSDK's mbedTLS patch
  reads entropy through newlib's `getentropy()`, which calls
  `sceKernelGetRandomNumber`, checked in the library objects.
- **Certificates:** vitaSDK's libcurl defaults to the firmware's CA list,
  `vs0:data/external/cert/CA_LIST.cer`, which on 3.65 dates from 2017.
  The frontend points NetSurf's `ca_bundle` at `app0:/res/ca-bundle.pem`
  instead: Mozilla's roots as extracted by curl, **2026-08-13, 121 roots**,
  pinned by date and SHA256 (`tools/fetch-certs.sh`; MPL 2.0 data,
  bundled unmodified). The VPK grows to 11.6 MB.
- **Network start-up** moved to its own module, `vita/net.c`, called once at
  boot for curl and the diagnostics mirror alike. Before, it lived in
  netlog.c, so `netlog.cfg` `off` would have left curl without a network.
  The sceNet pool is now 1 MiB.

**Patch 41 (core, upstreamable).** `fetch_curl_register()` passed
`CURLOPT_VERBOSE` an `int`. libcurl 8.x's GCC type checks reject that
under `-Werror`. It is now `0L` / `1L`, like every other option in the
file.

**Patch 42 (frontend).**
- curl is on, and `ca_bundle` defaults to the bundled file.
- **Network pages** follow the 15 bundled ones. The defaults are
  `http://example.com/` and `https://example.com/`;
  `ux0:data/VitaBrowser/nettest.txt` (`name url` per line) overrides them.
- L/R reach them, and a new **autotest pass N** times and dumps them.
- The timing passes A–D stay on bundled pages, so network time never
  mixes into the clip and clock comparison.

**The host now runs the Vita's TLS stack too.**
`tools/build-host-curl.sh` builds mbedTLS 3.6.5 and curl 8.22.0 from the
tarballs pinned in vitaSDK's own VITABUILDs. It uses the same `config.py`
settings and the same cmake options, minus the Vita-only ones. vitaSDK's
mbedTLS patch only adds `__vita__` branches, so nothing else differs. The
simulator's netsurf.log confirms the stack in use:
`libcurl/8.22.0 mbedTLS/3.6.5`, `ca_bundle: 'app0:/res/ca-bundle.pem'`,
`cURL not linked against openssl`.

**Verified on the host.** `run-vita-sim.sh` starts a local server
(`tools/vita-sim/httpd.py`) and a throwaway test CA. The simulator's
bundle is Mozilla's roots plus that CA.

| page | served as | result |
|---|---|---|
| 16 `NET-http-local` | L1 over plain http | **plots byte-identical to the bundled `01-L1-layout-basics`** |
| 17 `NET-https-local` | L1 over https, certificate signed by the test CA | **byte-identical**: mbedTLS verified the chain against the bundle |
| 18 `NET-https-rogue` | L1 over https, a self-signed certificate | **refused**: NetSurf's "Privacy error" page (asserted by title) |

- A separate simulator autotest with the **default** pages fetched the real
  `http://example.com/` (189 ms) and `https://example.com/` (263 ms) over
  the internet. The https fetch verified a public chain against the
  bundled Mozilla roots with mbedTLS, and both pages rendered ("Example
  Domain").
- Clean checkout: applied 125 + the known 2; L1 PASS; fixtures 4/4;
  101/101 + 30/30; simulator 15/15, clip modes 14/14; network mirror 28/28
  with a late receiver; the network pages as above. The cross build has
  `fetch_curl_register`, `mbedtls_ssl_handshake` and `getentropy` in the
  ELF, and `res/ca-bundle.pem` in the VPK.
- Found on the way: switching `NETSURF_USE_CURL` does not rebuild
  `content/fetch.c`, so an incremental build had no http fetcher
  (`navigate failed: 3`, `NSERROR_NO_FETCH_HANDLER`) until its object
  directory was cleared. The clean chain always builds from scratch.

**Known limits:**
- curl resolves names on the main thread (no threaded resolver in the
  Vita build), so a slow DNS lookup stalls the UI for its duration.
- There is no cookie jar and no disc cache (as before).
- A certificate error shows NetSurf's query page, but there is no way yet
  to accept an exception on the Vita.
- mbedTLS parses the 121-root bundle when curl sets up TLS. Its cost on the
  Vita's ARM shows in pass N's https load time.

**Hand-off.** SHA256, first 12: `VitaBrowser.vpk` `b5cfb75eb90f`,
`VitaBrowser-ext.vpk` `2ecbb7ec1e5b`, `nsvita.elf` `06517505e099`. They
replace run 7's in `VitaBrowser-hwtest\`. `reference-dumps\` now holds the
22 dumps of the internet-connected simulator run, including
`16-NET-http-example` and `17-NET-https-example`. Archive:
`<WORK>/vitabrowser-work/hwtest-2026-09-23-run8/`.

**Run 8 on the device** is run 7's procedure. The autotest now ends with
pass N, which needs the Vita on Wi-Fi with internet access. Then:
- **`log.txt`**: `init: net: up, ip …`, pass N's
  `NET-http-example` / `NET-https-example` lines, and `gw title: Example
  Domain` for both. "Privacy error" for https means certificate
  verification failed on the device.
- **`pass N summary`**: the load times, where https minus http is the TLS
  cost.
- **`receiver.txt`**: SAME for `16-`/`17-NET-…` against `reference-dumps\`.

This run still also measures runs 4–7, which remain pending.

## Run 9 — QuickJS, step 1: the engine on the Vita (patch 43)

This is Phase 1's JavaScript item. NetSurf itself has only Duktape (ES5.1)
and a "none" backend. The project's plan (README §5, §13.2) is MacSurf's
QuickJS: **QuickJS-ng 0.15.1, ES2023**, with MacSurf's hand-written DOM
bridge (`macsurf_qjs.c`). Step 1 puts the engine on the Vita and proves
it there, with the runaway-script and memory limits in from the first
hour (README §14.7). The bridge is step 2 (below).

**The engine source:**
- **Where from:** `tools/fetch-quickjs.sh` sparse-clones
  `mplsllc/macsurf` at the pinned revision **`55e64fa`** (the one every
  other MacSurf finding uses) and takes `quickjs-macos9/`, not
  `browser/libquickjs/`, which lacks the generated headers (doc 01 §5.3).
  The two `quickjs.c` differ in one Mac OS 9-only line.
- **Line endings:** MacSurf's classic-Mac CR endings are converted to LF.
- **`patches/quickjs/01-quickjs-cutils-posix.patch`** undoes two Mac OS 9
  edits that break non-glibc POSIX targets like vitaSDK's newlib:
  - `#include <sys/time.h>` had been commented out for every compiler;
  - `JS_ONCE_INIT` was `0` instead of `PTHREAD_ONCE_INIT`. vitaSDK's
    `pthread_once_t` is a struct, so `0` fails with "invalid initializer".
- **`tools/build-quickjs.sh`** builds `libquickjs.a` for the host
  (`$WORK/host-quickjs`) and the Vita (`vita-prefix`, 6.5 MiB with debug
  info), with MacSurf's Linux flags.
- **The MacSurf hooks inside the engine.** MacSurf instrumented
  `quickjs.c` itself:
  - every native call is counted, and 1 in 64 is timed;
  - every garbage collection is timed.

  Its Mac OS 9 frontend defines those hooks; `macos9_micros()` returns
  0 off the Mac. `vita/qjs_hooks.c` defines them here with a real
  microsecond clock (`sceKernelGetProcessTimeWide`), so the counters mean
  something.

**The probe (`vita/jsprobe.c`), shared by the host test and the Vita
autotest.** It runs 18 checks in a fresh runtime:
- **12 language checks:** private class fields; template, arrow and
  spread; destructuring with rest; `?.` and `??`; `at`, `hasOwn`,
  `findLast` and `toSorted`; BigInt; Map, Set and WeakMap; `\p{Script}`
  and case mapping; named groups and lookbehind; JSON; `Date` in UTC;
  `Error.cause`.
- **async/await:** drained through the job queue, as the browser's event
  loop will.
- **`fib(25)`:** a CPU benchmark.
- **The two limits from README §14.7**, each followed by a check that
  the runtime is still usable:
  - `for(;;){}` must be stopped by `JS_SetInterruptHandler` at the
    **250 ms** budget;
  - an allocate-forever loop must hit `JS_SetMemoryLimit`'s **32 MiB**
    cap as an `out of memory` exception inside the script.

**Verified on the host:**
- `tools/test-quickjs.sh`, under **AddressSanitizer + UBSan with leak
  detection** (MacSurf's own Layer-1 harness setup): **18/18**, no leaks,
  no UB reports.
  - The first run failed 3 checks, all mistakes in the probe: top-level
    `let` bindings leaking between evals, and a mis-escaped expectation.
    They are fixed; each check now evaluates in its own block.
- The simulator's autotest runs the probe at its end: 18/18. `fib(25)`
  takes 9 ms, the interrupt fires at 250 ms, and the 32 MiB cap is hit
  after 25 ms.
- Clean checkout: applied 126 + the known 2; L1 PASS; fixtures 4/4;
  101/101 + 30/30 + QuickJS 18/18; simulator 15/15, clip modes 14/14,
  mirror 28/28, network pages as run 8. Cross build clean: the ELF has
  `JS_NewRuntime`, `JS_SetInterruptHandler`, `vita_jsprobe_run`. The VPK
  is 14.4 MB.
- The plot dumps are unchanged, since the probe draws nothing. Run 8's
  `reference-dumps\` still apply.

**What the Vita run must show** (log.txt, at the end of the autotest):
- the `js:` lines, ending in `js: probe took … ms: 18/18 checks`;
- **`fib(25)`'s time on the Vita's ARM**, the first number for how fast
  page scripts will run there (9 ms on this PC);
- that the interrupt fires near 250 ms and the memory cap as an
  exception, on newlib and pthread-embedded rather than glibc.

A crash inside the probe would stop the run before `autotest.done`. The
log's last `js:` line then says where.

**Step 2, the DOM bridge.** It is sized by compiling MacSurf's bridge
against our patched tree:
- **Size:** `macsurf_qjs.c` is **16 803 lines**, plus
  `macsurf_qjs_audit.c` (1 071) and `macos9_js_fetch.c` (852). It
  implements NetSurf's `js_*` interface plus MacSurf's extensions
  (`js_exec_module`, `js_fire_dom_ready`/`window_load`/`script_load`,
  mutation batches, realm generations).
- **The core side is already in our stack:** `script.c` calls
  `js_set_current_script`, `js_fire_script_load` and `js_exec_module`,
  with weak stubs in `macsurf_frontend_stubs.c`.
- **It does not compile as-is:** it includes `macos9.h`, whose
  `gui_window` holds Mac Toolbox types (`WindowRef`, `ControlRef`,
  `Rect`). It reaches into `gui_window` in only 4 places.
- **It calls 41 external functions**, in five groups:
  - **Fetch:** `macos9_js_fetch_install` / `_flush`, the `fetch()` / XHR
    seam that README §13.2 calls original engineering. It is to be
    re-hosted on NetSurf's llcache or on curl.
  - **Reconvert:** relayout after DOM mutation
    (`macos9_reconvert_*`, `macos9_js_mark_dom_dirty_node`).
  - **Frontend services:** schedule, scroll-to, URL display, cache
    lookup, storage file names, the data directory.
  - **MacSurf's audit and diagnostics:** the `ms_diag_*` and
    `macsurf_qjs_emit_*` functions. They can start as log lines.
  - **Two allocation wrappers:** `macsurf_try_alloc` and
    `macsurf_try_realloc`.

So step 2 is:
1. a `vita/js/` shim layer for the 41 functions;
2. `macsurf_qjs.c` with its Toolbox header swapped for it;
3. `NETSURF_USE_QUICKJS` wiring in NetSurf's javascript Makefile, in
   place of Duktape / none;
4. fetch/XHR last.

Every piece is testable in the simulator first, against pages with
scripts.

## Run 10 — QuickJS, step 2: pages run JavaScript through MacSurf's DOM bridge (patches 44–46)

**What changed:** the Vita build now runs page scripts: QuickJS-ng
(ES2023) behind MacSurf's hand-written DOM bridge. Duktape and the "none"
backend are both out. The bridge became a NetSurf JS backend beside
`duktape/` and `none/`, selected by a new `NETSURF_USE_QUICKJS` feature
switch.

**Patch 45 — the backend, `content/handlers/javascript/quickjs/`:**
- **MacSurf's files, byte-for-byte** except CR → LF (verified file by
  file): the bridge (`macsurf_qjs.c`, 16 803 lines), its audit module,
  the fetch/XHR backend (`macos9_js_fetch.c`), the relayout driver's header,
  the live-content registry, `macsurf_dom_dispatch.c` (libdom calls as
  functions), and its portable debug/diag/timebase headers.
- **Two deliberate edits:**
  - `macos9_reconvert.c`: its registry declarations are enabled under
    `WITH_QUICKJS`.
  - `macsurf_qjs.c`: a `__vita__` stack guard (below).
- **Ours:**
  - `macos9.h` replaces MacSurf's Toolbox-laden frontend header under the
    same name. It declares only the services the bridge uses off the Mac,
    with MacSurf's own prototypes.
  - `macsurf_diag_none.c` switches off MacSurf's 2 573-line diagnostics
    store. Its ids only gate further diagnostics; checked in the relayout
    driver.
  - Three `-Wno-error` flags, for `macsurf_qjs.o` only.

**Patch 44 — core:**
- The `QUICKJS` feature switch.
- **MacSurf's live-content registry and owner-cancel, made real:** they
  were `__MACOS9__`-only, the rest getting "always live" macros. They are
  now real under `WITH_QUICKJS`, because callbacks outlive contents once
  scripts run. Death row stays Mac-only.
- **`select.c`:** the two pieces of MacSurf's deferred `cssh_select.c` the
  relayout needs (fixes899 `nscss_reset_node_data`, fixes130e).

**Patch 46 — the Vita frontend:**
- **`js_platform.c`:** the services, on the Vita's scheduler, clocks, text
  measurement, and randomness from `getentropy()` →
  `sceKernelGetRandomNumber`.
- **Main loop:** the bridge's event loop (`macsurf_qjs_pump_all`: timers,
  promise jobs, events) runs every pass, as in MacSurf.
- **`console.log`** goes to netsurf.log (`MS [js] …`).
- **Settling:** a page counts as settled only once no script-driven
  relayout is pending.

**Found and fixed on the way (all verified by the tests below):**
1. **Our patch 13 had broken every relayout after the first**, scripts or
   not. Removing MacSurf's `SITE` diagnostic block from the hand-ported
   `html.c` also removed the three lines after it:
   - `selection_reinit`;
   - **`htmlc->reflowing = false`**;
   - `had_initial_layout = true`.

   So `reflowing` stayed true forever. Every script-driven relayout was
   refused (`html_reconvert_content rc=16`, shown by temporary guard
   logging, since removed). **The mouse path also treated every page as
   mid-reformat**, so clicks would have done nothing on the device. Fixed
   in the hand-port source; patch 13 regenerated (the only patch that
   changed).
2. **With relayout finally running, the first one aborted in
   `set_libcss_node_data`**, a second cascade over nodes that still had
   node data. The fix is MacSurf's own (the `select.c` port above).
3. **`js_fire_script_load` was declared `void` in our compat shim**
   (`compat/macsurf_core_decls.h`); the real type is `unsigned char`.
4. **The compat shim's weak `macos9_schedule` was a no-op**, so MacSurf's
   deferred core callbacks never ran on the Vita. They run now.
5. **The bridge's `console.log` went to stderr**, which the Vita discards.
6. **The autotest could judge a page settled while its scripts' relayout
   was still due (400 ms debounce)**, so dumps and screenshots showed the
   page before the scripts' changes.
7. **Stack guard (safety):** off the Mac, the bridge sets QuickJS's native
   stack guard to 4 MB, "well under the 8 MB Linux main-thread stack". The
   Vita's main thread has 4 MiB *in total*, and `js_newheap` runs deep
   inside NetSurf. So deep recursion would overrun the real stack before
   QuickJS threw: MacSurf's fixes590 freeze. The `__vita__` branch sizes
   the guard like the Mac branch does, to the real headroom
   (`sceKernelGetThreadInfo`: current SP minus the stack base) less a
   512 KiB margin for the C frames beneath JS, capped at 4 MB. Logged as
   `qjs: stack guard=…`.

**fetch() and XMLHttpRequest needed no rewrite.** README §13.2 expected
MacSurf's async fetch/XHR to be bound to its discarded networking layer.
`macos9_js_fetch.c` is built on NetSurf's own `fetch_start()`, the layer
above the transport. In our build that means NetSurf's file fetcher for
`file:` and curl (patches 41–42) for http and https. It works unchanged,
proven below. "Move fetch()/XHR onto curl" was a verification, not a
port.

**Verified on the host** (simulator; clean checkout: applied 129 + the
known 2, L1 PASS, fixtures 4/4, 101/101 + 30/30 + QuickJS probe 18/18):

| page | what | result |
|---|---|---|
| 16 `JS-dom` (bundled) | inline script, createElement/appendChild, style, classList, selectors, ES2023 syntax, innerHTML, title, events, promise microtask, DOMContentLoaded, setTimeout, deep recursion → RangeError | **13/13**, laid out: the dump carries "JS: 13/13 passed" |
| 17 `JS-fetch` (bundled, `file:`) | fetch + json, XHR, async/await fetch, status/header, 404 | **5/5** |
| 21 / 22 `JS-fetch` over http / https | the same page, served locally; https via curl + mbedTLS | **5/5 each**; the server logged 4 data requests + the 404 on each port |

- Every row starts as "waiting" in the HTML, and only a working script
  turns it PASS. The simulator asserts the summaries; a run at 11/12 failed
  it.
- All 20 bundled-page dumps are byte-identical to the run-8/9 reference,
  so the scripting stack and the fixes above did not move any script-free
  page. Clip modes 16/16, mirror 32/32, network pages as run 8.
- The Vita cross build is `-Werror` clean. The ELF has the bridge
  (`macsurf_qjs_pump_all`, `js_newheap`), the registry,
  `nscss_reset_node_data` and the stack guard.

![JS-dom](img/10-run10/JS-dom.png) ![JS-fetch](img/10-run10/JS-fetch.png)

**Known gaps (the next task, "window services"):** the bridge's window
services are `__MACOS9__`-only with inert fallbacks:
- `location.href` reads `about:blank`, so `location.protocol` is empty (it
  shows on the JS-fetch page), and assigning to it does not navigate;
- `history.back/forward/go`, `scrollTo`, `scrollX/Y` and the viewport size;
- `document.title` does not reach the window (the JS side reads back fine);
- `alert`/`confirm`;
- `localStorage` persistence (Mac `FSSpec` files);
- the ES module loader.

Also by MacSurf's choice: `window` `load` is compiled out
(`MACSURF_JS_FIRE_LOAD`, fixes1022), and QuickJS's automatic GC is off
below the 96 MiB per-page heap cap (fixes593). The page's runtime is torn
down on navigation.

**Hand-off.** SHA256, first 12: `VitaBrowser.vpk` `d5ba4f62ac07`,
`VitaBrowser-ext.vpk` `e1b6e47f4ebe`, `nsvita.elf` `082c3a3eb8d4`, in
`VitaBrowser-hwtest\`. `reference-dumps\` is regenerated (24 dumps from an
internet-connected simulator run: pages 16–17 are the JS pages, 18–19
example.com), and `reference-screenshots\` has `16-JS-dom.png` and
`17-JS-fetch.png`. Archive: `<WORK>/vitabrowser-work/hwtest-2026-09-23-run10/`.

**Run 10 on the device** (it still covers runs 4–9) follows run 7's
procedure, with `receive-results.bat` running. Then:
- **JS-dom** (page 16) must read **13/13**, and **JS-fetch** (page 17)
  **5/5**. `receiver.txt` compares their dumps with `reference-dumps\`
  (SAME/DIFF).
- **netsurf.log** should have `qjs: stack guard=…` with the Vita's real
  stack room, and `MS [js] JS-dom row 13 passed`. That means deep
  recursion ended in a RangeError, not a crash.
- A crash, or no `autotest.done`, on page 16 or 17 points at the bridge
  on real hardware; the last `MS` lines in netsurf.log say where.
