# cs16-web — Performance Analysis (measured)

> 2026-06-18, 4-agent measured analysis against the running container. Goal: speed up
> loading + docker startup. Numbers are measured (curl, unzip -v, timed restarts), not guessed.

## The real causes (not what you'd guess)

"Loading is slow" has **three distinct causes**, only one of which is the raw download:

1. **Invisible unpack phase (perceived #1).** The upstream client downloads `valve.zip`, then
   single-threaded `JSZip+pako` inflates ~693 MB across **5057 files** and does 5057 `FS.writeFile`
   into in-RAM MEMFS. Crucially, the engine sets `#progress` opacity to **0 at *download* done —
   before the unpack even starts**. So the progress bar, our `%` caption, AND our new watchdog all
   treat "download done" as "complete" and fade out — then the heaviest phase runs with **zero UI**,
   just the pulsating logo. On localhost the download is 1.87 s but the unpack is the dominant,
   invisible wait. This is the "looks stuck/slow" feeling.
2. **No caching → re-download every time.** `valve.zip` and the content-hashed bundle are served with
   **no `Cache-Control`, no `ETag`** (only `Last-Modified`). A 372 MB body above the browser heuristic
   cache threshold + a hard refresh (`Cmd-Shift-R` sends `no-cache`) means **repeat visits re-pay the
   full 372 MB**. On office Wi-Fi (5–15 MB/s) that's 25–75 s wasted *every* time.
3. **Payload size on real networks.** 372 MB at 10 MB/s = ~37 s. ~44% of it is Half-Life content CS 1.6
   never loads.

"Docker is slow to come up" = **first-run only**: image pull (521 MB / 1.51 GB unpacked, ~52–83 s on
Wi-Fi) + one-time `valve.zip` build (~21 s). Warm restarts reach ready in **~1.7 s** — not the problem.

## Measured facts

| Metric | Value |
|---|---|
| valve.zip served | 390,266,243 B (372 MiB) / ~661 MiB uncompressed / 5057 files |
| Removable HL content (Tier A) | valve/maps 77 MB + media 50 MB + overviews 11 MB = **138 MB / 37%** |
| Removable HL sound (Tier B) | +29 MB → **167 MB / 45%** total |
| MUST KEEP | valve/halflife.wad (de_dust2 + cs_office reference it), all `*.lst` (engine crash) |
| localhost download | 1.87 s @ 208 MB/s (transfer not the local bottleneck) |
| Cache headers | **NO Cache-Control, NO ETag**; Last-Modified only; If-Modified-Since→304; Accept-Ranges: bytes |
| Unpack | single-threaded main-thread JSZip+pako, 5057 FS.writeFile, **no progress UI** |
| Image / platform | 1.51 GB, linux/386 on arm64 → QEMU (Rosetta can't help i386) |
| Warm restart → ready | ~1.7 s; first-run pull ~52–83 s + build ~21 s |
| zip -9 vs -6 | 0.06% smaller (assets pre-compressed) — not worth it; zip -1 cuts build 17 s→5-8 s |

## Prioritized speedup plan

| # | Change | Scope | Impact (measured) | Effort | Risk |
|---|---|---|---|---|---|
| **P1** | Trim `valve.zip` (Tier A+B excludes in `start.sh:71`) | repo | −167 MB / −45% download; −2808 files → big unpack cut; −RAM | S | low |
| **P2** | Show "Unpacking game files…" + gate "complete" on `__xash.running` (`web/index.html`) | repo | Kills the invisible-unpack window — the #1 *perceived* fix | S | low |
| **P3** | nginx reverse-proxy sidecar on 27016: `immutable` for hashed bundle, long max-age+ETag for valve.zip, pass `/websocket` through | repo | Repeat visit / hard-refresh: 372 MB → ~0 (304/cache) = 25–75 s saved each time | M | med |
| **P4** | `start.sh`: drop unconditional `--force-recreate`; readiness wait `--since`+timeout; `zip -1` build | repo | Fixes false-ready + infinite-hang bugs; faster builds; cleaner warm start | S | low |

**Status (2026-06-18):** all four shipped + verified.
- **P1 ✅** `valve.zip` 372 MiB → **212 MiB served (−43%, zip -1)**, all keep-files intact.
- **P2 ✅** `web/index.html` shows "Unpacking…" during the previously-blank unpack phase (3-phase playwright test).
- **P3 ✅** `proxy/nginx.conf` + `docker-compose.yml`: nginx sidecar owns 27016, injects caching, passes
  `/websocket` through. Verified: page 200, bundle `immutable`, valve.zip `public, no-cache` + **304/0-bytes**
  revalidation (repeat visit no longer re-downloads), `/websocket` → **101 + SDP offer**, range 206.
  Adversarial-review fix: valve.zip uses `no-cache` (store + revalidate) not `max-age` (which would serve a
  stale zip for up to 24h after a rebuild). macOS note: editing the bind-mounted `nginx.conf` needs a proxy
  **recreate** (not `nginx -s reload`) to take effect.
- **P4 ✅** `start.sh`: conditional `--force-recreate` (warm no-op verified), readiness `--since`+120s
  deadline+liveness (fixes false-ready + infinite-hang), proxy liveness+HTTP probe before the success banner,
  IPv4 shape validation, IMG extraction scoped to the cs16-web service (the proxy added a 2nd `image:` line),
  empty-`STARTED` guard, `zip -1`. Also fixed `prepare-client.sh` IMG extraction + empty guard.

Remaining (upstream-only): worker decompress, IDBFS unpacked-FS cache, lazy per-map loading, native arm64.

### P3 detail — the critical path
The signaling WebSocket is **same-origin** on 27016 (`new WebSocket(.../websocket)`); the proxy MUST
pass the WS upgrade through or the game never connects. 27018 (WebRTC media, TCP/UDP) is separate —
untouched. `nginx:alpine` is already on the host. Needs runtime verification (the game must actually
connect + a 2nd load must show `(disk cache)`/304).

## Upstream-only (need a fork — out of repo scope)
- Decompress off the main thread (Web Worker) — the unzip code is in the pinned bundle.
- Cache the *unpacked* FS in IDBFS so repeat loads skip re-unzip (`/rodir` is plain MEMFS today).
- True lazy/streamed per-map loading — engine needs `EAGAIN` (upstream README TODO).
- Native arm64 image — removes the QEMU tax on Apple Silicon.

## Recommended order
P1 + P2 first (biggest impact, lowest risk, files we own) → P4 (also fixes reliability bugs) → P3
(proxy, needs runtime verification of the WS path).
