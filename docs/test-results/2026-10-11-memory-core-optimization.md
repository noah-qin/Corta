# Memory and core optimization: #286–#289

Date: 2026-10-11. Implementation and measured acceptance record. Conditional
stages remain conditional; hardware checks and the final UI rerun are stated
explicitly below. Cell stays 16 bytes. History and search indexes stay in RAM.

## Environment and baseline

Mac17,3 / Apple M5, macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Swift 6.4
(swiftlang-6.4.0.34.1), AC power, Low Power Mode off. Before is an isolated
archive of `90f4481` with instrumentation only; after is this patch. Both use
the same toolchain and Release `-O`. The final Unicode benchmark driver was
copied unchanged to the baseline and uses five measured samples after one
warmup per mode; checksums agree. Offscreen frames use Menlo 14 @1x,
120×40 cells; memory experiments use Menlo 12 @2x. UI fixtures request
120×40 and disable blinking. Physical panel refresh/scale were unavailable;
requested Hz is not measured cadence. No installed app or persistent machine
configuration was changed. Temporary fixture apps use ad-hoc signing and
hardened runtime disabled only through xcodebuild overrides.

Raw driver output: [same-machine benchmark samples](memory-core-2026-10-11/raw-benchmarks.txt).

## #286: compact instances and stage gates

QuadInstance is 24 bytes: Float2 origin/size, RGBA8, UInt32 rectangle index.
An 8-byte UInt16 pixel-rectangle table is normalized against actual atlas
dimensions. Each queued draw owns its table copy. Float geometry preserves
negative bearings and fractional/block geometry; a UInt16-only 16-byte layout
was rejected for correctness. Kitty retains exact fractional Float4 UVs in
its per-draw uniform. Swift/MSL ABI and rendered pixels have regression tests.
Consecutive equal raw foreground/background roles, reverse/dim bits and
cursor state reuse resolved/packed colors; other attributes retain their
normal rendering behavior.

Instance upload counts include rectangle metadata, excluding small uniforms
and alignment padding: full rebuild 222,816 → 111,432 B; typing
224,400 → 112,224; shift 34,320 → 17,184; blocks 321,168 → 160,584;
all rows redrawn 171,888 → 85,968; history/anchored output
228,480 → 114,264. History fixture has 8,000 rows and compresses cold batches.

Final offscreen distributions, ms, p50/p95/p99/max (60 measured frames after
warmup, separate before/after quiet runs):

| Scenario | Before | After |
| --- | --- | --- |
| D17 full frame, including submit | .436/.659/1.334/1.334 | .335/.586/.953/.953 |
| Four 400×120 panes, one dirty row | .3055/.37675/.402875/.402875 | .213625/.28875/.380792/.380792 |
| Four 400×120 panes, full rebuild | 4.323/7.809459/9.208709/9.208709 | 3.66175/7.47925/14.952375/14.952375 |
| Typing | .019/.046/.053/.053 | .017/.047/.065/.065 |
| Shift + one row | .018/.042/.049/.049 | .034/.083/.103/.103 |
| Full instance rebuild | .131/.142/.152/.152 | .121/.144/.189/.189 |
| All rows redrawn | .119/.133/.142/.142 | .107/.138/.830/.830 |
| Blocks | .125/.132/.148/.148 | .121/.142/.173/.173 |
| Region scroll | .030/.034/.045/.045 | .030/.051/.058/.058 |
| History step 1 | .017/.018/.019/.019 | .017/.024/.027/.027 |
| History step 13 | .017/.019/.020/.020 | .016/.024/.037/.037 |
| Anchored output | .118/.122/.127/.127 | .110/.136/.153/.153 |

D17 average .446 → .350 ms. Median gains do not imply uniformly better
p99: several short microbenchmarks and the large full rebuild have worse
tails in the final run. Earlier after shift samples were ~.016 ms; this spread
is recorded rather than selecting only the fastest run. Broad tail acceptance
is not established by these samples alone.

