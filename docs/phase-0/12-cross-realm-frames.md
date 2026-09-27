# 12 — claude.ai sign-in: cross-realm frames + postMessage (Increment 2)

Checkpoint handed from Hermes (local agent) to Claude (lynx session) on
2026-09-26. Hermes implemented the C bridge + polyfill; a reproducible
segfault in the full sim run is blocking. **Your job: find and fix the
crash, then finalize (patch 126 + commit).**

## What's done and works

Increment 1 (`window.open` stub) is committed: repo patch
`125-netsurf-window-open.patch` (commit `ff425a1`).

Increment 2 is fully implemented in the **applied tree**
(`<WORK>/vitabrowser-work/applytest/upstream/netsurf`), builds clean, but the
full 18-page sim run segfaults (see below). Changed files:

1. `content/handlers/javascript/quickjs/macsurf_qjs.c` — cross-realm
   postMessage bridge (new `## VitaBrowser: cross-realm postMessage`
   section after `qjs_set_content`):
   - `struct jsheap` gained `parent_heap` + `frame_name` (linked per realm).
   - Serialized message queue (`qjs_xrealm_msg`, `s_msg_head`/`tail`);
     **only C `char*` JSON crosses JSRuntime boundaries** — never a
     `JSValue` (hard constraint from the Vita crash post-mortems:
     fixes 861/875/888/1070/1117b).
   - Natives: `__vitaPostMessageToParent`, `__vitaPostMessageToIframe`,
     `__vitaIframeContentDocKey`, `__vitaFrameRealmName` (registered in
     `macsurf_qjs_xrealm_register`, called from the context-setup chain
     after `register_browser_globals`).
   - `macsurf_qjs_drain_xrealm()` builds a real `MessageEvent` **in C in
     the target runtime** (type/data/source/originalTarget; `event.source`
     is a stand-in object with `toString`/`postMessage`/`close` no-ops and
     a `__vitaSourceLabel` getter) and dispatches it via
     `window.dispatchEvent` in the target realm. Called from
     `macsurf_qjs_pump_all()` after the heap-count log line.
   - `js_link_frame_heaps(child, parent, name)` export (declared in
     `macsurf_qjs.h`); `destroyheap` clears other realms' dangling
     `parent_heap` back-refs before unself.
   - Includes added: `netsurf/browser_window.h` then
     `desktop/browser_private.h` (for full `browser_window` field access).
   - Forward decl of `qjs_get_node` added at the top of the xrealm
     section (it's defined further down in the file).
2. `desktop/frames.c` — includes `macsurf_qjs.h`; calls
   `js_link_frame_heaps(window->jsheap, bw->jsheap, window->name)` at both
   iframe creation sites (the `/* linking */` blocks).
3. `content/handlers/javascript/quickjs/vita_polyfill.js` — new window
   IIFE (replaces the old minimal one) with per-realm shim windows:
   `parent`/`top` shims in iframe realms (detected via
   `__vitaFrameRealmName()`), `window.frames` shim + `iframe.contentWindow`
   / `iframe.contentDocument` in the top realm. Shim `postMessage`
   JSON-serializes the payload and calls the C natives. `window.open`
   stub retained.
4. `vita_polyfill.inc` — regenerated with
   `tools/gen-vita-polyfill.py vita_polyfill.js vita_polyfill.inc`.

## Build & verify commands (proven this session)

```sh
cd <REPO>
WORK=<WORK>/vitabrowser-work tools/run-vita-sim.sh        # engine + frontend + 18 shots
# full build log: <WORK>/vitabrowser-work/vita-sim/build.log
# screenshot run cwd: <WORK>/vitabrowser-work/vita-sim/run  (VITA_SIM_PAGES=18)
# single page:  cd <WORK>/vitabrowser-work/vita-sim/run && timeout 60 \
#   <WORK>/vitabrowser-work/applytest/upstream/netsurf/nsvita-sim file:///app0:/testpages/JS-dom.html
```

## THE BUG (your task)

`tools/run-vita-sim.sh` exits **139 (SIGSEGV)** during the screenshot
phase, on the **first page** (L1-layout-basics) while "Fetching, Loading"
is showing — i.e. before/iframes exist, queue is empty. Reproduced 3x.

Already established:
- Build is clean (no compile/link errors).
- Individual page runs (L1, JS-dom, JS-fetch, JS-window) **do not crash**
  in single-page mode. Only the full 18-page run crashes.
- `node --check` passes on the new polyfill.
- Fault: wild jump, `rip≈0x58597f6bc978`, `si_addr` same value (jump to
  garbage). Binary is PIE; no gdb/sudo on this box.

### Tools left for you

- `tools/segvtrace.c` (new, in this repo) — SIGSEGV/SIGBUS/SIGABRT
  handler with maps + backtrace + RIP/RSP. Build and use:
  ```sh
  gcc -shared -fPIC -O1 -o /tmp/segvtrace.so tools/segvtrace.c
  cd <WORK>/vitabrowser-work/vita-sim/run
  LD_PRELOAD=/tmp/segvtrace.so timeout 900 \
    <WORK>/vitabrowser-work/applytest/upstream/netsurf/nsvita-sim
  # output: /tmp/segv-trace.out — read the maps section, find the
  # nsvita-sim PIE base, then: addr2line -fC -e nsvita-sim $((0xRIP - 0xBASE))
  ```
- Suggested bisect order (applied tree `<WORK>/vitabrowser-work/applytest/upstream/netsurf`;
  **do NOT `git stash`/`git checkout` — the tree is the whole uncommitted
  VitaBrowser patch stack, only touch these 4 files**):
  1. Comment out ONLY the `macsurf_qjs_drain_xrealm();` call in
     `macsurf_qjs_pump_all` → rebuild → full run. If clean, the drain
     path (even empty-queue) or a registration-time issue is the cause.
  2. Revert ONLY `vita_polyfill.js` to the pre-Increment-2 window IIFE
     (see `git -C <REPO> show
     ff425a1:patches/vitabrowser/125-netsurf-window-open.patch` for the
     prior polyfill shape) + regenerate `.inc` → rebuild → full run.
  3. If both individually clean, bisect the polyfill additions in halves
     (parent/top shims vs frames/contentWindow shims).
- Likely suspects to check first: `macsurf_qjs_xrealm_register` (runs at
  every context setup — check `JS_NewObject`/function-define failures
  aren't ignored), the polyfill IIFE (QuickJS build here may lack `Proxy`
  — `host-quickjs` has **no Proxy support**; make sure the new polyfill
  doesn't use `Proxy` — it currently doesn't, keep it that way), and any
  use of `qjs_get_node` before its definition (forward decl added —
  verify signature match `static dom_node *qjs_get_node(JSValue v)`).

## After the crash is fixed

1. Full `tools/run-vita-sim.sh` → expect **exit 1 with 0 diff failures**
   (exit 1 is the script's normal "pages differ" code, not a crash —
   check `shots/` and the log).
2. Verify the bridge with a top-level eval page: add a temp test page
   `testpages/pages/JS-xrealm.html` with an iframe (local
   `file:///app0:/testpages/` URL) that `postMessage`s parent↔child and
   logs; confirm `console.log` output in the debug log
   (`ux0:data/VitaBrowser/...` debug log under the run dir).
3. Generate the patch the way 125 was done:
   `tools/gen-netsurf-patch.py <name>` (or the same manual `git diff`
   export used for 125 — check `patches/vitabrowser/125-*` for the
   format), name it `126-netsurf-cross-realm-frames-postmessage.patch`,
   update the patch-stack doc (`docs/phase-0/04-patch-stack.md` table),
   commit in the repo: `Polyfill 126: cross-realm frames + postMessage
   (claude.ai GSI completion)`.
4. Update THIS doc: root cause, fix, final verify results, "What's
   next".

## Constraints

- No sudo. No `git stash`/`checkout` in the applied tree (full
  uncommitted stack).
- Only C `char*`/JSON may cross JSRuntimes. Never share a `JSValue`
  across realms (Vita ABA/cross-RT free crashes).
- No `Proxy` in polyfill (host QuickJS build lacks it).
- Keep the polyfill `.inc` regenerated with every `.js` change.
- Document each step here, commit per finished task in the repo.
- At a natural checkpoint, STOP with a short done/next summary.

## What's next (for the resume prompt)

1. Symbolize the segv (segvtrace + addr2line with PIE base).
2. Bisect per the 3-step plan above.
3. Fix, verify full run + JS-xrealm.html eval check.
4. Patch 126 + commit + doc update.


## Resolution (2026-09-26, Claude)

**Root cause of the SIGSEGV.** gdb (a user-local build exists:
`~/opt/gdb/gdb.sh` -- no sudo needed, so segvtrace was not required) on the
18-page run: the fault is in QuickJS's call dispatch
(`rt->class_array[p->class_id].call`) during `qjs_vita_polyfill` of the
first page's realm, on an object whose class_id (100) no runtime
registered -- freed memory. `macsurf_qjs_xrealm_register` did
`JS_SetPropertyStr(ctx, global, "__vitaFrameRealmName", f);
JS_FreeValue(ctx, f);` -- SetPropertyStr had already taken the reference,
so the global kept a freed function object and the polyfill's
`__vitaFrameRealmName()` jumped through it once the memory was reused
(single-page runs got lucky). The bisect plan was not needed.

**Also fixed before shipping** (found by review, each would have crashed or
misbehaved on first real use):
- drain: the target's global object stored as target AND currentTarget
  without references (over-released on every message); on JS_NewObject
  failure ev/w were aliased and both freed; the queue tail was recomputed
  as `&head->next` (a reply enqueued by a listener could be lost); a
  queued message could outlive its jsheap (now `qjs_xrealm_purge` in
  destroyheap).
- `__vitaPostMessageToIframe` found the child only through layout boxes
  (absent when the first message goes): now by the heap link (frame name,
  else index), layout as fallback.
- MessageEvent.data was the JSON text: now `JS_ParseJSON` in the target
  realm, and shims always stringify (strings stay strings).
- polyfill: shim `parent/top/self/frames/window` were read from `w` inside
  its own initializer (undefined), also in the window.open stub;
  `window.frames` used `new Proxy` (now index getters refreshed on use);
  `contentWindow`/`contentDocument` were defined on the prototype shared by
  every element (now iframe-only).

Note: the pre-existing getComputedStyle wrapper (patch 73) does use Proxy
and works in this build's QuickJS; the "no Proxy" rule is kept for new code.

**Verification.** `tools/run-vita-sim.sh` exit 0 (not 1: no page differs),
including the new check `JS-xrealm: XREALM: 4/4 passed` (child to parent
object, parent to child round trip, a string stays a string,
event.source.postMessage). Disarm: skipping the JSON parse makes the page
report 0/4 (the suite check fails); restored 4/4. Interaction 22/22 at the
Vita's pace; 25/25 pages identical at both paces.

**Patch:** `126-netsurf-cross-realm-frames-postmessage.patch` (5 files:
macsurf_qjs.c/.h, vita_polyfill.js/.inc, desktop/frames.c), diffed against
the tree through 125 and checked to apply there.

## What's next

1. claude.ai "Continue with Google" end to end: window.open still returns a
   same-realm stub, so GSI's popup never loads accounts.google.com. Next
   increment: a real popup = a second browser window (own realm, shown
   full-screen, closed back to the opener), whose `window.opener` is a shim
   over this same JSON bridge (opener_heap alongside parent_heap).
2. Email sign-in needs hCaptcha's invisible iframe to run: check with a
   scripted claude.ai session whether its frame now loads and posts back.
3. A device run with 125+126 folded into the next bulk hand-off (run 20).


## Increment 3 — real popups (2026-09-26, patches 127–128)

- **127:** `window.open` opens a real top-level window over its opener
  (vita/window.c window stack; created and closed from the scheduler);
  `js_link_opener` links the heaps; opener<->popup postMessage, `closed`,
  `close()`, the popup's `window.opener` / `window.close()` over the same
  JSON-only queue. `event.source` is now the receiving realm's own shim for
  the sender and `origin` is scheme://host[:port]. JS-popup.html 4/4.
  claude.ai "Continue with Google" opens accounts.google.com "Sign in to
  continue to Claude" in the popup; the email field takes typing (needed
  128's flex fix and pointer-events: none in hoisted hit testing).
- **128:** script-inserted `<script>` elements are async and fire
  load/error (they ran parser-blocking with no events, so Google's and
  YouTube's module loaders hung); flex no longer lets abspos children eat
  free space. JS-scriptload.html 4/4.

**Open:** Google's sign-in "Next" still does nothing: at load its Wiz
service `nSePib` (viewport, `_.N9a`) fails with "not a function" and every
dependant service is cancelled. The original throw site is not in the log
(Wiz rewraps it); next step is a scripted session that hooks `_.GB` /
`_.N9a` via eval to catch it. YouTube now gets past its loading skeleton
but still renders a blank feed.


## Run 20 + patch 129 (2026-09-26)

On the device the popup opened and closed as designed. Replaying the
sign-in in the simulator with a temporary QuickJS hook (print the stack at
every "not a function"; host-only, removed) found two root causes, both
fixed in 129: document.compareDocumentPosition was missing (Google's
viewport service threw; 137 dependency failures -> 0) and script-inserted
bundles ran out of insertion order. Google's modules now load cleanly.

**Still open:** tapping Next: the click reaches Google's event contract on
`<html>` (capture, trusted, button 0, email present) but no action runs
and nothing is requested. Next step: hook the contract's dispatcher
(`jsaction` handler on documentElement) in an eval session to see whether
it finds `click:cOuCgd` on the button and why the controller (`soHxf`)
does not handle it.

## Patch 130 — the event model (2026-09-27, Claude + Hermes)

Hardware run 21 replayed the sign-in: the click reached Google's event
contract but no action ran. Not a per-button bug — the engine was missing
the event model every framework's buttons are built on:

- **Tap sequence** (interaction.c): a tap now fires pointerdown, mousedown,
  focus-move, pointerup, mouseup, click, in order. mousedown needed a PRESS
  flag the click path never carried (so it never fired); pointerup/mouseup
  came after click; nothing moved focus, so `document.activeElement` stayed
  null and no focus/blur event reached a page.
- **Focus model** (vita_polyfill.js `__vbTapFocus` + `macsurf_qjs_tap_focus`):
  `element.focus()/blur()` were no-ops. A tap now focuses the focusable
  element under it (a form control even under an overlay like a floating
  label); a `<label>` hands focus to its control and toggles a
  checkbox/radio; anything else clears focus. `change` on a text field
  fires on losing focus with a new value, not per keystroke.
- **Native event interfaces** (macsurf_qjs.c `qjs_event_iface` + polyfill
  subclasses): native events carried the right constructor (a native click
  reached page code as a plain Event — `e instanceof MouseEvent` false —
  so Google's event contract dropped it), with `which`, `relatedTarget`,
  `offsetX/Y`, key names and codes; FocusEvent/InputEvent had no
  `preventDefault`; no interface had `prototype.constructor`.
- **Caret hand-over** (interaction.c): a page that relayouts on focus
  (Google's fields) rebuilt the field's box between tap and keyboard; the
  caret now goes to the same control's new box.
- **`document.currentScript`**: the getter-only polyfill accessor made the
  engine's per-script assignment throw; it is now settable.
- **`readystatechange`** at interactive + complete, and **window load**
  (compat/macsurf_config.h `MACSURF_JS_FIRE_LOAD` 1): Google's Wiz waits
  for readyState 'complete' to finish building the controller behind
  "Next"; it never came, and no page ever saw `window load`.
- **Snapshot dispatch** for document/window/`XMLHttpRequest` handlers
  (a `{once:true}` listener removing itself skipped the next).
- Also in the same tree (46): re-read `vita_window_current()` in the main
  loop after a scheduled run, so a popup that just closed doesn't leave a
  dangling `gw`.

Result (simulator, run-21 scenario): Next posts `batchexecute?rpcids=MI613e`
and Google answers ("Couldn't find this account" for the test address), as
in Chromium. `IN-events.html` (taps scripted by position) checks the whole
model; disarms of the once-snapshot (7) and caret hand-over (3, 4) fail it.

**Verification (Hermes, after Claude's weekly limit):** full
`tools/run-vita-sim.sh` **exit 0** — 27/27 interaction (IN-events
`r=ok`), 25/25 pages, 68/68 frames, 4/4 xrealm/popup/scriptload, 6/6
modules, JS-window 4/4 passes; no segv (the recurring one was the
`macsurf_storage_fname` off-by-one, commit `5a5ee52`, ASAN-verified).
