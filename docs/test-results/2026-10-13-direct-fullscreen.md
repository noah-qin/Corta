# #285 Full screen without the compositor

2026-10-13. MacBook Air, Apple M5, macOS 27, built-in notched panel (2940×1912
backing pixels, 60 Hz), Xcode 27.0, `-configuration Benchmark` (`-O`), on
battery unless stated. No external display was available.

## How "direct" was read

Metal System Trace, attached to the running process
(`xcrun xctrace record --template 'Metal System Trace' --attach <pid>`), then
`xctrace export` of the `displayed-surfaces-interval` table. Each row is one
displayed surface; its **Direct to Display** column says whether the window
server presented the app's surface or composited it, and **Direct to Display
Failing Reason** sometimes says why. A frame that is composited shows the
window server's own framebuffer (three surfaces in rotation in
`display-surface-swap`).

## Step 1: Corta today

Single pane, typing, three alternating XCUI rounds each:

| Configuration | Direct frames |
| --- | --- |
| windowed | 0 of every round |
| full screen, toolbar showing | 0 of every round |

No failing reason is given: the surface is never a candidate.

## What blocks it: a stand-alone probe

A minimal AppKit + `CAMetalLayer` program clearing an opaque layer each
frame, in native full screen, one trait at a time (≈ 500 frames at 60 Hz, or
≈ 55 at one frame per 150 ms — a terminal's cadence):

| Variant | Direct |
| --- | --- |
| classic `MTLCommandQueue`, `present(drawable)` | **Yes** |
| … covering the notch band too, or leaving it out | Yes / Yes |
| … tagged sRGB, untagged, Display P3 | Yes |
| … with a visible unified-compact toolbar | Yes |
| … with `fullSizeContentView`, a nested layer-backed container, an empty subview, a hidden subview, a hidden titlebar accessory, a flipped view, `layerContentsPlacement = .topLeft`, a layer background colour, `CAMetalDisplayLink` drawables, `framebufferOnly = false` | Yes, each |
| … `cornerRadius` with no corner masked | Yes |
| **Metal 4: `MTL4CommandQueue`, `waitForDrawable` / `signalDrawable`** | **No** |
| Metal 4 render, classic queue presents the same drawable | No |
| a Metal 4 queue exists but is unused; classic render | Yes |
| **Metal 4 renders a staging texture; a classic queue copies it into the drawable and presents** | **Yes** |

So the one hard blocker is that **a drawable written by a Metal 4 command
buffer is never presented directly**, whichever queue presents it. Copying a
Metal 4 frame into the drawable on a classic queue lifts it. The notch, the
colour-space tag and a visible toolbar are not blockers.

The probe's submit → presented time at the terminal cadence (one frame per
150 ms):

| Path | p50 | p95 |
| --- | --- | --- |
| classic, direct | 21.8 ms | 22.9 ms |
| Metal 4, composited | 31.5 ms | 49.4 ms |
| Metal 4 + copy, direct | 20.0 ms | 21.2 ms |

At a continuous 60 fps all three read ≈ 33 ms: the drawable queue, not the
compositor, is the limit there.

## Corta with the spike

