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

## Conventions

- Every finding cites its evidence: a file and line, a measured number, or a
  URL. Claims without evidence are marked as assumptions.
- When a finding contradicts the brief, say so explicitly and update the brief
  in place with a cross-reference. The brief must never be left self-contradictory.
- Corrections to earlier *findings* are recorded in the document that made the
  error, not silently dropped.
- Phase N findings live in `phase-N/`.
