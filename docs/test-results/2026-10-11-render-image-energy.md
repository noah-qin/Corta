# Shared Kitty pixels, render ownership and idle cursor (#291, #284, #290)

Measured 2026-10-11 on Apple M5, 32 GB, macOS 27.0.1, Xcode 27.0
(27A266a), 60 Hz panel. Baseline is commit `5a123d4`; changed tree is the
local implementation. Staging and shell files were isolated under `/private/tmp`.
No installed app preferences, login items, security policy or global settings
were changed.

## Implementation and acceptance status

- **#291:** the parent validates PNG IHDR, allocates page/Metal-aligned anonymous
  shared memory, and passes only descriptor 3 to the embedded helper. The helper
  maps before applying the unchanged `pure-computation` sandbox and writes a
  premultiplied BGRA CGContext directly into it. Stdout is exactly eight header
  bytes. Metal wraps the mapping with `bytesNoCopy`, then GPU-blits to a private
  texture; the decode scheduler performs upload outside the cache lock. Raw
  RGB/RGBA conversion writes the same storage directly. Logical and padded
  physical budgets, generation checks, ten-second deadlines and cleanup remain
  bounded. A successful helper also verifies that opening `/etc/passwd` remains
  denied. The system `shm_open` varargs ABI requires the small C system-call shim
  documented in D02.
- **#284:** main publishes value inputs through a generation mailbox; a window
  owns one serial user-interactive Thread/RunLoop, its display links and renderer
  mutation. Reader wakes go directly to that owner; AppKit feedback is coalesced.
  Font/cache commands and teardown run on the owner. Drawable dimensions come
  from the drawable texture. Geometry snapshots do not wait behind a full frame.
  Change-only shell/input overlays apply in both modes. **The default remains
  `CORTA_RENDER_THREAD=0`: the keypress acceptance gate failed.** `1` is an
  experiment and is not approved for default adoption.
- **#290:** hidden/deselected panes request utility QoS after two seconds;
  the reader applies its own pthread QoS, and writes/pastes request interactive
  before enqueue. Idle cursor ownership switches only after an actually
  presented cursorless frame; zero presented timestamps retry. The reader
  invalidates stale handoffs before a main hop. Block contents use the exact
  renderer raster; bar/underline use the renderer's stroke thickness. Animation
  uses valid discrete key times `[0, 0.5, 1]`. A visible Metal cursor frame returns
  ownership after activity. Selection/search/link/image overlays conservatively
  retain Metal blinking rather than capture an incomplete block cell.

## Large-image decode/texture experiment

A fresh standalone process generated an opaque 4096×4096 PNG, warmed its Metal
queue, then timed the actual decoder plus texture availability. Both versions
use the same helper build configuration. A 0.5 ms sampler reads
`proc_pid_rusage` physical footprint in parent and exact child PID. Values are
bytes, not RSS. This is **not** Kitty transmission-end-to-first-presented latency.
The proxy excludes parser transmission and the compositor.

| Round | Before decode + texture, ms | After mapped decode + GPU blit, ms |
| :--- | ---: | ---: |
| 1 | 70.533 | 46.729 |
| 2 | 65.497 | 43.885 |
| 3 | 65.193 | 42.717 |

Median time fell 33.0%. Parent peak increment was 285,425,904 bytes before
and 102,252,568 bytes after (272.2 / 97.5 MiB). Helper peak footprint ranges
were 201,016,040–205,243,112 bytes before and 136,151,784–136,970,960 after.
The final private texture still consumes GPU memory; this does not claim zero
image memory.

Sampling uses full UV `(0,0,1,1)`, the real image shader and a 1024×768 render
target, 5 warmups then 60 samples per variant, rotating order. The timing
boundary is submission-to-completion, matching the application's GPU metric,
not just device execution. Isolated p50 / p95 / p99, ms:

