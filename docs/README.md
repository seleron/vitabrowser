# VitaBrowser docs

Findings are recorded per phase, as work happens. The project brief is
`../README.md`; these documents are the evidence behind it, and where the brief
and a findings document disagree, **the findings document is newer and wins**.

| Document | What it holds |
|---|---|
| [`north-star.md`](north-star.md) | The end goal (`claude.ai/code` on the Vita), an evidence-based capability audit, the remaining blockers, and the v1 decisions that protect the goal |
| [`phase-0/pre-phase-0-findings.md`](phase-0/pre-phase-0-findings.md) | Brief §14.11 checklist items 1–5: memory budget, source audit, licensing, environment |
| [`phase-0/01-toolchain-and-desktop-build.md`](phase-0/01-toolchain-and-desktop-build.md) | Phase 0 steps 1–2: vitaSDK install, NetSurf buildsystem, desktop build status, and MacSurf's own Linux-port roadmap |
| [`phase-0/02-upstream-pivot.md`](phase-0/02-upstream-pivot.md) | The §14.4 pivot to upstream NetSurf, the measured MacSurf divergence, and headless `monkey` |
| [`phase-0/03-golden-plotstream.md`](phase-0/03-golden-plotstream.md) | Headless `nsmonkey` fetching live HTTPS, and the golden-plotstream test mechanism that replaces §14.3's golden images |
| [`phase-0/04-patch-stack.md`](phase-0/04-patch-stack.md) | Splitting MacSurf's divergence into 62 applying patches, and what turned out to be noise |
| [`phase-0/05-capability-reaudit.md`](phase-0/05-capability-reaudit.md) | §6 re-audited against the stack: 44 added CSS properties, `min()`/`max()`/`clamp()`, and eight stale claims |
| [`phase-0/06-engine-comparison.md`](phase-0/06-engine-comparison.md) | Both engines built and compared by plot stream: what the stack demonstrably changes (grid, tag-types, gradients, box-shadows, animation timelines) and what's a known-different dialect |
| [`phase-0/07-netsurf-port.md`](phase-0/07-netsurf-port.md) | The netsurf-side port: extending the stack to `browser/netsurf`, the build-system quirks, and per-file port decisions |
| [`phase-0/08-patched-build.md`](phase-0/08-patched-build.md) | The final link stage: a runnable patched `nsmonkey`, the stub-vs-port decision for the five frontend-entangled core files, the grid + tag-type ports (patches 23+24), the two-stop gradient plotter (patch 25), the box-shadow plotter (patch 26), the animation-timeline plotter (patch 27), and what the binary does and does not prove |
| [`phase-0/09-vita-frontend.md`](phase-0/09-vita-frontend.md) | Phase 1 item 3: the Vita frontend (`frontends/vita`, patches 29–31) — the plot contract on libvita2d proved byte-identical to monkey by fuzz, the whole patched stack cross-compiled to `nsvita.elf` + a VPK, all test pages rendered through the real frontend in a host simulator, the porting findings (a use-after-free, GCC 15, newlib gaps), and the shadow/transform clip finding and its core fix (patch 32) |
| [`phase-0/10-hardware-test-plan.md`](phase-0/10-hardware-test-plan.md) | The first real-Vita test: the diagnostics build (patch 33: crash-safe log, per-page timings, memory probe, plot dumps, autotest), the step-by-step plan, the results template, and runs 1–7 (iconv root cause, CPU clipping + GPU clock, FreeType text, results over UDP with late-receiver catch-up) |

## Conventions

- Every finding cites its evidence: a file and line, a measured number, or a
  URL. Claims without evidence are marked as assumptions.
- When a finding contradicts the brief, say so explicitly and update the brief
  in place with a cross-reference. The brief must never be left self-contradictory.
- Corrections to earlier *findings* are recorded in the document that made the
  error, not silently dropped.
- Phase N findings live in `phase-N/`.
