# Final render and image validation

2026-10-11, Apple M5 / 32 GB, macOS 27.0.1, Xcode 27, native 2× / 60 Hz.
This supersedes the outstanding latency and live-capture status in
[the earlier follow-up](2026-10-11-followup.md). All image results, core tests,
helper sandbox checks and session-card captures in that report still apply.

## Scope and remaining limits

The user cancelled candidate-window following after repeated real IME failures.
It remains a known limitation, not a fixed or passing feature. The additional
unverified protocol experiments were withdrawn. The independent bottom-anchored
pointer/accessibility coordinate correction remains and has round-trip coverage.
Sleep/wake and cursor appearance passed the user's manual checks, without an
explicit owner-mode distinction. Cross-display 1×/2× movement and human VoiceOver
navigation are skipped at the user's request; automated AX checks passed.
Native 1× capture cannot be performed on this single 2× display; offscreen cursor
raster tests cover both scales. The existing conservative render-thread default
remains `0`; `1` is an explicitly opt-in, measured implementation.

CPU-energy saving for occluded floods is not established. The measured CPU and
wakeup rates are recorded separately in the earlier report and do not prove an
energy reduction. Xcode's listed Power Profiler template fails on this Mac with
“The Power Profiler instrument is not supported on macOS. Record on iOS or
 iPadOS instead.” No machine settings or sandbox policy were changed. These
unmet adoption/energy criteria keep #284 and #290 open; the independent #291
image implementation has its required before/after image and memory evidence.

## Corrected input-to-glass instrumentation and quiet scheduling

An output event may arrive after the snapshot that a drawable encodes. The echo
tracker now requires the output timestamp to precede the encoded snapshot, and
never treats a drawable recycled without encoding as an echo frame. Monotonic
keypress identities also prevent a zero-time callback from resurrecting an older
keypress after a newer one completes. Three tracker regressions cover these
orderings.

Immediate quiet-frame parking had slowed echo presentation. Leaving the full-rate
link active until a positive present, on the other hand, submitted unchanged
frames that could replace the first echo drawable. While awaiting that quiet
present, the link now uses at most 15 Hz; a new reader/UI wake restores the normal
rate immediately. Continuous floods retain the normal presentation rate.

Benchmark `-O`, arm64, 320 scripted keys per scene, final 200 positive presents:

| Scene | Owner | Mean ms | p50 ms | p95 ms | p99 ms |
| :--- | :--- | ---: | ---: | ---: | ---: |
| Steady | main (`0`) | 103.93 | 105.67 | 118.95 | 120.07 |
| Steady | thread (`1`) | 66.42 | 56.56 | 117.12 | 118.60 |
| Main stall 8/33 | main (`0`) | 101.24 | 105.55 | 121.33 | 125.27 |
| Main stall 8/33 | thread (`1`) | 70.92 | 59.89 | 117.40 | 121.57 |

Each scene is one sequential A/B pair, not a confidence interval. All UI cases
passed; p50/p95/p99 improved in these pairs. A single maximum sample is not
used to claim tail improvement.

Thread owner `1`, main stall `8/33`, same optimized configuration:

| Flood panes | CPU p50/p99 ms | GPU p50/p99 ms | Interval p99 ms |
| :--- | :--- | :--- | ---: |
| 1 | 0.05 / 0.06 | 0.61 / 0.63 | 16.67 |
| 2 | 0.06 / 0.11 | 0.49 / 0.55 | 16.67 |
| 4 | 0.10 / 0.19 | 0.37 / 0.50 | 16.67 |

The intervals meet the 25 ms gate at 60 Hz. CPU/GPU remain within the earlier
baseline spread. The measurement tests now wait for and report all three
metrics and enforce that interval gate for the opt-in owner outside Low Power
Mode.

## Cursor ownership correction

A live TSan capture exposed two cursor positions during a dark block-cursor
return to Metal. The old implementation drew the live cursor at its new cell
before the presented-handler main-actor hop removed the old CA layer. Because
Metal and CA present independently (D25), a token-valid callback alone did not
prevent that overlap.

A dedicated, standalone cursor layer now has a one-shot retirement guard.
Animation/opacity writes are serialized independently of its view hierarchy.
Input or reader activity stops its animation and commits opacity zero *before*
publishing takeback to the render owner. The next Metal frame uses the actual
cursor immediately, without waiting for a main-actor callback. Main still owns
creation, geometry, attachment and removal; removal waits for a positive
presented callback. A late main callback cannot restart a retired animation.
The regression checks background retirement, stale-session rejection and
irreversible retirement. This uses explicit [Core Animation transactions](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/AdvancedAnimationTricks/AdvancedAnimationTricks.html)
for the standalone presentation, without moving any AppKit view operations off
main or enabling `presentsWithTransaction`.