| Texture | p50 | p95 | p99 |
| :--- | ---: | ---: | ---: |
| Shared linear alias | 0.654 | 1.459 | 2.006 |
| Previous shared tiled texture | 1.131 | 2.066 | 2.097 |
| Private texture after GPU blit | 0.491 | 1.849 | 1.880 |

The private texture wins median and tails against the previous shared tiled
path in this scene. Linear's p95 was better than private here; results are not
universal texture-layout claims. An earlier single-texel test omitted the UV
rectangle and was discarded; it must not justify the storage choice.

## Reader QoS experiment

Release `corta-bench --reader-qos` and `--reader-qos --utility` apply pthread QoS
on the benchmark worker. Existing 32 MiB feed workloads retain released/held
60 Hz snapshots. MiB/s from these launches:

| Scene | User initiated | Utility |
| :--- | ---: | ---: |
| `yes`, no snapshot | 86.4 | 86.6 |
| `yes`, released snapshot | 84.8 | 85.2 |
| `yes`, held snapshot | 83.7 | 84.7 |
| 200 columns, no snapshot | 589.5 | 591.4 |
| 200 columns, released snapshot | 541.4 | 563.6 |
| 200 columns, held snapshot | 537.4 | 548.3 |

Three actual Python children write 200-column rows at 1 kHz for two seconds
under each QoS. Child write p99 was 21.5 / 23.9 / 22.5 µs (interactive),
24.2 / 22.9 / 21.6 µs (utility); no write exceeded 1 ms. Non-reading-child
1 MiB caller cost rounded to 0.0 ms under both QoS modes. This demonstrates
no observed throughput/backpressure loss for these workloads. It does not
measure watts or establish savings for `swift build` / `find`.

## Main-stall A/B (Benchmark, 8 ms every 33 ms)

The real application uses `CORTA_MAIN_STALL=8/33`, which is unavailable in
shipping Release. Paired one-pane flood runs used the same 60 Hz panel and
measurement fixture. Application metrics from 600 frames:

| Metric | Main owner | Window render thread |
| :--- | ---: | ---: |
| Frame interval p99, ms | 33.33 | 16.67 |
| Frame CPU p50 / p99, ms | 0.08 / 0.22 | 0.05 / 0.15 |
| GPU p50 / p99, ms | 0.62 / 1.58 | 0.62 / 0.76 |

320 scripted digits at 150 ms pacing, measured until the echo drawable was
presented, produced these app-stamped keypress-to-glass distributions:

| Mode | p50 | p95 | p99 | Mean, ms |
| :--- | ---: | ---: | ---: | ---: |
| Main owner | 83.69 | 132.89 | 133.84 | 88.91 |
| Window render thread | 109.70 | 132.19 | 150.42 | 105.12 |
| Thread, immediate quiet parking + autoreleasepool | 111.33 | 134.20 | 143.77 | 106.60 |

Key delivery / output medians were 1.70 / 1.79 ms on main, 1.68 / 1.77 ms
on the thread. The regression is after output, in scheduling/presentation;
removing the main wake hop alone does not meet the latency gate. The parking
experiment did not fix it. No default switch or issue closure is justified.
These script measurements omit physical HID time and are not human typing.

## Verification

- Full core: 916 tests passed (13 + 22 + 756 + 125).
- Full application Unit: 979 tests in 151 suites passed; four pre-existing
  known issues remain recorded by the suite.
- Thread Sanitizer: 23 tests in four suites passed for render ownership,
  image cache concurrency, decoder process lifetime and exact cursor capture.
  No TSan report. This is targeted coverage, not every live AppKit interaction.
- Exact block-cursor capture covers ASCII, CJK, emoji, block and box glyphs at
  1× and 2× against a crop of a full Metal frame.
- Actual-window UI: cursor settings persistence and blinking, plus quiet
  handoff/frame cessation, passed on main and thread modes (two tests each).
  The quiet test first verifies frames exist, then verifies no additional
  `cpuFrame` samples during the next three seconds (`CORTA_RENDER_METRICS_FRAMES=1`).
