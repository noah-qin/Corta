# Input and desktop follow-up for #280–#283, October 9, 2026

This follows the [background verification](2026-10-09-scrolling.md), after the
user authorized desktop measurements. Baseline is `b0917dd`; the new driver
comparison uses the same changed binary with only `CORTA_FRAME_DRIVER` varied.
[Raw distributions and allocation call tree](2026-10-09-input-followup-raw.md)
retain the results. The issues remain open and PR #309 remains a draft.

## Environment and method

Apple M5 Mac17,3, 32 GB, macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Swift
6.4; AC power, Low Power Mode off. The only detected screen was the built-in
Retina display, maximum 60 Hz, scale 2. No 120 Hz panel was available.
Configurations, HOME and ZDOTDIR were isolated under `/private/tmp`; system
power settings and production signing were unchanged.

The in-app sessions used Menlo 14, 120×40, cursor blink off, `cat`-like shell
echo, and XCTest digits. Each round typed 320 keys with requested 150 ms pauses;
XCTest overhead made the actual cadence approximately 330 ms. Each reported
ring contains 200 successful presentations. The comparison order was
DisplayLink → on-demand, repeated three times. Binary SHA-256:
`43e0420f62fe6ca1ccc247438ee46fd5263cd1488b1d82c69ce09511d876fa8a`.
Later maintenance fixed the pacing-target retain cycle, skipped clocks in the
default input hook and repaired test cleanup; the full Unit plan and D17 were
rerun on that final source. The earlier rings are not relabelled as final-source
measurements.

Typometer 1.0.1 used its original keyboard and AWT screen accessor via a small
Java launcher, 200 samples/round, 150 ms interval, pause option disabled.
Temurin 25.0.4; Menlo 18, 120×32, cursor hidden, no unrelated shell output.
Three alternating rounds used the same app binary and isolated fixtures. A
foreground guard stopped the worker if the target PID lost focus. An earlier
45-sample interrupted trial was discarded. Existing Terminal accessibility
and screen-recording permissions were used, without changing system settings.
Raw CSVs remain locally under `/tmp/corta-external-driver-accepted`.

## Latency and driver decision

| Round | In-app DisplayLink p50/p95/p99 ms | In-app on-demand p50/p95/p99 ms | Typometer DisplayLink p50/p95/p99 ms | Typometer on-demand p50/p95/p99 ms |
| :--- | :--- | :--- | :--- | :--- |
| 1 | 84.12 / 108.80 / 110.35 | 34.21 / 42.01 / 51.08 | 55.69 / 77.58 / 80.52 | 22.26 / 44.37 / 47.90 |
| 2 | 83.75 / 109.07 / 113.40 | 33.94 / 42.20 / 50.41 | 56.37 / 76.80 / 80.48 | 22.27 / 43.62 / 46.84 |
| 3 | 84.02 / 109.21 / 131.65 | 34.13 / 43.27 / 52.09 | 54.81 / 78.43 / 82.27 | 24.12 / 43.26 / 45.07 |

Both measures improve beyond one 16.67 ms frame, with lower tails. The gain is
approximately 50 ms internally and 33 ms externally: same direction and order
of magnitude, with a one-frame size difference. They are separate event and
presentation instruments; the older #279 calibration offset is not subtracted
from these sessions. #279 is now closed and its baseline remains in
[the cross-terminal record](../history/2026-10-09-CROSS-TERMINAL-RUN.md).
A person typing three alternating rounds is deferred by the user, not replaced
by either synthetic instrument.

Correlated round-one mean stages for DisplayLink are approximately 2.20 ms
keypress→output + 1.29 echo→main + 48.98 main→frame + 33.36 frame→glass =
85.83 ms. On-demand gives 2.33 + 0.93 + 0.36 + 30.64 = 34.26 ms. CPU/GPU work
is already inside these segments and must not be added again. Independent
percentiles must not be summed. Replaced drawables retain their original echo
metadata and request another frame; this explains why a single callback lead
is not the whole main→glass path. `presentationSlip` compares actual time with
the target; a target alone is not evidence that a frame reached the glass.