The previous version, which held Metal's cursor at the layer's old cell until
main removed it, eliminated duplicate positions but failed the calibrated
staleness check (131 ms beyond the measured Metal-only envelope). It is withdrawn.
Initial duration checks used a process-relative Python clock and could not
establish staleness. The final harness uses `mach_absolute_time` for both
processes, asserts that each journal timestamp belongs to its corresponding
keypress, and brackets a screenshot's capture time between API entry and return.
A screenshot return timestamp alone would incorrectly include capture overhead.
The comparison uses the CA lower bound against the Metal upper bound plus one
refresh interval. Captures have finite temporal resolution; they do not establish
pixel behavior on every display refresh.

## Final automated checks

The full app Unit plan with TSan passed 987 tests in 152 suites, with the same
four pre-existing known issues. The helper uses the unchanged pure-computation
sandbox, which rejects TSan runtime resource acquisition. Only the disposable
TSan test bundle's helper was replaced by the identical normally-built source
and the test bundle was re-signed preserving its metadata. Deep strict signature
verification passed; `otool` confirmed the app retained TSan and only the helper
did not. No project signing flags, entitlements or sandbox policy changed.
This is app TSan coverage across a process boundary, not helper TSan coverage.

The optimized performance plan passed five tests in four suites. The final
120×40 frame baseline was mean 0.291 / p50 0.275 / p95 0.471 / p99 0.866 ms,
not above the previous three baseline means 0.456 / 0.370 / 0.342 ms. The repository's
Benchmark configuration uses Release `-O` settings and a development identity
(D22); this is not a Debug `-Onone` measurement.

The final focused threaded one-pane flood passed the new 25 ms assertion:
CPU p50/p99 0.05/0.07 ms, GPU 0.62/0.63 ms, interval p99 16.67 ms. The window
memory test completed five real open/flood/close cycles, checking window counts.
Absolute physical memory after each cycle was 104.416 / 104.547 / 104.580 /
104.695 / 104.662 MB, versus peak approximately 207.9 MB while the extra window
was open; net per-cycle growth averaged 0.095 MB. The owner lifetime regression
also verifies that teardown releases its render thread.

## Final live cursor and lifecycle capture

Both owners used the final standalone-layer retirement implementation, TSan,
identical raw-TTY cursor scripts and the shared absolute clock:

| Owner | CA handoffs/takebacks | Transition screenshots | Live session |
| :--- | ---: | ---: | ---: |
| Thread (`1`) | 24 | 480 | 302.53 s |
| Main (`0`) | 24 | 480 | 301.74 s |

Each case covers block, bar and underline in light/dark themes, with a solid
Metal-only reference for the matching theme and shape. Every sampled screenshot
had at most one pink cursor column cluster, and each round observed the new
position. The calibrated staleness comparison passed for every case: no captured
old-cell sample had a positive lower bound beyond the reference upper bound
plus one 60 Hz refresh interval. Zero in the sample bound is not a claim of zero
presentation latency. Each session also performed real floods, splits, closes,
window resizes and font changes. No TSan race report occurred.

The source is a throwaway local XCUITest and is deliberately not committed
(#290). Screenshots remain temporary local artifacts and are excluded as the
user requested. The 1×/2× offscreen raster tests verify exact cursor pixels;
these native captures establish only the available 2× display.

The full Unit TSan plan was repeated after the final retirement implementation:
987 tests / 152 suites passed in 38.781 s with the original four known issues.
One intermediate test assumed an unattached layer retained an animation; its
fixture assertion was corrected to check eligibility and irreversible retirement.
Live, attached-layer animation behavior is covered by the captures above.
The five optimized performance tests and the focused flood/memory cases were
also repeated on that final source and passed; their final numbers are above.


`script/build_and_run.sh --verify` built and launched the final development app
in an isolated stage with the default main render owner. License checking passed
687 tracked files, and `git diff --check` passed. The earlier complete core run
(916 tests), fuzz run (500,000 cases), automated AX coverage and session-card
normal/narrow-window checks remain valid for their unchanged runtime paths.
Security configuration and PNG content hashes were checked against all 22
excluded local files; they were unchanged and are not part of the commit.

## CI compiler compatibility follow-up (2026-10-12)

The first PR CI build rejected a local noncopyable `Atomic<Bool>` captured by
both a GPU callback and a main-actor task (`sending 'accepted' risks causing
data races`). The acquisition/release operations now live in a checked-Sendable
reference marker. It is allocated only when a cursor presentation is pending,
so ordinary frames allocate no marker. Neither CI configuration nor concurrency
checking was relaxed. An owner-boundary regression checks accepted and dropped
encodings through the shared reference.

After this change the full TSan plan passed 988 tests in 152 suites in 38.549 s,
with the same four known issues. The optimized plan and final flood/memory cases
passed again. D17 mean/p50/p95/p99: 0.302 / 0.290 / 0.498 / 0.986 ms; one-pane
CPU p99 0.07 ms, GPU p99 0.63 ms, interval p99 16.67 ms. Closed-window absolute
physical memory over five cycles: 104.170 / 104.416 / 104.449 / 104.449 / 104.433 MB.
