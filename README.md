# VitaBrowser

Modern web browsing + downloading on a jailbroken PS Vita (enso/Henkaku).

## Status: RESEARCH COMPLETE (2026-09-20)

## The problem

- Vita: 4x Cortex-A9 @ ~533 MHz max (3 usable cores), 512 MB RAM (no paging,
  app budget ~200–330 MB), PowerVR SGX543MP4+ (GLES 2.0 only), 960x544 LCD.
- Stock browser: WebKit 531 (2010). Dead on the modern web.
- No modern browser has ever been ported to Vita (or 3DS/Switch) by anyone.

## Prior art

| Project | What it is | Relevance |
|---|---|---|
| [DownloadEnabler](https://github.com/XCage15/DownloadEnabler) | taiHEN plugin, 2017 | Enables arbitrary file downloads from stock browser to `ux0:download`. The download half is solved for stock browser. |
| [UserAgentSpoofer](https://github.com/GrapheneCt/UserAgentSpoofer) | taiHEN plugin, 2022 | Proves homebrew can hook system WebKit (`webcore`/`mini webcore`). |
| NetSurf 3DS / NetSurf PSP port | WIP native ports | Proof that small native engines work on this hardware class. |
| tenox/WRP, browservice | Web rendering proxies (headless Chromium → images + link maps) | The engine for the remote-render path. |

## Feasibility verdict

- **Port WebKit WPE**: 12–24 months, ~25% success. Killers: WebKit2 multi-process
  on no-fork/no-AF_UNIX kernel, ~70 MB engine in a 200 MB budget, no paging.
- **Port Servo**: dead (WebRender needs GLES 3.0).
- **Plugin on stock WebKit 531**: 2–8 weeks, high success, 2010 ceiling.
- **Remote rendering (chosen)**: server drives headless Chromium, Vita is a thin
  client. Only honest path to *real* modern web (JS, video, everything).
- **NetSurf-fb native port**: 2–4 months, fast for simple/offline sites.

### vita-sdk has what we need

curl, openssl, ffmpeg, freetype, harfbuzz, pixman, libpng, libjpeg-turbo,
libwebp, sdl2, vitaGL (GLES), expat, libxml2, jansson.
Missing (matters only for full WebKit port): glib/gio, cairo, pango, ICU, sqlite.

## Plan

### Phase 0 — 1-day prototype (de-risk everything)
1. Stand up WRP/browservice (headless Chromium) on a VPS or localhost.
2. Point the *stock* Vita browser at it via network proxy settings
   (plain-HTTP-from-proxy trick dodges custom root CA).
3. Judge: is image-based browsing on 960x544 pleasant?
   **Kill criteria: >400 ms input-to-photon, or text unreadable at native res.**

### Phase 1 — Native thin client (6–10 weeks, if Phase 0 passes)
- vitaSDK app (C/C++, SDL2 + vitaGL).
- Server: headless Chromium over CDP (Chrome DevTools Protocol).
- Video: H.264 960x544 stream → hardware decode via SGX/`sceAvcdec`.
- Structure over pixels: CDP returns link rects, scroll extents, focus state →
  real touch targets (dual sticks + front/rear touch), local scroll of
  pre-rendered tall bitmap, OSK text echo.
- Downloads: proxy serves files over plain HTTP → write to `ux0:download`
  (or any path). No DownloadEnabler needed for the new browser.

### Phase 2 (parallel, optional) — NetSurf-fb port
- Offline, no-server, fast on wikis/docs/forums/manga.
- Same approach as the 3DS/PSP NetSurf ports.

## Key risks

- Wi-Fi 802.11b/g (~20 Mbit real) on Vita — image/video stream must be small.
  H.264 at 544p is the right call; test actual round-trip latency on user's network.
- Privacy: everything flows through our server (it's ours — fine, but a fact).
- Vita debug tooling is printf-over-UDP: multiply dev-time estimates by ~1.5.

## Conventions

- One item → one branch → one PR.
- Vita code: C/C++ via vitaSDK toolchain (Linux). Server code: Go/Python.
- Folder: `server/` (rendering proxy), `client/` (vitaSDK app), `docs/`.
