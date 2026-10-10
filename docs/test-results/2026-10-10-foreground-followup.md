# Authorized foreground follow-up, October 10, 2026

The user explicitly authorized foreground testing after the
[background audit](2026-10-10-acceptance-status.md). Measurements use isolated
HOME/ZDOTDIR/config, temporary adhoc binaries and exact task-owned PIDs.
AC, Low Power Mode off, built-in 60 Hz Retina; power settings were not changed.
Earlier recorded results are retained rather than relabelled.

## Directory completion and real Pinyin composition

A protocol fixture printed OSC 133 prompt boundaries and OSC 134 directory
hints (`Doc` → `Documentation` / `Documents`), then accepted ordinary input.
The fixture exposed a real overlap: when the macOS Pinyin input context
composed underlined `ni hao`, the directory suffix and candidates remained
behind it at the same caret. DisplayLink and on-demand both reproduced it.
This is a protocol fixture, not a new real-zsh conformance result.

`ShellOverlayView` now suppresses directory hints while input composition
is active. `TerminalView` begins suppression with marked text and releases
it on cancellation/commit/focus clearing. Frame refreshes cannot recreate
the old hint underneath the input method. Status gutter rules stay visible.
The regression fails before the fix at both initial suppression and attempted
frame refresh (two issues); after the fix **40 tests in two input/overlay
suites pass**. Full Unit: **962 tests in 147 suites pass**, four intentional
known degenerate-target cases.

Rebuilt Benchmark SHA-256:
`4283d84160599cadf07e6c56799f54a252f00c7276b3dc13c47df7715ef6a3b6`.
Launched-app recheck shows real underlined Pinyin, candidate panel and
committed `你好` in full screen on both drivers; the overlapping directory
preview is absent during composition. Before/fixed captures are local
`/tmp/corta-final-d14/foreground-ghost-valid-*` /
`/tmp/corta-final-d14/foreground-ghost-fixed-*`. An initial scene capture
selected the separate 80-pixel fullscreen toolbar rather than the content
window; those captures are invalid and were replaced by largest-content
window captures before accepting the visual result.

## Dynamic window and fullscreen frames

Before the overlay-only correction, all three drivers (DisplayLink,
on-demand, on-demand-nosync) ran a 30 Hz colored-row/moving-stripe fixture
in windowed and native fullscreen modes. Three distinct frames per mode
were captured; inspected full-screen images have matching frame labels on
every row and an unbroken stripe, with no stale/doubled rows in those samples.
The window returns to its normal frame after leaving fullscreen.

These are compositor-window captures, not physical-panel scanout measurements.
The user explicitly answered that they did not watch the continuous animation
and cannot confirm temporal tearing. Therefore temporal tearing remains
unverified; in particular nosync is not promoted or described as tear-free.
Local images: `/tmp/corta-final-d14/foreground-{driver}-{window,fullscreen}-*.png`.

## System scheduling and residual idle wakeups

A valid 30-second System Trace attached to only the test process (PID 6825),
with twelve HID digit events followed by idle, completed successfully.
The app binary for this trace precedes the overlay-only change (SHA-256
`42e7fa41bd1fc243d0aa9105d9a9007b077a90ba553dab4f26ccfb47551a6cf7`).
Counter window after a three-second grace: **9 interrupt wakeups in
20.018284792 s = 0.449589/s**, five package-idle wakeups. CPU counter units
from the helper are uncalibrated despite its legacy `_ns` field names, so
no CPU percentage is derived from them.

Valid exports use `ThreadActivity`, `context-switch-sample` and `syscall`,
with ID/reference resolution. The conservative trace interval 8–25 s lies
after the input burst. `com.corta.terminal.reader` remains continuously
Blocked from **3.652429791 to 30.779613018 s**, for **27.127183227 s**.
Completed poll calls before that interval have two descriptors and timeout
`0xffffffff` (-1); there are no completed reader poll/read calls in idle.
The outstanding poll is not listed as a completed syscall, so ThreadActivity
is necessary rather than interpreting an empty syscall list as proof.

In 8–25 s, six `kevent_id` calls at 8.820746 / 11.819205 / 14.821272 /
17.819166 / 20.819153 / 23.819148 s have stacks through
`_dispatch_event_loop_drain_timers` and `_dispatch_kevent_worker_thread`.
Other activity involves workqueue and Mach/CoreFoundation runloop paths.
This supplies evidence of library dispatch timer activity about every three
seconds, but does **not** identify who created the timer or equate those
six calls one-for-one with all nine interrupt-counter increments. No causal
claim about a specific app callback or framework owner is made.