The default link's callback lead and first-after-resume lead are both about
49.9 ms; resume→callback is about 16.4 ms, consistent with a 60 Hz period.
There is no observed additional first-tick penalty, so the conditional
hold-awake experiment was not added. The lead gate did justify on-demand.
Mixing a paused CAMetalDisplayLink with `nextDrawable` trapped twice on this OS;
crash stacks show a Swift main-executor/pointer-auth trap in `keyDown`, and do
not establish a shared-event deadlock. That mixed prototype was removed.

The retained opt-in experiment uses a separate CADisplayLink for continuous
work, acquiring `nextDrawable` only after preparation. Echo bypass requires a
paused link, input within 50 ms, and at least one refresh interval since the
last presentation; nil acquisition or a dropped render retains an owed redraw.
Every acquired drawable is presented. Synchronized output that prepares no
frame acquires none. `ondemand-nosync` was measured once on final source: 200 successful scripted
samples, p50/p95/p99 25.66/33.50/47.53 ms, mean 25.62 ms. This is not a
paired three-round result against the earlier synchronized rings, and no
fullscreen tearing acceptance was performed; it remains diagnostic only. `presentsWithTransaction` stays unchanged (D25).

**The default remains `displaylink`.** Scripted latency alone does not satisfy
the promotion gate: human rounds, Low Power Mode and visual tearing checks
remain, and the repeated flood tails below fail the experimental promotion gate.

## Floods and energy

One run per scenario, each last 600-sample ring; this is not a measured
run-to-run spread. `frameInterval` during the experiment's flood is 16.67 ms,
with approximately 16.80 ms p99 in some rings, rather than extra presentations.

| Panes | Baseline CPU/GPU p99 ms | Changed DisplayLink CPU/GPU p99 ms | On-demand CPU/GPU p99 ms |
| :--- | :--- | :--- | :--- |
| 1 | 0.17 / 0.67 | 0.21 / 0.67 | 0.31 / 0.72 |
| 2 | 0.21 / 0.74 | 0.25 / 0.74 | 0.22 / 0.71 |
| 4 | 0.53 / 2.03 | 0.48 / 2.13 | 0.63 / 3.10 |

The one-pane CPU tail and four-pane GPU tail are higher in the experimental
sample. They cannot be dismissed as within spread without repeated runs, so
no flood non-regression or default promotion is claimed.

Two valid Activity Monitor traces cover the runs. Only Corta process rows were
exported into the committed raw summary. Stable windows exclude each process's
first five and last three seconds; these process windows differ from XCTest's
five four-second CPU intervals. CPU is derived from cumulative on-core time;
idle wakeups are differences of the cumulative kernel counter. App Nap was not
reported in those windows.

| Scenario | Baseline CPU % / wakeups per second | Changed DisplayLink | On-demand |
| :--- | :--- | :--- | :--- |
| Idle | 0.0256 / 4.644 | 0.0311 / 4.450 | 0.0360 / 4.609 |
| Occluded | 0.0457 / 5.181 | 0.0389 / 4.644 | 0.0325 / 4.633 |

CPU remains near zero. **Process wakeups are not zero.** The existing reader's
250 ms poll stop-check is consistent with this order of wakeups, but this is
an inference, not an attributed stack trace. No claim is made that the typing
burst reaches zero process wakeups. Flood CPU/wakeups are in the raw record;
the windows include setup and teardown margins and do not replace a repeated
energy comparison. Thermal and battery-mode acceptance remains unmeasured.

## Allocations and regressions

The original CLI rights failure was overcome using task-owned Terminal launch
and temporary profiling binaries ad hoc signed with `get-task-allow`; no
production entitlements or system permissions changed. `corta-bench
--scroll-allocations` warms 100k×120 history with the existing `y\r\n` corpus,
then feeds for 30 seconds without a snapshotter. The identical harness was
compiled against baseline and changed sources.

