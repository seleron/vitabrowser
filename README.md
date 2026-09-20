# VitaBrowser

A native, modern-ish web browser for a jailbroken PS Vita (enso/Henkaku).
No server, no VPS — the Vita browses directly.

## Status: PLAN v2 (2026-09-20) — native engine port, no VPS

## Why this is buildable (the two proofs)

1. **netsurf-3ds** (github.com/coderman64/netsurf-3ds, 197★, releases Dec 2025)
   A *working* homebrew browser for the 3DS: full NetSurf core (libparserutils,
   libhubbub, libdom, libcss, libnsbmp/gif/svgtiny, libwapcaplet), framebuffer
   frontend, HTTPS via libcurl, on a console *weaker* than the Vita (ARM11).
   It is effectively a template: same architecture, same porting shape.
   3DS devkitPro → Vita vitaSDK, 3DS framebuffer → libvita2d.

2. **MacSurf** (macsurf.org, github.com/mplsllc/macsurf, 2026)
   Runs the NetSurf 5-lib core + **QuickJS (ES2023)** + custom TLS 1.3 on a
   1998 Power Mac G3 (G4 @ ~400 MHz, 192 MB RAM) — hardware in the same class
   as the Vita. Proven working: WordPress + jQuery 3.7, flexbox, CSS Grid (V1),
   modern JS (classes, async/await) executing natively on-device. Much of it
   was built with Claude — the exact workflow we'd use.

## Target capability (honest, not marketing)

| Works | Doesn't work |
|---|---|
| HTML5, flexbox, grid (libcss), most CSS layout | `<canvas>`, WebGL, `<video>`/`<audio>` (NetSurf core has no media) |
| QuickJS: ES2023 (let/const, classes, async/await, fetch-style XHR) | CSS animations/transitions, canvas JS APIs |
| HTTPS 1.2/1.3 (curl+openssl from vita-sdk, real CAs) | SPA frameworks needing full DOM API (React etc. — NetSurf DOM API is partial) |
| Downloads to memory card (libcurl → `ux0:/download`) | Service workers, WebRTC |
| jQuery/WordPress/wikis/forums/news/text-heavy modern sites | — |

Performance expectation: 533 MHz A9 + NEON. Simple pages ~1–3 s, heavy pages
~5–15 s. Slow compared to a phone, **a universe** compared to the stock
WebKit-531 browser which is functionally dead on the modern web.

## Architecture

```
VitaBrowser (NPXS homebrew app, vitaSDK, C)
├── frontend          Vita frontend (new, modeled on libnsfb from netsurf-3ds)
│   ├── libvita2d framebuffer (960x544) for layout/paint
│   ├── sceLibKernel threads for fetch; front/rear touch + sticks for input
│   ├── freetype + harfbuzz (vita-sdk packages) for text
│   └── download manager → ux0:/download
├── QuickJS           JS engine (port: plain C99, has ARM/NEON paths)
└── NetSurf core libs (port, mostly as netsurf-3ds did)
    libparserutils, libhubbub, libdom, libcss, libnsbmp, libnsgif,
    libsvgtiny, libutf8proc, libnsutils, libnslog, libpencil (SVG)
    + images via vita-sdk libpng/libwebp/libjpeg-turbo
    + network via vita-sdk curl + openssl (replaces netsurf-3ds's homebrew curl)
```

## Plan

### Phase 0 — De-risk spike (1–2 weeks)
1. Set up vitaSDK toolchain (vdpm), hello-world NPXS app on the Vita.
2. Cross-compile **libparserutils + libhubbub + libdom** for Vita.
3. Render a fetched page's text (no CSS yet) to the framebuffer.
   *Milestone: a real URL loads and its text appears on the Vita.*

### Phase 1 — Core browser (weeks 3–8)
4. libcss + layout + paint (port the libnsfb layout/plotters approach).
5. Images: png/webp/gif/jpg decoding.
6. QuickJS wired in (follow MacSurf's integration).
7. Downloads: libcurl to memory card + UI.
8. Chrome: URL bar, back/forward, bookmarks, OSK keyboard.
   *Milestone: daily-driver-able for wikis, forums, news, WordPress.*

### Phase 2 — Polish (ongoing)
9. CSS gaps (grid V2 details, transforms), font subsetting, memory budgeting,
   tab management, UA string, cookie jar.

## Effort

- One competent dev + AI: **~1–2 months to a solid v1** (much of it
  mechanical — netsurf-3ds did 90% of the porting work already, on a harder
  target). Vita's toolchain is *better* (curl/openssl/freetype/harfbuzz are
  off-the-shelf vita-sdk packages) and its framebuffer API is simpler.
- This is the "NetSurf on Vita" no one has shipped. First one gets the name.

## Risks

- NetSurf DOM API coverage limits heavy JS SPAs (accepted trade-off).
- No media/canvas (accepted; stock browser can't do modern web at all).
- Vita debug tooling = printf-over-UDP: budget ~1.5x on dev time.
- Memory: budget ~200–330 MB, no paging — profile early, keep page caches small.

## Conventions

- One item → one branch → one PR.
- C, vitaSDK toolchain (Linux). Reference codebases: netsurf-3ds (frontend
  patterns), macsurf (QuickJS + modern CSS integration), NetSurf upstream.
- Folders: `app/` (frontend + app), `libs/` (ported NetSurf libs, submodule'd
  where possible), `docs/`.
