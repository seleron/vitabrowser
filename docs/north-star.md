# North star: run `claude.ai/code` on the Vita

**Goal (owner-stated, 2026-09-20):** open the Claude Code web app on a
jailbroken PS Vita and use it. **v1 rendering simple pages is an accepted
waypoint, not the destination.**

This document exists so that every architectural decision can be checked
against the end goal, and so v1 does not foreclose it. It is evidence-based:
the capability table below was produced by auditing MacSurf's actual bridge
source (`frontends/macos9/javascript/macsurf_qjs.c`, 16,803 lines) at
`55e64fa` (v2.3), **not** from MacSurf's published documentation.

> **Correction to brief §6 and §13.** The brief's JS gap list — "matchMedia
> false, *Observer stubs, `<script type="module">` dropped, innerHTML reads as
> textContent" — is **stale**. Every one of those has since been fixed in
> MacSurf. An earlier assessment in this project called `<script type="module">`
> an immediate fatal blocker; that was based on the stale list and is wrong.
> The real blocker list is shorter, different, and more tractable.

---

## 1. What the target actually needs

`claude.ai/code` is a React SPA behind authentication that streams model output
token-by-token. Decomposed into engine requirements:

| # | Requirement | Why it matters |
|---|---|---|
| R1 | Execute a modern ES module bundle | the app will not boot otherwise |
| R2 | Real DOM mutation + observation | React reconciliation |
| R3 | **Streaming HTTP response delivery** | tokens arrive incrementally |
| R4 | Auth: OAuth redirect flow, cookies | reaching the app at all |
| R5 | Pass bot protection / TLS fingerprinting | reaching the app at all |
| R6 | Storage (localStorage at minimum) | session persistence |
| R7 | Enough RAM for a React runtime + transcript | ~heavy-JS class page |
| R8 | Layout: flexbox, grid, custom properties | the UI is built on them |

## 2. Audited status of each

Method: symbol and implementation audit of the bridge source. Hit counts are
indicative; "real" means a non-stub implementation was read and its fix ID
recorded. These are **shims of varying completeness**, not spec-complete
implementations — adequacy per site is an empirical question.

| Capability | Status | Evidence |
|---|---|---|
| **ES modules** (R1) | **REAL** | `fixes1117b (#265)`: `JS_SetModuleLoaderFunc` + `JS_EVAL_TYPE_MODULE`, with a normalize callback resolving relative specifiers. `html/script.c:1245` dispatches `type="module"` for **both inline and external** scripts |
| **matchMedia** (R8) | **REAL** | `fixes1114b (#265)`: "REAL matchMedia evaluator, not hardcoded false" — replaced a stub that lied `{matches:false}` to every query |
| **innerHTML read-back** (R2) | **REAL** | `fixes1168 (#262)`: real HTML serializer; the getter previously returned `textContent` |
| **innerHTML assignment** (R2) | **REAL** | `fixes846 (#167 S3)`: real HTML fragment parsing, single child-list replacement |
| **MutationObserver** (R2) | **REAL** | `fixes1235 (#167)`: own implementation delivering actual `addedNodes` across the native boundary. Previously a shared no-op returning `[]` |
| ResizeObserver / IntersectionObserver | present | 12 / 15 references; not individually verified as non-stub — **audit before relying on** |
| PerformanceObserver | **explicit no-op** | `_mkObserver` factory, documented as such |
| addEventListener, querySelector, Promise, requestAnimationFrame | present | 45 / 65 / 32 / 12 references |
| localStorage, sessionStorage (R6) | present | 10 / 6 references |
| history.pushState | present | 2 references |
| canvas `measureText` | partial | `qjs_canvas_measure_text_width` routes through the real hardware-measured font path |
| **EventSource / SSE** (R3) | **REAL (Patch 131, 2026-09-27)** | was 0 references; now a spec parser in `vita_polyfill.js` on the native slot -- see B1 |
| **WebSocket** (R3) | **ABSENT, deliberate** | only a comment: globals "stay absent until they can provide storage, transport, or byte semantics" |
| **XHR streaming** (R3) | **REAL (Patch 131, 2026-09-27)** | was: `macos9_js_fetch.c:314` set `readyState` directly to `4`. Now readyState 2/3 + `progress` per scheduler pass. `fetch()` bodies still arrive whole -- see B1 |
| IndexedDB, Cache Storage, File/FileReader, object URLs, Notifications | deliberately absent | same design rule: absent beats fake, so feature detection picks a working path |

