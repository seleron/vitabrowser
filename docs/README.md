# VitaBrowser docs

Findings are recorded per phase, as work happens. The project brief is
`../README.md`; these documents are the evidence behind it, and where the brief
and a findings document disagree, **the findings document is newer and wins**.

| Document | What it holds |
|---|---|
| [`north-star.md`](north-star.md) | The end goal (`claude.ai/code` on the Vita), an evidence-based capability audit, the remaining blockers, and the v1 decisions that protect the goal |
| [`phase-0/pre-phase-0-findings.md`](phase-0/pre-phase-0-findings.md) | Brief §14.11 checklist items 1–5: memory budget, source audit, licensing, environment |
| [`phase-0/01-toolchain-and-desktop-build.md`](phase-0/01-toolchain-and-desktop-build.md) | Phase 0 steps 1–2: vitaSDK install, NetSurf buildsystem, desktop build status, and MacSurf's own Linux-port roadmap |

## Conventions

- Every finding cites its evidence: a file and line, a measured number, or a
  URL. Claims without evidence are marked as assumptions.
- When a finding contradicts the brief, say so explicitly and update the brief
  in place with a cross-reference. The brief must never be left self-contradictory.
- Corrections to earlier *findings* are recorded in the document that made the
  error, not silently dropped.
- Phase N findings live in `phase-N/`.