A separate unprofiled control with `CORTA_RENDER_METRICS=0` still reports
**12 interrupts / 20.00364475 s = 0.599891/s**, three package-idle wakeups.
Thus this control does not support a claim that disabling diagnostics removes
all residual activity. The original 250 ms PTY poll is demonstrably gone;
strict zero process wakeups is not achieved.

Trace: `/tmp/corta-foreground-final-idle-system.trace`; target-only resolved
analysis: `/tmp/corta-foreground-final-system-analysis.json`; metrics-off
control: `/tmp/corta-foreground-final-idle-metrics-off-summary.json`.
No new reader or render-loop change is justified from an unidentified timer.

## Three new default-driver four-pane flood pairs

Three alternating old → fixed-current pairs ran `testFloodFourPanes` under
Benchmark optimization, with DisplayLink on both sides. Old binary SHA-256
`3124a34d95fa751cce072dad129d210d8383b8670a6e57ad50d5b3a444b5d1ef`;
current SHA-256 `4283d84160599cadf07e6c56799f54a252f00c7276b3dc13c47df7715ef6a3b6`.
All six UI tests passed as executions; that does not pass their measured
performance gates. The latest full 600-sample ring per run is reported,
matching the existing UI harness; all rings remain in the raw attachments.

| Pair | Old CPU/GPU p99 ms | Current CPU/GPU p99 ms |
| :--- | :--- | :--- |
| 1 | 0.51 / 0.80 | 0.45 / 1.05 |
| 2 | 0.69 / 0.50 | 0.58 / 2.80 |
| 3 | 0.61 / 1.42 | 0.73 / 1.73 |

Current CPU p99 median **0.58 ms** is within the old range 0.51–0.69 ms,
but third-run 0.73 exceeds that maximum. Current GPU p99 median
**1.73 ms** exceeds the old range **0.50–1.42 ms**; the second-run
**2.80 ms** spike reproduces the previous tail concern. This comparison
**fails the GPU flood gate**. Earlier outliers are retained, not overwritten.
Native GPU execution p99 in changed round 2 is **2.30 ms**, feedback-delay
p99 **0.80 ms**, so that ring cannot be explained as only delayed callbacks.
This is not a validated cause or justification for a speculative renderer
change. Diagnostic overhead differs between old/current native timing
coverage; no instrumentation-parity claim is made.

## Activity Monitor flood proxy

A valid Activity Monitor recording spans the six paired runs. A one-second
identity watcher records only executable paths under the two task-owned
Benchmark bundles; PIDs 8290 / 8389 / 8477 / 8577 / 8658 / 8759 map to
the three old/current pairs. `activity-monitor-process-live` exports were
resolved by ID/reference and filtered to those six PIDs. Integer cumulative
on-core time and idle-wakeup fields are the basis of these values. Export
reported dylib-overlap warnings; no symbol-timeline conclusions use this
recording, and the process counter table exported successfully.

Uniform stable windows exclude each process's first five and last three
seconds; the resulting windows are 36.9–38.3 seconds, include setup/teardown
margins, and are not identical to XCTest's five four-second CPU windows.
App Nap is No throughout. CPU is cumulative on-core delta / elapsed time;
wakeups are cumulative counter delta / elapsed time. These are workload
energy proxies, **not watts or proof of equal GPU energy**.

| Pair | Old CPU % / wakeups per second | Current CPU % / wakeups per second |
| :--- | :--- | :--- |
| 1 | 322.108 / 233.070 | 321.658 / 228.783 |
| 2 | 323.448 / 230.191 | 315.802 / 225.332 |
| 3 | 323.549 / 233.431 | 317.904 / 226.301 |

No increase appears in these uniformly selected CPU/wakeup proxies.
The GPU tail gate remains failed. One/two-pane and idle/occluded evidence
from earlier runs remains separately identified by build/method. This is
not a new final-build idle/occluded Activity Monitor pair.

## Cleanup and disposition

All task-owned measurement apps and recorders exited. The original Pinyin
source was verified; both AC and Battery lowpowermode remain 0, unchanged
from this phase's saved settings. Native fullscreen transitions returned
the isolated windows before closing them.

The overlay collision is fixed and verified, but strict zero wakeups, default
GPU flood tails, scripted low-power/normal spread equivalence, and physical
continuous-screen tearing are not all established. The user did not observe
the animation, so that human confirmation is unavailable. PR #309 remains
draft, DisplayLink remains default, no issue is closed and no merge occurs.

October 11 merge follow-up: the [final validation](2026-10-11-merge-validation.md) corrects flood sampling before teardown, records three passing sustained default-driver pairs and a final-source check, matches scripted input cadence across power modes, withdraws no-sync, and attributes the three-second idle timer to Apple AGX deferred GPU setup. Historical negative results above are retained with their method limits; absolute zero process wakeups and an unperformed human panel observation are not claimed.