Valid changed trace: 30.819 s, 2388 one-MiB batches in its timed phase. Selected
10.300–20.300 s, All Allocations call tree: **2,169,772 allocations**, exclusively
two `Grid.scrollUp` array-reservation paths, **1,084,886 each**, 5297.29 MB and
3708.11 MB. These correspond to the arena and row-index arrays once per
256-row history batch. The selected stable call tree has no per-line
`Line`/`ScreenLines` allocation or trim/make-unique branch. Batch allocations
remain; this is not a claim that the whole feed allocates nothing.

The baseline positive-control trace ran 8.707 s and reported 9,576,567 call-tree
allocations, including `makeUniqueAndReserveCapacityIfNotUnique`. Its full run
includes warmup and is not an equal-duration steady-state comparison. Local
traces: `/tmp/corta-alloc-signed-after.trace` and
`/tmp/corta-alloc-signed-before.trace`; the after call-tree values are preserved
in the raw Markdown rather than committing gigabyte traces.

Final full Unit plan: **961 tests in 147 suites passed**, with four intentional
known issues from degenerate render-target parameter cases. The previous
902 core/package tests, unchanged goldens and 500k seeded fuzz result remain
valid; subsequent core-source changes only add the profiling CLI harness.
The typing-grace test now executes captured cancellation/expiry work directly,
avoiding the CI wall-clock flake without weakening its assertions. The final
current-source license checker passes 657 tracked files; the initially reused binary
contained stale image rules and was rebuilt rather than changing classifications.

Final D17 three rounds, Release 120×40 full rebuild: mean **0.740 / 0.715 /
0.770 ms**, p95 **2.839 / 2.625 / 3.195 ms**. Mean across rounds 0.742 ms;
previous baseline means 0.806 / 0.786 / 0.716 ms and p95 1.121–3.220 ms.
The spread overlaps. These final rounds are a follow-up, not a new alternating
baseline sequence.

The launched window is 1044×716 points (2088×1432 pixels), matching the
120×40 cells at 8.5×16.5 points plus pane/chrome insets; child `stty size`
reports 40 120. Upright colored output fills every row and scrolls past 100
lines. Native screenshots were inspected for nvim at line 200 with its status
line, less search and paging, tmux horizontal split and status, and htop live
updates: no stale/doubled rows were observed in these snapshots. A faulty
tmux fixture initially inherited its own startup shell and nested; rerunning
with the server shell set to `/bin/sh` fixed the fixture. Physical keycodes
composed underlined `ni hao`, then space committed `你好`. Candidate-window
placement and temporal tearing are not established by these app-only images.
With the search bar kept open, selection covered history rows 965–966;
five native wheel gestures moved the viewport back 100 lines, retaining
search highlights on the correct rows without stale/doubled text. The
selection moved out of view as expected.
The raw-APC `less -r` image fixture displayed a checkerboard at the bottom
instead of the intended document position; Kitty-in-less acceptance is not
claimed from that fixture. The baseline build produced the same bottom
placement before and after paging, so this fixture does not show a new
regression and cannot establish correct image/document placement. Images remain local under `/tmp/corta-final-d14`
and are not committed with unrelated process information from htop.

Menu paste and its cleanup pass in the final launched-app UI test. An earlier
fixture restored the same pasteboard items twice, threw during cleanup and
cleared the user's then-current clipboard. The user was informed; the contents
could not be recovered. The fixture now restores once.

Live region scroll completed a 600-frame ring (CPU p50/p99 0.84/1.16 ms, GPU
0.81/0.98 ms). The subsequent history gesture lost XCTest's helper connection;
a sampled app main thread was waiting normally in the event loop, not blocked
in rendering. The overall test failed and that XCTest history measurement is not accepted. A separate native scroll
run with foreground-PID protection completed 1400 wheel events over about
42 seconds. Its successive CPU p50/p99 rings were 0.48/1.20, 0.51/0.85,
0.50/0.85 and 0.50/0.93 ms; GPU rings were 1.27/1.75 and 1.27/1.41 ms.
It measures the full live prepare/render path, not the CPU-only shift benchmark.

## Automatic follow-up before human input

Three alternating rounds ran baseline → changed DisplayLink → on-demand for
one, two and four panes. Every original ring remains in the raw record.