Encouraging context: MacSurf's own fix commentary references debugging against
**Facebook's bootloader and module loader** on real hardware. They are already
targeting heavy production SPAs, not just WordPress.

## 3. The blockers that actually remain

Ranked by how hard they are, not by when you hit them.

### B1 — Streaming transport (R3). **The real blocker.**

No SSE, no WebSocket, and XHR delivers only on completion. Claude Code streams
tokens; without incremental delivery the UI either hangs until a response fully
completes or breaks outright.

**Tractability: good.** SSE over HTTP is the easy case — chunked reading plus a
line-oriented parser, and `libcurl`'s write callback is already incremental by
nature, unlike Open Transport. Much of MacSurf's all-or-nothing design is a
constraint of the networking layer **we are replacing anyway**. This argues for
building the fetch layer on `curl_multi` with a streaming write callback **from
day one**, and exposing `readyState 3` / `onprogress` / `EventSource` on top.
WebSocket is a larger job and may not be required if SSE suffices.

**Action: do not copy `macos9_js_fetch.c`'s completion-only model.** This is the
single most important v1 decision that protects the end goal.

**Status (2026-09-27, Patch 131, doc 13):** XHR streaming and `EventSource`
are done. The simulator's S5 gate (`JS-streaming`) passes 7/7 over http and
https, and the full suite exits 0. **Still open for claude.ai:** streaming
`fetch()` bodies. Modern apps read SSE through
`fetch(...).then(r => r.body.getReader())`, and `Response.body` still
resolves only at DONE. The native half is already in place
(`__xhrNativeTake` with discard), so this is the next increment: resolve
`fetch()` at HEADERS_RECEIVED with a `ReadableStream` body fed by progress
ticks. WebSocket is still absent.

### B2 — Auth and bot protection (R4, R5)

A direct fetch of `claude.ai/code` returns **HTTP 403**. Homebrew TLS
fingerprints and a nonstandard UA will be fought before rendering matters.
Partly addressable via per-host UA (MacSurf already has per-host UA and an
RFC-6265 cookie jar) and by using vita-sdk OpenSSL, whose fingerprint is far
more conventional than a hand-rolled stack. Partly not under our control.

### B3 — Memory (R7)

Materially better than the brief assumed: **365 MiB MAIN** available (extended
budget) plus **112 MiB CDRAM** for framebuffers. MacSurf's own heavy-JS figure
is 384 MB, so this is tight but no longer disqualifying. See
`phase-0/pre-phase-0-findings.md` §1.

### B4 — React itself (R2, R8)

Unquantified. With real ES modules, real MutationObserver, real innerHTML and
real matchMedia, React is no longer obviously impossible — which is a genuine
change from the brief's assessment. It remains unproven, and MacSurf's own
documentation still calls heavy SPAs "the open frontier."

## 4. What this means for v1

v1 renders simple pages. The point of this document is that **a handful of v1
decisions either preserve or destroy the end goal**, at little or no extra cost
now:

1. **Build the fetch layer streaming-first** (`curl_multi` + incremental write
   callback). Retrofitting streaming into a completion-only fetch layer means
   rewriting the JS bridge's async surface twice. — *blocks B1*
2. **Port the ES module loader path**, do not stub it. It already exists; it
   only needs re-hosting. — *preserves R1*
3. **Keep the cookie jar and per-host UA** from the start. — *B2*
4. **Ship with the extended memory budget** (`-d ATTRIBUTE2=12`) and account
   allocations from day one. — *B3*
5. **Put framebuffers in CDRAM, not MAIN.** Free headroom. — *B3*
6. **Track MacSurf upstream closely.** Four of the five capabilities the brief
   called permanent gaps were fixed by them, not us. The patch-stack approach
   (§14.4) is how that leverage keeps paying. — *B4*

## 5. Staged targets

Progressively harder pages, each a real checkpoint:

| Stage | Target | Exercises |
|---|---|---|
| S1 | a static HTML page over HTTPS | fetch, parse, layout, paint |
| S2 | a WordPress / news page | CSS cascade, images, floats |
| S3 | a jQuery-driven page | JS execution, DOM mutation |
| S4 | any ES-module SPA bundle that boots | R1, R2 |
| S5 | **a page that streams via SSE** | **B1 — the gate** (simulator: PASS, Patch 131) |
| S6 | an authenticated session behind OAuth | B2 |
| S7 | `claude.ai/code` | everything |

S5 is the one to attack early, because it is the only blocker whose cost is
dominated by a decision we make in v1 rather than by work someone else has to
do.