`CORTA_DIRECT_FULLSCREEN` (PR #321) removed the suspected blockers one at a
time. Without `present` (the copy) Corta's surface was never direct. With it:

- **Under XCUITest**, frames become candidates but the trace marks them
  `display rejected`, and the latency is worse. An XCUI-driven session cannot
  measure direct presentation; a person must type.
- **A person typing**, frames are presented directly, and the display link's
  callback lead drops from 50 ms (3 frames) to 33 ms (2 frames).
- Anything the window server must draw over the screen — the Screenshot
  toolbar's full-screen window, a notification — brings composition back for
  every app, the probe included.

### Keypress → glass, a person typing (in-app `keypressToPresent`)

Full screen, one pane, `cursor-blink = false`, 200 keystrokes per run:

| Run | p50 | p95 | p99 | max | Direct frames in trace |
| --- | --- | --- | --- | --- | --- |
| today 1 | 64.3 | 86.9 | 153.6 | 156.0 | 0 / 467 |
| today 2 | 65.6 | 113.5 | 179.7 | 184.6 | 0 / 470 |
| today 3 | 67.6 | 85.9 | 164.1 | 175.0 | 0 / 672 |
| spike 1 | 49.1 | 75.4 | 84.2 | 103.3 | 91 / 239 |
| spike 5 | 50.8 | 68.5 | 82.9 | 99.9 | 1181 / 1213 |
| spike 6 | 50.4 | 66.4 | 84.1 | 120.0 | 1273 / 1274 |

Excluded: spike 2 and 3 (no direct frame in their trace window and a 50 ms
lead — not in the spike's state, probably a notification banner the runner
posted), and spike 4 (trace window missed the direct period, although its
p50 49.0 and 33 ms lead match). p50 falls ≈ 15 ms, about one frame; p99
roughly halves.

### Keypress → glass, Typometer

Typometer 1.0.1, 200 characters, 150 ms delay, synchronous; three rounds
alternating the order, 600 samples per configuration:

| Configuration | p50 | p95 | p99 | max |
| --- | --- | --- | --- | --- |
| windowed | 53.7 | 73.2 | 79.4 | 104.4 |
| full screen today | 57.0 | 68.2 | 73.6 | 79.3 |
| full screen, direct | **50.5** | **61.5** | **67.2** | 87.8 |

Per round, direct p50 51.4 / 51.0 / 50.0 against today 58.0 / 56.0 / 56.4.
The traces show direct presentation held while Typometer captured, but the
display link's lead stayed at 50 ms in every run: while the screen is being
captured the system keeps the extra frame of lead. The external gain,
≈ 6.5 ms at every percentile, is the compositor pass alone; a person typing
also gets the lead's frame back.

## Shipped

Full screen with one pane: frames render through the staging copy
(`Metal4Backend.presentsByCopy`) and the canvas drops its corner mask
(full screen has no rounded corners). Nothing visible changes: the toolbar,
the overlays and colour stay as they are. `CORTA_DIRECT_FULLSCREEN=0`
turns it off for an A/B in any build.

## Cost, and D17

`FrameCPUBaselineTests` (`TestPlans/Release`, Benchmark `-O`, battery), this
branch against `main` at 9857ba0, alternated, three runs each:

| Build | Frame CPU avg (runs) | p50 (runs) |
| --- | --- | --- |
| main | 0.402 / 0.568 / 0.547 ms | 0.332 / 0.493 / 0.462 ms |
| this branch | 0.374 / 0.381 / 0.391 ms | 0.321 / 0.318 / 0.323 ms |

No regression on the windowed path, which this change leaves as it was
apart from one check a frame. `measurePresentByCopyCost` renders a full
183×55 grid into a 2940×1846 target — this panel's full screen — to GPU
completion, alternating the two paths, 60 frames each:

| Run | direct avg / p50 / p95 | by copy avg / p50 / p95 |
| --- | --- | --- |
| 1 | 1.091 / 1.129 / 2.400 ms | 1.950 / 1.993 / 4.178 ms |
| 2 | 1.077 / 1.070 / 2.480 ms | 1.722 / 1.826 / 3.370 ms |
| 3 | 0.998 / 1.033 / 1.337 ms | 1.831 / 1.875 / 3.577 ms |

The copy costs ≈ 0.8 ms of GPU round trip a presented frame, against the
≈ 15 ms it saves; a frame that does not change is not presented, so an idle
pane copies nothing.

## Not verified

- An external display, and a 120 Hz panel.
- Whether a masked corner alone blocks direct presentation: the probe run
  that tested it lost the foreground and is not counted. The mask is
  dropped in full screen regardless; it is invisible there.
- Energy: the copy adds one full-screen blit per presented frame; its GPU
  time is above, its power was not measured.
