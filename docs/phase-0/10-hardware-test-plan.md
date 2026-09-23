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
3. **Inline punctuation gap:** reproduce on the desktop (it shows in the
   simulator) and fix in the engine.
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