Stage decisions: row-relative positions fail a declared 100 µs opportunity
gate (whole shift frame 16–34 µs). Shared ASCII fails both a 4 MiB saving
and 10% window benefit gate: all four current atlases together are 1.063 MiB.
Per-pane mutable ownership remains. Optional GPU expansion has a 4 ms p50
large-pane gate and depends on #284 first. #284 is open; pre-dependency full
rebuild measurements span ~3.66–4.44 ms. Re-measure after #284 before deciding;
no render-thread migration or GPU expansion was added here.

## #287: lazy atlas and storage

Grayscale starts 2048×128, color 1×1; height doubles to 2048. Growth copies
texels and preserves glyph metadata without changing generation: zero
full-row invalidations caused solely by growth (tested, not a timed metric).
Page eviction recycles only that page's rectangle slots. Font reset shrinks
to initial dimensions. Old textures retire on backend completion. Failed
replacement never overwrites an in-flight texture; bounds/failure tests
verify unavailable glyphs are omitted safely.

Actual allocatedSize per prompt pane is 278,656 B; four total 1,114,624 B
(1.063 MiB), below the 1 MiB per-pane target. Baseline actual allocatedSize
is 21,233,664 B per pane and 84,934,656 B (81 MiB) for four. This is resource
allocation, not physical-footprint equivalence.

Final four-pane storage experiment:

| State/storage | Device allocation delta | Physical-footprint delta | Init |
| --- | ---: | ---: | ---: |
| Before managed | 84,934,656 B | 1,196,056 B | 4.983 ms |
| Before shared | 84,934,656 B | 1,196,056 B | 2.791 ms |
| After managed | 1,245,184 B | 212,992 B | 3.727 ms |
| After shared | 1,114,112 B | 196,608 B | 1.500 ms |

Allocation pooling affects footprint deltas; these do not prove an equivalent
managed/shared physical-memory reduction. Four 128×128 Kitty textures each
allocate 81,920 B in both modes; device/footprint increases are 327,680 B.
Single-sample managed/shared decode-upload time is 5.493/5.488 ms, not evidence
of a material timing gain. Shared storage is used for Apple silicon CPU uploads;
no Intel result is inferred. Backend construction cold 70.228 → 69.246 ms,
warm median .086 → .079 ms; cold includes pipeline/toolchain setup.

## #288: cold history and bounded readers

Hottest four sealed 256-row batches plus mutable tail remain plain. A serial
utility worker captures immutable work under the session lock, encodes and
scans hyperlink/grapheme IDs outside it, validates namespace/batch identity
on installation, and yields to waiters. One scheduled drain per session,
no recurring timer; stop ends work. A monotonic frontier avoids rescanning
attempted batches, including out-of-order installs and head eviction. Clear
rejects stale work. Parked main history is maintained through immutable holder
replacement, preserving snapshots.

Decoded cache is limited to four arenas / 8 MiB; ASCII planes to 32 MiB,
including metadata. Per-query readers avoid repeated cache locks. Partial
head eviction uses sparse ID sets without decoding all cold history. Dump
and reflow stream one decoded arena at a time. Narrow reflow runs bulk-copy;
wide/spacer boundaries preserve cursor and wrap rules. Legacy 120→80 reflow:
73.2 → 54.1 ms.

100k-row codec experiment, encode/decode MiB/s includes shuffle and scratch:

| Corpus | Codec/layout | Ratio | Encode | Decode |
| --- | --- | ---: | ---: | ---: |
| SGR ls | LZ4 raw | 38.26× | 11182 | 31645 |
| SGR ls | LZ4 shuffled | 109.03× | 2155 | 1845 |
| SGR ls | LZFSE raw | 119.28× | 235 | 22666 |
| SGR ls | LZFSE shuffled | 232.95× | 208 | 2297 |
| Log | LZ4 raw | 53.06× | 14253 | 39532 |
| Log | LZ4 shuffled | 87.24× | 2151 | 1646 |
| Log | LZFSE raw | 122.84× | 220 | 19915 |
| Log | LZFSE shuffled | 325.02× | 192 | 2341 |
| CJK | LZ4 raw | 86.93× | 15618 | 38380 |
| CJK | LZ4 shuffled | 109.70× | 1551 | 1616 |
| CJK | LZFSE raw | 261.47× | 216 | 17908 |
| CJK | LZFSE shuffled | 437.02× | 187 | 1391 |