| Panes | Baseline CPU/GPU p99, median of runs ms | Changed DisplayLink | On-demand |
| :--- | :--- | :--- | :--- |
| 1 | 0.10 / 0.63 | 0.13 / 0.64 | 0.22 / 0.68 |
| 2 | 0.17 / 0.78 | 0.17 / 0.77 | 0.16 / 0.76 |
| 4 | 0.34 / 1.51 | 0.28 / 1.73 | 0.44 / 4.04 |

All changed-default medians fall within the respective baseline three-run
ranges. This does **not** establish that every tail is within spread: changed
DisplayLink four-pane GPU p99 was 1.45 / 1.73 / **3.42 ms**, versus baseline
1.51 / 1.47 / 2.08. The outlier is retained. Experimental four-pane GPU p99 was **1.32 / 4.40 / 4.04 ms**, while CPU p99 was
0.40 / 0.44 / 0.49 ms. On-demand fails the flood promotion gate.
XCTest CPU time per four-second window stays close to one saturated reader
core per pane across the rounds. It is a CPU proxy, not a watts measurement
or an Activity Monitor wakeup trace.

The existing `gpu` metric spans submission to completion feedback, rather than
only GPU execution. Two diagnostic-only metrics now record Metal 4's native
`gpuStartTime`/`gpuEndTime` difference and elapsed time from GPU end to the
observation after the completion callback. Disabled metrics do not sample
these timestamps. They do not redefine or replace the original gate metric.
Identical diagnostic additions were made to the scratch baseline only.
Native GPU probe and power-pair executable SHA-256 values are
`3124a34d95fa751cce072dad129d210d8383b8670a6e57ad50d5b3a444b5d1ef`
(baseline plus diagnostic seam) and
`27af7b0fe38ba237fd0cbb16aa38d146d084ec082daf2ad73bbdea7d6d91fbad`
(changed source including GPU diagnostics).
A single four-pane probe measured baseline / DisplayLink / on-demand GPU
execution p99 **1.28 / 0.19 / 2.02 ms**, and original `gpu` p99
**1.79 / 0.79 / 3.49 ms**. On-demand drawable-wait p99 **16.29 ms** explains
most of its CPU p99 **16.45 ms** in this probe. This single diagnostic run does
not override the three original rounds. Full Unit after the diagnostic change:
**961 tests in 147 suites passed**, four known degenerate-target cases.

An accepted 40.650491-second signpost trace contains twelve target `keyDown`,
`wake`, `commit` and `gpu` intervals. From two seconds after the last keyDown
(trace time 11.303557625) through 31.303557625, **zero render commits** occur.
A separate 20.010848-second process-counter window records **96 interrupt
wakeups (4.7974/s)** and 52 package idle wakeups. Raw CPU counter units were
not calibrated and are not used as nanoseconds. The earlier no-input trace is
discarded. Render quiescence is established; zero process wakeups is not.
`TerminalSession.stopCheckMilliseconds` is 250 and its live reader waits with
that timeout. This is source evidence of polling, not a sampled attribution
of all 96 kernel wakeups. No hold-awake was introduced.

A corrected live `less -R` fixture injects a checkerboard after startup at
row 10 with cursor restoration. Native paging moves the text while the normal
Kitty placement stays fixed. This matches the [official Kitty implementation](https://github.com/kovidgoyal/kitty/blob/master/kitty/screen.c):
insert/delete-line actions deliberately do not move normal image references;
index scrolling does. A separate explicit index sequence in the live less
window moved the image up four rows, then seven more rows clipped it to two
rows at the upper margin, preserving its source crop without stretching or
duplicates. Native screenshots were inspected locally. The attempted raw less
capture was empty after termination and is not accepted as sequence evidence.
This validates the explicit index fixture, not document-aware less placement
or unsupported Unicode-placeholder behavior.

## Outstanding acceptance

Human three-round typing is explicitly deferred. Normal/Low Power Mode paired
latency, 120 Hz if a panel becomes available, flood-tail outliers and Activity Monitor energy
comparisons, zero-process-wakeup attribution, and the complete
D14 real-program/IME/windowed/fullscreen visual checklist remain gates. These
are not replaced by policy-table tests, offscreen equivalence or static images.
