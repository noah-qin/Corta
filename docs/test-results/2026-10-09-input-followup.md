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
Configurations, HOME and ZDOTDIR were isolated under `/private/tmp`; production signing was unchanged. Power settings were temporarily changed only
for the later power-mode pairs and restored to their original values.

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
At the time of these scripted runs, human alternating rounds were deferred by the user, not replaced
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
the promotion gate: human rounds and visual tearing checks
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

In this earlier build, CPU remains near zero. **Process wakeups are not zero.** The reader's
250 ms poll stop-check is consistent with this order of wakeups, but this is
an inference, not an attributed stack trace. No claim is made that the typing
burst reaches zero process wakeups. Flood CPU/wakeups are in the raw record;
the windows include setup and teardown margins and do not replace a repeated
energy comparison. Thermal acceptance remains unmeasured; subsequent scripted
power-mode pairs and the final reader-wakeup measurements are recorded below.

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
known issues from degenerate render-target parameter cases. The original
902 core/package tests preceded the added no-history regression. The final
903-test package rerun, unchanged goldens and rebuilt 500k seeded fuzz pass
are recorded below.
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

A live `less -R` fixture injects a checkerboard at row 10 with cursor
restoration. A valid transcript saved after quitting less contains ordinary
line feeds, with no IL/DL sequences. It exposed an existing full-screen
no-history bug: `Scrollback(limit: 0)` never increments `totalPushed`, so image
anchors stayed fixed while alternate-screen text scrolled. Full-screen scrolls
now use the explicit image movement/crop path when the history limit is zero,
including alternate screens. Normal history scrolling keeps its document
anchors. Ordinary image references deliberately stay fixed for IL/DL in the
[official Kitty implementation](https://github.com/kovidgoyal/kitty/blob/master/kitty/screen.c);
those actions were not changed.

The two parameter cases (alternate screen and zero-history main screen) fail
before the fix and pass afterward, asserting movement, fractional source
crop and complete removal. Rebuilt-app native less paging now moves the image
up four rows, reaches a two-row source crop after eleven row steps, and removes
it after thirteen; screenshots show no stretching or duplicates. The earlier
empty transcript and fixture-path failure are discarded. This validates
ordinary live image references, not unsupported Unicode placeholders.
After the no-history core fix, **743 terminal tests, 125 SFTP, 22 release-check and
13 license tests pass**, unchanged goldens and **500k seeded mutation inputs
pass again**. Final full Unit: **961 tests in 147 suites pass**, four known
issues; the 400-step renderer oracle is included.

Native nvim `j` and Control-F move the view while preserving its status line.
View ▸ Bigger reaches the pane: child dimensions change **40×120 → 37×113**;
Command-minus restores **40×120**, with upright text at both sizes.
The final Pinyin candidate fixture initially remained plain Latin after a
TIS-only switch. Activating the input context with [Control-Space](https://support.apple.com/guide/chinese-input-method/switch-to-a-chinese-or-cantonese-input-source-cim119a8d473/mac)
and sending HID keycodes without Unicode produces underlined `ni hao`, with
the candidate bar directly below the composing cell, then space commits
`你好`. Compositor-region capture includes the actual candidate bar, unlike
an app-window-only image. The failed Latin-only attempts are not accepted as
IME evidence. Original Pinyin input source is restored; no IME setting or
permission was changed.

No-history correction native/D17 executable SHA-256:
`95a8cec1fcb2eb460dd8ab82ff88dc66659cde0daafc284b240725912b8052b5`.
D17 after the no-history correction, three Release 120×40 rounds: average **0.759 / 0.723 /
0.806 ms**, p95 **3.881 / 2.877 / 3.468 ms**. Across-round mean **0.763 ms**
versus baseline **0.769 ms**, overlapping mean ranges; the larger individual
p95 values are retained. Earlier input, power, allocation and flood rings
precede only this isolated no-history image-path correction and are not
relabelled as measurements of the final executable.

## Scripted power-mode pairs, October 9–10

Same diagnostic executables as the native GPU probe; DisplayLink driver in
both builds, isolated Menlo 14 120×40 fixture, 320 requested 150 ms key events,
200 successful presentations per reported ring. Three rounds alternate
normal baseline → normal changed → Low Power baseline → Low Power changed.
This tests the shipping policy, separately from the older same-binary
DisplayLink/on-demand experiment. Normal rings in this session must not be
substituted into that earlier table.

The original Battery setting was Never (`lowpowermode=0` for Battery and AC).
The temporary UI setting Only on Power Adapter enabled AC mode alone. Changed
app summaries independently report the actual `lowPower` flag. Settings are
restored in `finally` and read back after the final pair. No password or global
permission change was needed.

An initial Xcode process trapped before launching the changed low-power app.
Its report identifies libmalloc free-block corruption in DVT/Touch Bar
notification handling. No app result is accepted from that launch. The whole
first low-power pair was rerun; its first valid baseline-only trial remains a
separate diagnostic (p50/p95/p99 187.39/414.87/431.83 ms), outside the paired
table. Normal pair 1 stayed valid and was not repeated.

Requested input pauses are identical, but XCTest overhead differs by power
mode (mean key-to-key 0.330–0.333 s normal, 0.409–0.412 s low-power). This
can affect timing phase and prevents claiming identical input cadence or a
human result. The changed low-power p50 is lower than the normal range, not
statistically equal to it. The policy change removes the large before/after
low-power penalty in these scripted sessions. Physical human input remains
required. Continuous target intervals are reported separately from actual
keypress-to-present distributions; a 16.67 ms target interval is not proof
that every frame reaches the glass at 60 Hz.

| Round | Normal baseline p50/p95/p99 ms | Normal changed | Low Power baseline | Low Power changed |
| :--- | :--- | :--- | :--- | :--- |
| 1 | 108.49 / 133.11 / 149.38 | 107.34 / 133.68 / 149.70 | 185.50 / 419.17 / 435.03 | 64.08 / 132.59 / 136.90 |
| 2 | 108.44 / 132.08 / 149.85 | 106.99 / 133.60 / 150.03 | 186.64 / 413.46 / 433.58 | 66.80 / 133.63 / 136.83 |
| 3 | 108.48 / 132.45 / 149.62 | 107.23 / 131.88 / 148.78 | 188.54 / 416.34 / 420.99 | 64.02 / 126.43 / 136.79 |

All three changed low-power continuous target-interval rings had p50/p99
**16.67 / 16.67 ms**, mean 16.92 ms and maximum 66.66 ms. The occasional
larger target gap is retained; these timestamps do not establish actual
presentation cadence. Normal p50 medians are baseline **108.48 ms**, changed
**107.23 ms**. Normal tail ranges overlap, but changed median p95 is 1.15 ms
higher and median p99 0.08 ms higher; no assertion of identical distributions
is made. Low-power p50 medians are baseline **186.64 ms**, changed **64.08 ms**.
Both Battery and AC `lowpowermode` were read back as zero after restoration.


## Explicit PTY close wakeup, October 10

The four-per-second reader timeout was replaced with an indefinite readiness
wait and a lazy, parent-only close-notification pipe. Closing signals one
nonblocking byte, with concurrent/repeated signals guarded. Both pipe ends
use the existing descriptor leases: an in-flight wait owns its number until
it observes close, preventing descriptor reuse races. CLOEXEC plus the spawn
close-by-default policy prevent child inheritance. Creation failures close
both new handles and report the existing I/O failure. There is no new timer.

The deterministic kernel test closes concurrently after the poll lease is
held, verifies readiness and that the number stays valid inside the lease.
The existing 25-cycle descriptor-leak test now creates the wakeup handles in
each cycle. Full package: **744 terminal + 125 SFTP + 22 release-check + 13
license = 904 tests passed**; the rebuilt **500k seed-1 fuzz** passes. Full
Unit: **961 tests in 147 suites passed**, four known degenerate-target cases.
The duplicated descriptor documentation stays byte-identical; SFTP runtime
behavior is unchanged.

| Driver | Profiled 20 s interrupt wakeups / second | Without profiler | Render commits after two-second grace |
| :--- | :--- | :--- | :--- |
| Default DisplayLink | 10 / 0.500 | 8 / 0.400 | 0 |
| On-demand | 11 / 0.550 | 11 / 0.550 | 0 |

Both traces contain twelve target keyDown/wake intervals. Default records
27 frame/commit/GPU intervals during the burst; on-demand records twelve
commits/GPU intervals. Each following 20-second window has **zero commits and
zero frame callbacks**. The first export used a nonexistent schema and was
empty; it was discarded, then exported using the actual `OSSignpostIntervals`
schema from the TOC. Zero counts are calculated from traces that contain the
input burst, not from an empty export.

Original process wakeups were 96 over 20.010848 s (4.7974/s). They are now
approximately **0.4–0.55/s**, including unprofiled controls, a substantial
reduction. They are **not strictly zero**. Residual kernel wakeups are not
causally attributed and are not relabelled as render wakes. Raw CPU counter
units remain uncalibrated; no nanosecond-based CPU percentage is inferred.

Three final functional-build normal-mode pairs alternate baseline → changed
DisplayLink, 320 scripted keys and 200 successful presentations per ring,
AC power and Low Power Mode off. Executable SHA-256:
`42e7fa41bd1fc243d0aa9105d9a9007b077a90ba553dab4f26ccfb47551a6cf7`.

| Round | Baseline p50/p95/p99 ms | Changed default |
| :--- | :--- | :--- |
| 1 | 103.08 / 118.64 / 119.55 | 105.32 / 118.92 / 149.06 |
| 2 | 104.19 / 118.57 / 131.51 | 105.75 / 118.32 / 119.24 |
| 3 | 104.88 / 118.88 / 119.53 | 104.77 / 119.07 / 119.56 |

Median p50 **104.19 → 105.32 ms**, a 1.13 ms increase versus a 1.80 ms
baseline run range; p99 medians **119.55 → 119.56 ms**. The first changed p99
**149.06 ms** exceeds every paired baseline p99 and is retained, despite the
near-equal medians. No assertion that every tail is within spread is made.
The earlier three power-mode pairs and the same-binary driver experiment
precede this idle-reader optimization; they remain explicitly earlier-build
measurements. Renderer code and the offscreen D17 path are unchanged by it.


## Human driver comparison, October 10

The user physically typed in six alternating isolated launches, DisplayLink
then on-demand, three pairs. Same current functional binary after the PTY
close-wakeup change: SHA-256
`42e7fa41bd1fc243d0aa9105d9a9007b077a90ba553dab4f26ccfb47551a6cf7`,
source commit `69fd44c`. Menlo 14, 120×40, blink off, shell `cat` discarding
input after terminal echo; lowPower=false, built-in 60 Hz panel. The user
subsequently clarified that the preceding whole batch was unplugged. Its
earlier AC label was incorrect: these are reported battery-powered sessions,
without continuous power-state capture, and are supplemental rather than
verified mains acceptance. No
scripted keystrokes were sent. Each launch was requested to receive about
300 individually pressed digits. Exact physical key count/cadence was not
recorded; each produced at least one complete 200-presentation ring.

The first complete ring from each launch is the comparison; all subsequent
rings are retained below as supplemental data, without picking the best.
At launch verification of the sixth session, a short Latin letter sequence
was already visible before the final digit instruction. These inputs are
not separated or discarded; this is a mixed ordinary-key input limitation,
so a digits-only claim is not made.

| Pair | DisplayLink p50 / p95 / p99 ms | On-demand p50 / p95 / p99 ms |
| :--- | :--- | :--- |
| 1 | 63.11 / 82.81 / 145.49 | 38.02 / 60.31 / 66.58 |
| 2 | 68.27 / 86.17 / 176.71 | 38.25 / 57.89 / 66.73 |
| 3 | 68.61 / 84.44 / 171.45 | 36.40 / 57.59 / 67.36 |

In these reported battery-powered sessions, median p50 improves **68.27 → 38.02 ms**, 30.25 ms (more than one
60 Hz frame). Every paired p95/p99 improves. This supports the latency
direction of the scripted/external measurements, but does not override
the failed experimental flood gate or pending visual/energy acceptance.
The first old-version human power baseline was likewise completed unplugged
and retained as supplemental, to be repeated on confirmed mains.
The six test processes were closed individually and the original Pinyin
input source restored. The separate human old/new power-policy comparisons
are recorded in the following section.


## Human mains and Low Power policy pairs, October 10

Twelve human launches completed three old/new pairs under normal mains power,
then three old/new pairs under Low Power Mode on mains. The user personally
changed Battery settings to Only on Power Adapter before the low-power series.
Each launch used DisplayLink, Menlo 14, 120×40, blink off, isolated config,
and shell echo; the first complete 200-presentation ring triggered automatic
save/close. No synthetic keystrokes were sent. Both launch/end snapshots of
all twelve sessions report AC Power. Power was not continuously monitored.
Low-mode setting snapshots show AC lowpowermode=1, Battery=0; changed-app
rings report lowPower=true (normal rings false). Original Never setting and
Pinyin input source were restored after the series.

Old binary SHA-256: `3124a34d95fa751cce072dad129d210d8383b8670a6e57ad50d5b3a444b5d1ef`
(baseline `b0917dd`). Current functional binary:
`42e7fa41bd1fc243d0aa9105d9a9007b077a90ba553dab4f26ccfb47551a6cf7`
(source `69fd44c`). Normal first pair was launched individually; remaining
three normal windows and all six low-power windows were prelaunched with
blink disabled, then focused sequentially after the previous process exited.
Consequently later runs have additional inactive test processes; this is
not an identical process-count experiment. The tiny watchers check metric
files once per second. The user was instructed to type individual digits,
but short Latin text was seen during some launch verifications, including
normal-after-1 and low-before-1; exact key count/content/cadence was not
recorded. Results are mixed ordinary physical-key sessions, not digits-only
proof. Typed content is not committed.

| Mode / pair | Old p50 / p95 / p99 ms | Current p50 / p95 / p99 ms |
| :--- | :--- | :--- |
| normal / 1 | 68.32 / 84.55 / 169.47 | 68.74 / 84.16 / 175.47 |
| normal / 2 | 66.40 / 83.83 / 163.80 | 69.30 / 85.25 / 173.80 |
| normal / 3 | 68.91 / 85.45 / 168.18 | 69.02 / 83.47 / 142.45 |
| low / 1 | 184.76 / 220.41 / 232.61 | 68.17 / 82.46 / 91.35 |
| low / 2 | 183.25 / 227.51 / 243.00 | 68.33 / 84.01 / 166.93 |
| low / 3 | 184.54 / 221.09 / 234.39 | 70.28 / 86.85 / 174.71 |

Normal p50 medians are **68.32 → 69.02 ms**, a +0.70 ms difference within
the 2.51 ms old-run range. Normal old/new median p99 is **168.18 →
173.80 ms**; current first-pair p99 **175.47 ms** exceeds the old maximum
**169.47 ms**, so strict tail non-regression is not passed. Do not omit it.
Low-power p50 medians are **184.54 → 68.33 ms**; current low-power median
is within the normal old-run range (66.40–68.91 ms), and within 0.69 ms of
current normal median 69.02 ms. Current low-power range 68.17–70.28 overlaps
current normal 68.74–69.30; not every low-power round lies within that range.
All three low-power p95/p99 improve relative to their old counterparts.
This supports removal of the low-power typing penalty on this 60 Hz panel;
no 120 Hz, energy, tearing or strict tail/zero-wakeup pass is inferred.


## Human driver comparison on verified mains, October 10

Six further physical-input launches completed three DisplayLink → on-demand
pairs on the same functional PTY-wakeup binary (SHA-256
`42e7fa41bd1fc243d0aa9105d9a9007b077a90ba553dab4f26ccfb47551a6cf7`,
functional source `69fd44c`). Built-in 60 Hz, Menlo 14, 120×40, blink off,
isolated configs and shell echo. Launch, focus and completion snapshots of
every session report AC Power; AC lowpowermode=0 at launch/completion,
and all latency rings report lowPower=false. Power is sampled at those
boundaries, not continuously monitored.

All six windows were prelaunched at the user's request. Each was focused in
order after the previous process exited, with an automatic close after the
first complete 200-presentation ring. Other test processes were inactive
with blink disabled; process count therefore declines across the queue.
The same launch/close pattern applies in every pair, but does not eliminate
process-count effects. No scripted key events were sent; the user was
instructed to type individual digits naturally. Exact physical key count,
content and cadence were not recorded, so this is physical ordinary-key
input evidence rather than independently verified digits-only input.

| Pair | DisplayLink p50 / p95 / p99 ms | On-demand p50 / p95 / p99 ms |
| :--- | :--- | :--- |
| 1 | 66.38 / 107.69 / 122.48 | 36.78 / 53.06 / 59.88 |
| 2 | 68.85 / 89.78 / 174.21 | 39.45 / 60.89 / 65.17 |
| 3 | 69.21 / 84.26 / 168.50 | 39.39 / 59.59 / 66.87 |

Median p50 is **68.85 → 39.39 ms**, an improvement of **29.46 ms**
(about 1.77 frames at 60 Hz). Every paired p95 and p99 is lower; median
p95 is **89.78 → 59.59 ms**, p99 **168.50 → 65.17 ms**. This supplies
the previously missing mains human driver comparison. The earlier unplugged
series remains separately labelled supplemental. The internal improvement
agrees in direction and approximate size with the earlier external Typometer
result; it does not replace its separate build/environment limits.
All six test processes and watchers exited; the original Pinyin input source
was verified afterward. DisplayLink remains default because experimental
flood tails fail their promotion gate. Complete visual/tearing acceptance,
strict normal-policy tail non-regression, energy and zero-wakeup attribution
remain unresolved; this positive latency comparison does not pass those.

## Outstanding acceptance

Human driver typing has completed with the mixed-key limitation above. Scripted and human Normal/Low Power pairs are recorded with the limits above; mains driver pairs are also complete; strict normal tails,
120 Hz if a panel becomes available, flood-tail outliers and Activity Monitor energy
comparisons, zero-process-wakeup attribution, and the complete
D14 real-program/IME/windowed/fullscreen visual checklist remain gates. These
are not replaced by policy-table tests, offscreen equivalence or static images.