- Parser fuzz: 500,000 cases, seed 1, completed with no crash/hang/cap failure.
- Accessibility machine follow-up: 26 tests in two suites passed
  (`TerminalViewAccessibilityTests`, `AccessibilityMappingTests`); no listening
  or real VoiceOver navigation is claimed.
- Documentation drift: five tests passed after the measurement records were added.
- License-header check: 670 tracked source files passed; new source files also
  include the Apache-2.0/SPDX header.
- `script/build_and_run.sh --verify`: final Debug build succeeded and the
  development application launched under the isolated measurement stage.

## Thread-mode lifecycle measurements

The Release measurement plan ran four actual-window tests: two/four panes
flooding, idle CPU and open/close-window memory. Flood metrics from 600 frames:

| Scene | CPU p50 / p99, ms | GPU p50 / p99, ms |
| :--- | ---: | ---: |
| Two panes | 0.06 / 0.12 | 0.51 / 0.59 |
| Four panes | 0.15 / 0.34 | 0.38 / 0.94 |

The four-pane run began while the final Unit host was still active briefly;
these are observations, not a clean paired CPU comparison. Idle uses the
nonblinking measurement fixture: five four-second samples consumed
0.000481 / 0.003114 / 0.000412 / 0.000060 / 0.000058 CPU seconds. The separate
live cursor test above proves blinking also owes no application frames.
Five open/close iterations confirmed the window counts (2 then 1) and measured
physical-memory deltas of 262.144 / 114.688 / −32.768 / −49.152 / 16.384 kB;
post-iteration absolute memory was 104236.040–104350.728 kB. No monotonic
retention was observed. This does not prove arbitrary hours of window churn.

## D17 final Release frame baseline

The baseline archive and changed checkout each ran the existing full performance
bundle (five tests in four suites), sequentially alternating before/after on the
same machine. The report file was deleted before each run and copied only after
successful nonzero test execution. D17 retains its historical full rebuild,
120×40, 60 iterations and GPU-completion timing boundary; this is not the
application's CPU-only callback metric.

| Round | Before avg / p50 / p95 / p99, ms | After avg / p50 / p95 / p99, ms |
| :--- | :--- | :--- |
| 1 | 0.456 / 0.437 / 0.900 / 1.301 | 0.355 / 0.335 / 0.517 / 1.032 |
| 2 | 0.370 / 0.336 / 0.705 / 1.120 | 0.381 / 0.335 / 0.699 / 1.239 |
| 3 | 0.342 / 0.331 / 0.516 / 1.037 | 0.356 / 0.334 / 0.568 / 0.972 |

Median average: 0.370 ms before, 0.356 ms after. Before range 0.342–0.456,
after 0.355–0.381. No full-rebuild regression was observed; the distributions
overlap and do not support a large speedup claim.

## Outstanding gates

The [follow-up record](2026-10-11-followup.md) supersedes the earlier open
Kitty and real-producer measurement items: actual 4096 PNG presentation and
physical footprint were measured, and actual Swift-build/find producers
completed under both priorities. CPU/wakeup proxies did not demonstrate an
energy benefit; watts and whole-app Energy Impact are not established.

#284 remains opt-in. Its corrected quiet-frame parking was retested with
steady/stalled 320-key A/B; the stalled latency gate still fails. Default
adoption and full issue acceptance are not claimed. The IME candidate-anchor
fix and compact session-ended card are recorded in the follow-up, including
what actual Pinyin automation could not verify. User reported sleep/wake and
cursor visual passes without specifying owner mode. Cross-1×/2× display
movement is skipped (no second display); human VoiceOver listening/navigation
is skipped, with machine accessibility checks passing. These skips are not
passing results. The [manual operation sheet](2026-10-11-manual-acceptance-zh.md)
supplies the remaining real-input retest steps.

[Raw metric excerpts](2026-10-11-render-image-energy-raw.md) preserve the measured
rounds and test/result identifiers without the full compiler log.