These synthetic rows have repeated attributes. All configurations roundtrip
complete 16-byte Cells. Ratios are not promised for arbitrary user history.
Raw LZ4 is selected for fast random decode and lowest encoding latency;
shuffling gains bytes at a large CPU cost. Encoding that cannot save at
least half the cell bytes is not installed. Actual compressed arrays are
copied to exact capacity; shrinking only an ArraySlice retained raw capacity.

The final isolated maintained-ingestion 100k×120 history run reports RSS
increment 11.4 MiB (5.7→17.1 MiB), physical-footprint increment 11,714,584 B
(11.17 MiB), versus roughly 185 MiB before. Other maintained runs measured
7.4 MiB; the final result is not replaced by the minimum. Deferred compression
can retain malloc high-water pages after freeing Cell arenas; immediate RSS
reduction is not guaranteed. No mmap or allocator pressure-relief calls are
used. Combined all-scenario benchmark peak RSS is not this isolated metric.

## #289: core paths, measured separately

Parser SIMD16 uses bounded unaligned loads and scalar tail. Short runs keep
the original span path; longer runs use SIMD after a scalar prefix to avoid
ANSI-separated short-run overhead. CJK profiling (3,720 samples) attributes
most time to grid/memmove/width/wide writes; UTF8 decode and dispatch about
10–15%, so no decoder rewrite was justified. Pinned common CJK ranges and
single-grow wide writes target the measured grid work. Kitty budget refresh
is lazy after a valid command, replacing two scans of every feed slice.

Final Unicode medians, MiB/s, five measured samples plus warmup:

| Corpus | Parser before/after | Grid before/after | Feed before/after |
| --- | --- | --- | --- |
| ASCII | 700.7 / 628.8 | 89.0 / 89.0 | 345.2 / 340.3 |
| CJK | 229.6 / 236.7 | 55.5 / 65.9 | 70.8 / 87.4 |
| Emoji | 222.4 / 202.1 | 54.9 / 55.2 | 70.6 / 70.6 |
| AI ANSI mix | 364.5 / 394.5 | 85.4 / 89.9 | 123.3 / 133.7 |

ASCII parser ranges 518.7–757.4 before / 551.1–703.6 after; feed
342.5–345.9 / 336.4–343.1. CJK feed 70.5–71.1 / 87.0–87.5 (~23% median
gain), AI feed 122.9–123.5 / 133.3–133.9 (~8%). Emoji feed remains stable.
Parser-only rates do not predict end-to-end feed. Earlier single-sample
ASCII parser 812 MiB/s is superseded by this repeated driver.

ASCII search uses bounded shared planes, reverse KMP and SIMD first-needed
byte skip. A–Z folding only preserves punctuation; Unicode scalar fallback,
newest/rightmost non-overlap, wrapped mappings and cancellation remain.
100k fox corpus cold setup 27.207 → 44.699 ms; warmed calls
25.468–25.664 → 20.018–20.822 ms. First-query latency is a real regression
from building the index; repeated-query benefit is not cold-search acceptance.
Uncompressed broad-driver search p50/p95/p99/max 21.230/21.815/21.902/21.902 ms.
Neighbor keypress under flood .015/.020/.029/.056 ms, zero timeouts.

## Verification and live frames

Final production app full unit run: 968 tests / 148 suites passed in 13.969 s,
with four existing expected invalid-size issues. Full Release core: 755 tests /
78 suites in 45.680 s, including 1,000,000 scalar-reference parser differential
cases (23.096 s), all cap cases and a 100 MB PTY drain (1.493 s). Exec 13,
license 22 and SFTP 125 tests also passed. Focused final ThreadSanitizer:
22 compression/cache/image-budget tests in 8.301 s, no reported race.
Two final 500k mutation runs, seeds 1 and 2, passed. Earlier quiet Debug
core also passed; a concurrent run hit child timeout and was rerun quietly.
A redundant app rerun aborted in unchanged CFAttributedString font creation;
the completed final full app run above passed again. These failed attempts
are not counted as passes.

Live CPU/GPU frames, n=600, ms p50/p95/p99/max:

| Scenario | Before CPU | After CPU | Before GPU | After GPU |
| --- | --- | --- | --- | --- |
| 1 pane | .07/.09/.12/.35 | .08/.09/.13/.37 | .61/.62/.63/.88 | .61/.62/.63/.63 |
| 2 panes | .08/.13/.17/.59 | .09/.13/.18/.39 | .70/.76/.77/.78 | .50/.52/.54/.56 |
| 4 panes | .11/.19/.26/.33 | .13/.21/.28/.55 | .34/.47/.48/.58 | .34/.47/.49/.56 |
| Region | — | .08/.13/.25/.50 | — | .80/.85/.86/.88 |
| Keyboard history | — | .31/.44/.55/.85 | — | .82/.95/1.32/1.43 |

Each flood pane has a verified live producer. History asserts a changed
viewport and alternates Shift–PageUp/PageDown every 100 events. Wheel runs
failed because XCTest reported unavailable display rectangles; keyboard
results do not validate physical wheel gestures. All six final MeasurementUI
and five performance-driver tests passed. These UI frames precede the final
raw-color memo; pixel equivalence passed afterward and final D17 numbers
above include the memo.

Four idle prompt windows: median footprint 124,208,184 → 107,578,352 B
(~118.4→102.6 MiB), reduction ~15.86 MiB / 13.4%. Repeated window-close
memory test passed with stable after footprint (~101.5 MB).

## Final table-corner verification

The user's final request adds explicit square and rounded corner inspection.
Both border-continuity GPU tests now cover font sizes 12/14/17/40 and
scales 1/1.25/1.5/2/3, checking all four sides/corners; rounded tests also
check connected ink and bare outer corners. Representative GPU PNGs are
attached even on success. Inspection found one-pixel outward spurs at square
corners in the original center-overlap geometry. Endpoints now join the
widest perpendicular stroke rather than extending beyond it. The added
pixel envelope assertion prevents all four corner spurs; continuity and
rounded-corner tests still pass. Full app rerun after the fix: 968 tests /
148 suites passed in 13.763 s, four known expected issues. Images inspected:
[square corners](memory-core-2026-10-11/square-corners.png),
[rounded corners](memory-core-2026-10-11/rounded-corners.png),
[heavy square corners](memory-core-2026-10-11/heavy-corners.png).
Heavy square borders are covered as well as light square and rounded ones.
Full functional Debug UI: 28 tests executed, 26 passed / 2 failed, 546.318 s.
Both failures are input-source indicator tests: the no-integration shell
fixture lacks its expected prompt; toolbar visibility after history navigation
does not satisfy its assertion. The same two failures reproduce on baseline `90f4481` in Debug with fresh
fixtures (27.230 s): identical missing prompt and identical indicator
visibility timeout. They are pre-existing failures under this environment,
not introduced by this patch. Mock SSH, all nine UI languages, theme editor, settings, splits,
font shortcuts, recovery and table appearance passed. Exported live table
images were inspected in both appearances: four square corners and interior
junctions meet cleanly, CJK stays inside two cells and the emoji remains colored.
[Light table](memory-core-2026-10-11/table-light.png),
[dark table](memory-core-2026-10-11/table-dark.png).
Final Release performance target: all five tests passed in 1.098 s after
the corner fix. Several subsequent explicit-URL UI launch attempts failed
with no application process ID and were stopped; they do not count as
measurement passes. The app itself passed direct and Launch Services startup.
The measurement driver now uses XCTest's configured default target, retaining
the isolated fixture environment. A process-path check confirmed the current
Benchmark executable, not the baseline or an installed checkout. A leftover
baseline Debug fixture process was terminated. Four-pane flood then passed
in 49.627 s, CPU p50/p95/p99/max .12/.20/.26/.37 ms, n=600.
The other ten measurement cases passed with zero failures in 562.731 s.
Together all eleven cases passed: 1/2/4-pane floods, prompt memory, idle,
occluded CPU, keypress-to-glass, launch, paste, open/close memory, and region /
history scrolling. Final frame rings each have n=600:

| Scenario | CPU p50/p95/p99/max ms | GPU p50/p95/p99/max ms |
| --- | --- | --- |
| 1 pane | .08/.10/.14/.36 | .62/.62/.63/.64 |
| 2 panes | .09/.14/.21/.39 | .49/.51/.53/.62 |
| 4 panes | .12/.20/.26/.37 | .34/.47/.49/.56 |
| Region | .08/.12/.20/.40 | .82/.86/.87/.90 |
| Keyboard history | .32/.41/.55/.69 | .79/1.20/1.22/1.28 |

The final history test ran 701 PageUp/PageDown operations after asserting a
changed viewport. Four-prompt footprint is 110,412,784 B (~105.3 MiB), compared
with earlier after 102.6 MiB and before 118.4 MiB: observed saving is about
13.2–15.9 MiB / 11–13%. The range is retained rather than reporting only the
minimum. Window-close memory passed in 49.067 s. Idle CPU averages .001 s
per four-second sample. Scripted input-to-present n=200: avg 84.88 ms,
p50/p95/p99/max 82.92/112.75/132.39/132.47 ms. These XCTest events are not
physical keypress or 120 Hz validation, and no matching new latency baseline
was measured. Raw final UI summaries are included in the raw driver output.

Test-driver attempts: the full functional UI plan was initially invoked with
Benchmark instead of its specified Debug configuration. The mock SSH override
is Debug-only, so that attempt cannot validate remote workflow. It was stopped
and rerun with Debug. A leftover Benchmark fixture app with the same bundle ID
interfered with explicit Debug fixture launches; only that temporary process
was terminated. Directory completion then passed in an isolated Debug run
(29.742 s). Fixture URLs now resolve symlinks and report the exact app path.
Incomplete runs are not counted as full-suite passes.

The first final appearance UI run lost its helper connection at the keyboard
settings menu; it is recorded as failed, not a visual pass. Actual 120 Hz,
cross-display scale movement and held-key font resizing remain unverified
hardware checks. The normal build/run scripts are unchanged. License check
passed 660 tracked files; the three new Swift test files carry Apache headers.

## Archived final checks

The separately archived final performance run passed five tests in 1.136 s.
D17 after the corner fix: avg .358 ms, p50/p95/p99/max
.343/.514/.950/.950 ms. Large grid one-row .214917/.24875/.255958/.255958;
full rebuild 3.903333/7.357708/10.171458/10.171458. These additional samples
show the spread rather than replacing the earlier paired table. Final storage
init managed/shared 2.829/2.651 ms, footprint delta 196,608 B in each mode;
mode timings are order/cache sensitive, not proof of a material speed gain.
Documentation drift: five tests passed in .110 s. Final license check:
660 tracked files passed; `git diff --check` passed. Temporary fixture roots
were removed after their apps exited; result bundles and logs remain under
`/private/tmp/corta-286-*` for review. GitHub delivery is handled after the complete verification below.

## Pre-PR verification

The two previously reproduced input-source failures were stale test fixtures,
not product defects. Toolbar placement intentionally remains visible during
history navigation and programs, as already specified in CONFIGURATION.md
and pinned by InputSourceIndicatorTests. The UI test now asserts that policy,
verifies the history viewport changes, and uses the current “Automatically”
menu label. The plain-shell fixture sets its own PS1 instead of depending on
the launch environment. All four focused input-source tests and the final
complete functional UI plan passed: 28/28, zero failures, 556.945 s.

The final staging check includes every new evidence artifact. LicenseHeaders,
REUSE.toml and LICENSING.md explicitly classify raw benchmarks, offscreen
pixel images and live UI screenshots; 670 tracked files pass the checker,
and all 22 license tests pass. Release script tests: 28 passed in 11.507 s.
Real localhost SSH/SFTP: three integration tests passed with a disposable sshd
and keys; no system configuration changed. A first script run lacked sandbox
access for swiftc caches; it is not counted as a successful run.

The final full Release SwiftPM rerun passed: 755 core tests in 45.440 s,
including 1,000,000 differential cases (23.087 s), 13 exec tests, 22 license
tests and 125 SFTP tests. The final full application unit rerun passed all
968 tests in 148 suites in 13.853 s, with four existing expected invalid-size
issues. The complete functional UI plan, performance target and all eleven
measurement cases above are green; physical hardware checks remain explicitly
unverified as listed above.
