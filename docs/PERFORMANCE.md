# Corta — Performance

[Documentation index](README.md) · [Project overview](../README.md)

Performance is the first priority (`DESIGN.md` §1). This document states
the targets, the rules that protect them, and how they are measured.

**The language is not the bottleneck.** Every modern GPU terminal —
Ghostty, Alacritty, kitty — shares the same architecture: a glyph atlas
and instanced quads. What separates fast from slow is the two decisions
in §2, not the implementation language. Swift with `ContiguousArray` and
raw integer buffers reaches the same ceiling, provided the hot path
avoids the constructs in §3.

---

## 1. Targets

Set before the first release and defended from then on. A change that regresses one of these
is a bug regardless of what it improves.

| Metric                     | Target                        | Why                                            |
| -------------------------- | ----------------------------- | ---------------------------------------------- |
| Frame budget (CPU)         | **< 4 ms**                    | 120 Hz ProMotion is an 8.3 ms frame            |
| Parser throughput          | **> 100 MB/s** single-thread  | `cat` of a large file must not be the slow part |
| Keypress → pixel latency   | **< 1 frame + input latency** | The metric a user actually feels               |
| Scrollback memory          | **100k 120-column lines within ~200 MB** | Log-heavy ML workloads are a target use case; the column count is stated because without it the target is unfalsifiable |
| Idle CPU                   | **~0%**                       | No redraw when nothing changed                  |

Numbers are re-measured at every release (§5.6). "It feels
fast" is not a measurement.

### 1.1 User-visible targets

§1's table states engineering targets (frame budget, parser throughput) — the
numbers a change is checked against. This table states what those numbers are
*for*: the categories a person actually notices, each with a target stated in
terms a user would recognize and the harness that is supposed to hold it
accountable. Where no repeatable number exists yet, that is stated plainly
rather than filled in with a guess.

| Category      | Target                                              | Held accountable by |
| -------------- | ---------------------------------------------------- | -------------------- |
| Input          | Keypress → glass feels immediate; §1's latency target | `RenderMetrics.keypressToPresent` via `scripts/measure-keypress-latency.sh` (§5.7), `corta-bench`'s `benchmarkKeypressLatency` |
| Sustained output | A flood (`yes`, a build log, a training run) does not fall behind or drop frames below §1's frame budget | `corta-bench`'s parse-throughput and write-backpressure benchmarks; `scripts/measure-app-baseline.sh` phase B flood |
| Scrolling      | Scrolling a long buffer tracks the pointer/trackpad with no visible stutter | `scripts/measure-render-metrics.sh` (`CORTA_RENDER_METRICS` ring buffer); no dedicated automated scroll benchmark exists yet — a real gap, not an oversight |
| Startup        | A warm launch reaches an interactive window fast enough that switching to Corta does not feel like waiting for an app to open | `scripts/measure-app-baseline.sh` phase A (5 warm launches + 1 cold-ish) |
| Memory         | §1's scrollback figure holds, and closing panes/windows returns memory rather than leaking it | `corta-bench`'s scrollback-footprint and peak-RSS benchmarks; `scripts/measure-app-baseline.sh`'s post-close recovery phase |
| Energy         | An idle pane draws no more power than idle CPU (§1) implies; a flooding pane does not keep the GPU busier than the frames it is actually producing require | `scripts/measure-energy.sh` (idle, occluded, background flood, two windows, Kitty image; `powermetrics` when it can run, labelled `top` samples when it cannot) — §5.6 has the figures, measured on mains and under Low Power Mode. Thermal pressure is not forced and stays *not judged* |
| Compatibility  | The real-program and esctest pass rates `CONFORMANCE.md` already tracks | `CONFORMANCE.md` §4.2 (esctest), §4.4.2 (real-program table), §4.6 (manual scenario pass) — cross-referenced here rather than duplicated |
| Recovery       | A crashed or force-quit Corta restores its window/split/scrollback state on next launch without asking the user to rebuild it by hand | `scripts/measure-app-baseline.sh`'s SessionRestore-driven multi-pane phases; `SessionRestore`'s crash marker |

Startup, memory and energy inherit their machine dependency from §5.2 below —
a number recorded here is only comparable to another run that held the same
fixed environment.

---

## 2. The Two Decisions That Matter

Everything else in this document is a detail by comparison.

### 2.1 Decouple PTY drain rate from frame rate

```
PTY read (blocking read / DispatchIO, batched — never byte-at-a-time)
        │
        ▼
Parser → Grid                     runs as fast as bytes arrive
        │
        ▼  CAMetalDisplayLink (vsync)  snapshot taken here, at most 1× per frame
Metal renderer
```

Three properties follow, and all three are mandatory:

**Never render per chunk of input.** A flooding process can produce tens
of MB/s. Rendering is driven by vsync and reads the latest grid state;
intermediate states are simply never drawn.

**Never stop draining the PTY.** If reading stops, the pipe fills, the
child blocks in `write`, and the terminal becomes the reason a training
job runs slowly. This is the classic cause of "my terminal slows down my
program" — draining must not be coupled to rendering, to the main thread,
or to any lock the renderer can hold for long.

**Cap the work in one parse batch.** Give a batch a byte budget (roughly
1 MB) and yield afterwards. Without a cap, a single enormous burst
starves the UI and the window appears frozen.

### 2.2 An ASCII fast path that bypasses shaping

Calling Core Text per line per frame costs milliseconds and destroys the
frame budget immediately.

- **Pure-ASCII runs skip shaping entirely** — look glyphs up directly via
  `CTFontGetGlyphsForCharacters`. This is the single largest text
  rendering win available, and it covers the overwhelming majority of
  terminal content.
- **Everything else goes through a shaping cache**, keyed by (run, font,
  attributes). Shape once, reuse across frames.

---

## 3. Hot-Path Rules

The hot path is: PTY read → parse → grid write → instance buffer build.
These rules apply there, and only there. Elsewhere, write ordinary
idiomatic Swift.

| Rule                                                     | Reason                                                     |
| -------------------------------------------------------- | ---------------------------------------------------------- |
| `struct` + `ContiguousArray`, never a `class` per cell or glyph | A `class` per cell means an ARC retain/release storm per frame |
| `UInt8` / `UInt32` buffers for bytes and scalars          | `String` carries grapheme-breaking semantics that are not free |
| Convert to `String` only at the Core Text boundary        | Shaping is the only place that needs it                     |
| No `NSString` / `NSArray` / ObjC bridging                 | Bridging cost per element                                   |
| No allocation per cell or per frame                       | Reuse buffers; size them at resize, not at draw             |
| Reuse pipelines and the atlas texture when the font changes | Rebuilding a `TerminalRenderer` per keystroke recompiled pipeline states and allocated a new atlas texture, which is what made key-repeat font sizing stutter |
| Triple-buffer the Metal instance buffer                   | Avoids a CPU/GPU stall waiting on the previous frame        |
| Rebuild the instance buffer only on damage                | Idle CPU must be ~0%; a static screen rebuilds nothing      |

### On damage tracking

With instanced quads, redrawing a full screen on the GPU is already
cheap. The win from damage tracking is **not rebuilding the instance
buffer** on the CPU when nothing changed. Track damage at line
granularity; per-cell damage tracking is complexity that does not pay for
itself.

On the live screen the line-granularity check is not a comparison of
each row's full `Line` value against the cache but a `UInt64` stamp (`Grid.lineRevision(_:)`, bumped centrally by
`ScreenLines` on every row it touches: `ScreenLines.swift`). The
granularity is unchanged, still one row, not one cell; only the cost of
asking "did this row change" dropped, from an `O(row length)` comparison
to one integer compare. Scrolled into history the rows come from
immutable scrollback storage with no such stamp, so that path still
compares `Line` values directly (`TerminalRenderer.rebuildDamagedRows`).
The shell takes one `session.snapshot()` + diff per frame, in
`ViewController.prepareFrame`, and releases it there: `render` draws the
renderer's cached instances and reads no grid. A second snapshot would
diff a grid the first had just diffed in the same vsync callback, and one
held until the next frame would cost the reader a scrollback copy (§5.9).

Because a `ScreenLines` swap (an alternate-screen enter/exit, a column
resize replacing `lines` outright) restarts row revisions from small
numbers a moment-ago screen's cache could coincidentally already hold,
`ScreenLines.generation` — a process-wide unique value set once per
instance — is checked alongside `lineRevision` so that coincidence can
never be mistaken for "unchanged" (`Grid.linesGeneration`).

**On scrolling specifically:** a whole-screen scroll used to look like
every row changed — the ring-buffer rotation `ScreenLines.rotateUp`
uses to make scrolling O(1) also (correctly) gives every surviving row
a new *position*, and the old value-based diff had no way to tell "this
row's content moved" from "this row's content changed". `Grid.
linesRotated` (`ScreenLines.totalRotated`, bumped in `rotateUp`) lets
`TerminalRenderer.applyScrollShift` tell the difference: retained rows'
instances are shifted by a Y-coordinate offset — a bulk arithmetic pass —
instead of rebuilt through `appendRowInstances`' per-cell Core Text/atlas
lookups, and only the newly exposed rows at the bottom get a real
rebuild. A scroll larger than the screen (nothing survives to shift) and
scrolling within a partial scroll region (an application's own scroll
region, e.g. a status line — outside `Grid.scrollUp`'s history-saving
path, so `totalRotated` does not move for it) both fall back to the
ordinary per-row check, unoptimised but correct.

**Considered and not done:** shifting the CPU-side cache is the win here,
not shrinking what gets copied into the GPU instance buffer afterward.
`Metal4Backend`'s ring buffers already copy the whole array in one
`memcpy` per draw (steady-state zero allocation, `PERFORMANCE.md` §3),
and true byte-range partial updates into a *triple-buffered* ring would
need each of the three slots to independently track which generation of
the array it holds and replay every dirty range accumulated since — and
because a row's rebuilt instance count can change (an edit that adds or
removes a glyph), a row's byte offset in the array is not stable across
rebuilds the way a fixed-size slot's would be, so a naive partial copy
risks splicing the wrong bytes into a shifted position. Solving that
properly means fixed-size per-row instance slots, a larger rewrite not
justified here: a full array copy is a sub-millisecond `memcpy`
(hundreds of KB at a typical window size), not the measured cost.

---

## 4. Memory

- **Rows are variable length**, stored up to the last non-blank cell.
  Fixed 200-cell rows over 100k lines is ~320 MB (`DECISIONS.md` D05).
- **Scrollback is a ring buffer** with a configured line cap; eviction is
  O(1) and never a reallocation of the whole history.
- **The glyph atlas is bounded**: a full 2048×2048 page is reset on
  exhaustion and re-rasterised on demand (`DESIGN.md` §7, hard part 4). A
  CJK session exceeds a single page.
- **Every unbounded input has a cap** — OSC/DCS string length, CSI
  parameter count and magnitude. See `SECURITY.md` §3; these are
  simultaneously a memory-safety and a denial-of-service concern.

---

## 5. Benchmarks

Because the terminal core is a separate SwiftPM package (`DESIGN.md`
§2.2), all of these run without launching the app.

| Benchmark                              | Measures                              |
| -------------------------------------- | ------------------------------------- |
| `vtebench`                             | The standard cross-terminal comparison |
| `cat` of a ~100 MB text file           | End-to-end throughput                  |
| `find / 2>/dev/null`                   | Sustained realistic output             |
| `yes`                                  | Worst-case flood; also verifies §2.1   |
| Neovim scrolling a large file in tmux  | Interactive full-screen redraw path    |
| Parser-only harness over a byte corpus | Isolates parse cost from rendering     |

Latency (keypress → glass) is measured separately — since 1.0.0 from
inside the app (§5.7); before that with an external screen-capture tool.
It is invisible to
throughput benchmarks and is the number users actually perceive.

The measurements taken before 1.0.0 with that tool, and why they cannot
be read against each other, are
[a record of their own](history/2026-09-09-LATENCY-BEFORE-1.0.md).

**The percentile-shaped view of the render stage.** Between
`corta-bench` (headless, core-only) and the end-to-end §5.7 number sits
`CORTA_RENDER_METRICS=1`
(`RenderMetrics.swift`'s 600-sample ring buffer, streamed by
`scripts/measure-render-metrics.sh`): it dumps real p50/p99 for `cpuFrame`,
`drawableWait` and `gpu` from a live, on-screen app, without Instruments.
Its limit: it needs a person at the keyboard
typing and scrolling for the ring to fill with real frames (the
`scripts/measure-app-baseline.sh` finding that synthetic System Events keystrokes
never reach `TerminalView` applies here too — a scripted flood through the
PTY slave fills `drawableWait`/`gpu`, but `cpuFrame` specifically wants real
keyDown-triggered frames), so it is a tool for a person at the keyboard,
not a scripted number.

**Every target has a baseline.** Without one, "performance is the
first priority" is a slogan rather than a constraint.

### 5.1 Report distributions, never averages

Every latency number in this document must carry **p50, p95, p99 and the
maximum**. `corta-bench` reports all four (`LatencyDistribution`), and so does
§5.7's in-app measure; the screen-capture figures from before 1.0.0
(`history/`) predate the rule and are averages, which is exactly the
shape of the problem.

An average is the one statistic a latency measurement should not be
reduced to. Keypress latency is not normally distributed — a tight body
with a tail of vsync misses and scheduling hiccups — and it is the tail
that is felt: 45 ms average with a 90 ms p99 is a terminal that visibly
stutters once a second while averaging "fine". A change that trades 2 ms
off the mean for 20 ms on the p99 is a regression that an average
reports as an improvement.

The sample count has to support the percentile it claims. The p99 of 200
samples is the second-largest value in the set, which is one scheduling
hiccup away from being noise; `corta-bench` takes 2,000.

### 5.2 The fixed benchmark environment

Numbers recorded in this document or in `docs/history/ROADMAP-0.1.md` are only comparable
against numbers taken the same way. Any run that is quoted must state:

| Variable          | Fixed at                                              |
| ----------------- | ----------------------------------------------------- |
| Machine           | The recorded machine and chip |
| Build             | Release (`-c release` / the Release scheme), never Debug |
| Display           | Built-in panel, and its refresh rate — a 120 Hz panel halves the vsync quantum a 60 Hz one imposes, which moves every latency number in this table |
| Scale factor      | The display's native backing scale (the atlas is rasterised per scale) |
| Font              | System monospaced at 12 pt, the default |
| Window            | 120×30, one pane, not full screen, no tab bar |
| Power             | Mains, not battery — the efficiency cores and a lowered display refresh rate are both on the table otherwise |
| Other load        | No other application in the foreground; the app activated and its window frontmost |
| Test program      | Named explicitly (`cat`, `yes`, `nvim` in `tmux`, `vtebench` case) |

Two runs that differ in any row of that table are two different
measurements. In particular a Debug build is not a slow Release build:
the parse path's bounds checks and non-inlined generics change its shape,
not only its speed.

**Toolchain.** Compiler, SDK, language mode and deployment target are
four different things — conflating them makes a "same environment" claim
unfalsifiable. Recorded on the machine this run was measured on
(2026-09-10):

| Variable            | Value                                                    |
| -------------------- | --------------------------------------------------------- |
| Xcode                | 26.6, build 17F113 (stable channel; `xcodebuild -version`) |
| Swift compiler       | 6.3.3 (swiftlang-6.3.3.1.3, clang-2100.1.1.101; `swift --version`) |
| Swift language mode  | Swift 6, per the Xcode project's `SWIFT_VERSION` and `CortaTerminal/Package.swift`'s `swift-tools-version: 6.2` |
| macOS (build machine) | 26.6.2, build 25G83 (`sw_vers`) — the OS actually running the benchmark, not a promise every contributor matches it |
| Deployment target    | `MACOSX_DEPLOYMENT_TARGET = 26.0` (`Corta.xcodeproj/project.pbxproj`) — the oldest OS the shipped binary claims to run on, independent of the two rows above |

**Current stable toolchain (2026-09-19).** The benchmark identity above
is historical; the installed toolchain has since changed. The following
compatibility results are not new benchmark measurements.

| Xcode / build | Swift compiler | macOS SDK / build | Language / deployment | Core / app result |
| --- | --- | --- | --- | --- |
| 27.0 / 27A266a | 6.4 (`swiftlang-6.4.0.34.1`, `clang-2100.3.34.1`) | 27.0 / 26A425 | Swift 6 / macOS 26.0 | 615 core / 653 app tests passed; 4 expected known issues |

The host runs macOS 27.0 (26A428). Results and diagnostics are recorded in
the [dated verification record](test-results/2026-09-19-issues-88-90.md).

**The pin and the measurement are deliberately two different toolchains.**
`XCODE_PIN` — 26.6.0 in `ci.yml`, `nightly.yml`, `release.yml` and
`render.yml`, which move together — is what compiles the binary users run.
The numbers in this document come from the machine above and whatever
toolchain it has, currently Xcode 27.0. There is no standard GitHub-hosted
runner with Xcode 27 (`macos-27` is not a label; the `xcode-27` image is a
preview that requires a paid larger runner), and CI was never going to be
where a performance number came from anyway: its runner is a virtual
machine whose GPU reports only `MTLGPUFamily.apple5` and cannot construct
a Metal 4 renderer at all (issue #107).

So the rule that keeps both usable is: **a number and the number it is
compared against must come from the same machine and the same toolchain**,
and every quoted figure says which one. That is enough for everything this
document is for — D17's "re-measure after touching the render loop", a
before/after on a batch, a regression guard — because all of them are
differential. What it is *not* enough for is an absolute claim about the
shipped binary: that binary is compiled by the pinned toolchain, and each
release records which one in its own notes (`release.yml`). Moving a
number to a new toolchain means re-recording its baseline on both sides
once, as a bridge, exactly as a Debug-to-Release move would.

A run quoted without this table predates the distinction — it is not a
claim that it used a different toolchain.

### 5.3 Attributing latency: `os_signpost`

An end-to-end number says whether the last change helped. It cannot say
*where* the time goes, and each stage has a different fix — so the whole
chain emits `os_signpost` intervals (`Corta/InputLatencySignposts.swift`),
subsystem `dev.noahqin.Corta`, category `input-latency`:

| Signpost  | Covers                                              |
| --------- | --------------------------------------------------- |
| `keyDown` | key event → bytes written to the PTY                |
| `output`  | a parse batch has been applied to the grid (a point, not an interval — it is emitted on the reader thread) |
| `wake`    | the MainActor hop that un-parks the display link — at most one a frame (§5.10) |
| `frame`   | the vsync callback: damage diff, instance build, `nextDrawable` |
| `commit`  | encode and submit                                   |
| `gpu`     | submission → the command buffer's completion handler |

```sh
xcrun xctrace record --attach Corta --instrument 'os_signpost' \
    --output /path/to/output.trace
```

`--instrument`, not `--template`: `os_signpost` is not one of
`xctrace list templates`' entries on current Xcode (it is one of
`xctrace list instruments`' entries instead), so `--template 'os_signpost'` — this
document's own earlier wording — fails outright with "Cannot find
template matching name". `--attach` to an already-running, already-
launched Corta, not `--launch`, for the reason the paragraph below this
one explains: launching *through* xctrace/Instruments does not hand the
new process window focus, so typing right after fails silently instead.
`scripts/record-signpost-trace.sh` runs the whole sequence (launch,
activate, attach, save to `.build/traces/` — not `~/Desktop`, which
needs a one-time Files-and-Folders permission grant Terminal does not
have by default and `xctrace` fails on outright).

Everything is behind `OSSignposter.isEnabled`, which is false unless a
trace is recording, so the render path pays one atomic load per stage.
That is what makes it safe in a Release build — and the point is that the
2.40 ms → 4.19 ms frame-CPU regression this document warns about was
invisible to every passing test and would have been one interval wide in
a trace.

**Open question this instrumentation exists to answer:** whether an
input-triggered partial redraw occasionally misses the current display
frame and waits a whole refresh period. In a trace this is visible
directly — an `output` event landing after that frame's `frame` interval
has begun, with the next `frame` an interval later.

**First two attempts: no valid data.** Two Instruments recordings against
the Release build both showed zero `keyDown` and `output` events — only
`wake`/`frame`/`commit`/`gpu` from idle cursor-blink activity — because
the typing done immediately after launching Corta from Instruments'
Record button never reached `TerminalView` (launching a target this way
does not appear to hand it window focus).

One incidental result from those two recordings, unrelated to the
missed-frame question but relevant to §5.4: Instruments' own
`CAMetalLayer.Stalls` track recorded real stalls from idle cursor-blink
redraws alone — 146 stalls averaging 30.6 ms in the first recording, 305
stalls averaging 30.5 ms in the second. Drawable stalling is happening on
this machine at rest, not only under load.

**Answered.** Two more things had to be fixed before a valid recording
was possible, both real gaps rather than test-environment noise:

1. Launching *through* `xctrace`/Instruments never hands the new process
   focus, confirmed again — the fix is `scripts/record-signpost-trace.sh`:
   launch Corta normally (it gets focus the way it always does), block
   until System Events itself confirms it is frontmost, *then* attach a
   trace to the already-running process. An unguarded `activate` that
   silently swallowed its own failure (`2>/dev/null || true`) was the
   actual reason two further attempts still showed a mistyped-into-the-
   wrong-window session — the script now surfaces that failure instead of
   hiding it.
2. `InputLatencySignposts.keyDown` only wrapped `TerminalView
   .deliverBytes` — the control-sequence bypass path (⌘/⌃, or an event
   the input context declines). Ordinary typing, composed or not, commits
   through `TerminalView.insertText` instead (Cocoa's input-context
   pipeline, not a Corta choice), and Return/Delete/Escape/the arrows
   through `doCommand(by:)` — neither had ever been instrumented. A trace
   of a completely normal typing session showed real keystrokes reaching
   the child (bytes on the PTY, grid updates, frames) with zero `keyDown`
   signposts the whole time, which is what exposed this: the chain's
   first link was silently only covering the path a small minority of
   real keystrokes take. Both paths are now wrapped in
   `InputLatencySignposts.measure(.keyDown)`, matching `deliverBytes`.

With both fixed, a 12-second recording of ordinary typing (122
keystrokes) gives:

| Stage | n | min | p50 | p99 | max |
| --- | --- | --- | --- | --- | --- |
| `keyDown` → next `output` | 122 | 0.07 ms | 0.13 ms | 0.19 ms | 0.43 ms |
| `output` → next `frame` begin | 131 | 0.56 ms | 9.46 ms | 15.61 ms | 15.73 ms |

The core-side chain (`keyDown` → `output`) stays sub-millisecond, in line
with `corta-bench`'s separately-measured 0.005 ms average for the same
span — the end-to-end latency is not spent in the core.

`output` → `frame` spreads roughly uniformly across the whole 0–16 ms
window this machine's frame-begin-to-frame-begin gaps cluster around
(§5.2's fixed-environment table was not held for this run — power and
foreground load were not controlled — so the exact frame period is a
observation of this run, not a citable number). That shape is what
*ordinary* vsync alignment looks like — a keystroke lands at a random
phase of the refresh clock, and the closer to the start of the current
period it lands, the nearer to a full period it waits for the next one.
**No `output` → `frame` gap in this recording exceeded roughly one frame
period** — the specific pattern a genuinely missed frame would show
(waiting for the vsync *after* the one that should have caught it) did
not appear. One 12-second sample is not exhaustive — a longer or busier
session could still catch a rarer double-miss — but this is a real answer
where none existed before, not another inconclusive attempt.

### 5.4 `maximumDrawableCount`

`CAMetalLayer.maximumDrawableCount = 2` is often cited as removing a
frame of latency; it can equally add one, because `nextDrawable()` then
blocks the main thread more often waiting for a drawable to be recycled.
Which one happens depends on how long a frame takes on the machine in
question, so it is a measurement, not a choice.

Corta ships the default (3). `CORTA_MAX_DRAWABLES=2` sets it for one launch, so the
comparison is two launches of the same binary rather than a code change.
Pair it with a signpost trace: if double buffering is costing rather than
saving, it appears as the `frame` interval growing at its front.

**Preliminary signal, not the A/B itself.** `RenderMetrics`
(`Corta/RenderMetrics.swift`, `CORTA_RENDER_METRICS=1`,
`scripts/measure-render-metrics.sh`) reports `drawableWait` — how long
`nextDrawable()` blocks — directly, without Instruments. One
informal run at the default drawable count (3), auto-repeat plus `yes`
for a few seconds, held nothing else about the machine fixed the way
§5.2 requires:

| Metric | n | avg | p50 | p99 | max |
| --- | --- | --- | --- | --- | --- |
| `drawableWait` | 600 | 0.00 ms | 0.00 ms | 0.00 ms | 0.00 ms |
| `cpuFrame` | 600 | 0.38 ms | 0.34 ms | 0.78 ms | 3.79 ms |
| `gpu` | 600 | 0.93 ms | 0.89 ms | 1.22 ms | 8.22 ms |

`drawableWait` never left zero — at the default count, `nextDrawable()`
is not blocking on this machine under this load, which is the condition
under which dropping to 2 has nothing to buy back and can plausibly only
cost (more frequent blocking, not less). Not a substitute for the actual
end-to-end A/B — that is the only way to turn "probably not worth it"
into a number.

**The end-to-end A/B itself.** `scripts/measure-drawable-ab.sh`
runs the same Release build twice, back to back, so the only variable
between the two runs is `CORTA_MAX_DRAWABLES`; since 1.0.0 each run is
`scripts/measure-keypress-latency.sh` (§5.7) and prints the percentile
line itself. The pair below was taken with the external screen-capture
tool of the day (200 chars / 150 ms delay / 50 ms period / 1,000 ms
length, synchronous, no pauses), mains power, Corta frontmost with
nothing else running:

| Run | Min, ms | Max, ms | Avg, ms | SD, ms |
| --- | ------- | ------- | ------- | ------ |
| A — default (`maximumDrawableCount = 3`) | 45.4 | 99.4 | 70.1 | 13.9 |
| B — `CORTA_MAX_DRAWABLES=2`              | 46.2 | 95.4 | 70.4 | 13.5 |

Run A and Run B are within noise of each other on every column — the
gap in the mean (0.3 ms) is far smaller than either run's own standard
deviation (13.5–13.9 ms). This matches the `drawableWait` finding above:
`nextDrawable()` is not blocking at the default count on this machine, so
there is nothing for a smaller count to buy back, and it does not cost
anything either. **Conclusion: leave the default (3).** Forcing 2 has no
measured benefit and is not worth the added blocking risk on a slower
frame or a busier machine.

(These two runs' Avg/SD are higher across the board than §5.5's earlier
single-run numbers for Corta — 70 ms vs. 45 ms — despite identical
capture settings; §5.2's environment table was not fully controlled for
this pair either, e.g. other background load on the machine varied
between sessions. The A vs. B *comparison* is still valid, since both
runs shared whatever that day's uncontrolled conditions were — only the
absolute numbers should not be cross-cited against §5.5's.)

### 5.5 Cross-terminal comparison

Taken before 1.0.0 with an external screen-capture latency tool — the only
kind of measure that can be pointed at another terminal, which is why
this table is not refreshed by §5.7's in-app measure. 200 characters /
150 ms delay / 50 ms period / 1000 ms length, synchronous mode, same
machine, same font (system monospaced, 12 pt), power connected, target
app frontmost with nothing else running:

| Terminal | Min, ms | Max, ms | Avg, ms | SD, ms |
| -------- | ------- | ------- | ------- | ------ |
| Corta    | 32.8    | 64.1    | 45.4    | 8.1    |
| iTerm2   | 28.1    | 63.0    | 42.7    | 7.7    |
| Ghostty  | 17.8    | 45.2    | 31.9    | 5.9    |

Corta is slower on average than iTerm2 and noticeably slower than
Ghostty on this machine. (Terminal.app is missing — the tool would not
measure it; figures above are min/max/avg/SD, not the §5.1 percentile
distribution.)

---

### 5.6 Numbers by release

One column per release, on the machine §5.2 records. A cell says *not
re-measured* rather than carrying an older figure forward. Each release's
full run — machine state, every scenario, the energy tables and the
reading of them — is its record under `history/`:
[1.0.0](history/2026-09-18-V1.0.0-BENCHMARK-RUN.md),
[1.0.1](history/2026-09-21-V1.0.1-BENCHMARK-RUN.md).

| Metric | 1.0.1 (2026-09-21) | 1.0.0 (2026-09-18) | How |
| --- | --- | --- | --- |
| Core feed throughput | 138.5 MiB/s (one run) | **144.2 MiB/s** (5-run mean; 141.2–146.6) | `corta-bench`, `-c release` |
| Parser-only / parser + grid | 766.9 / 161.4 MiB/s | 806.3 / 166.9 MiB/s | same run |
| Memory @ 100k × 120 lines | 184.4 MB | **185.0 MB** | `corta-bench` |
| Keypress → grid (core side) | p50 0.009 / p95 0.011 / p99 0.012 ms | p50 0.014 / p95 0.018 / p99 0.020 ms | `corta-bench`, 2000 samples; excludes vsync and display |
| Frame CPU, 120×40 full rebuild, Debug | **1.79 ms** avg (1.76 / 1.75 / 1.87) | **2.26 ms** avg (2.31 / 2.26 / 2.20) | `FrameCPUBaselineTests` (D17), Debug test action; from 1.1.0 a Release figure (§5.8) |
| Live frame CPU, Release, 2 / 4 panes flooded | not re-measured | avg 0.60 / 0.14–0.49 ms; p99 2.59 / 0.38–0.45 | `scripts/measure-app-baseline.sh`, `CORTA_RENDER_METRICS` |
| GPU, 2 / 4 panes flooded | not re-measured | avg 0.49 / 0.47 ms | same |
| Idle CPU, Release, 20 s | not re-measured | **0.05%**; occluded 0.0–0.1% | same |
| Launch → first window | not re-measured | 208 ms (2-pane restore), 451 ms (4-pane) | same |
| Spawn: `zsh -l` → first output | p50 46.8 ms | p50 44.5 ms | `corta-bench` |
| Reflow, 100k lines, 120 → 80 columns | 97.9 ms | 94.1 ms | `corta-bench` |
| Search, 100k lines, one query | ~400 ms warm | ~395 ms warm | `corta-bench` |
| Keypress → glass, scripted | not re-measured | **61.9 ms** avg; p50 61.4 / p95 69.7 / p99 70.9 | §5.7 |
| Keypress → glass, a person typing | not re-measured | **66.3 ms** avg; p50 67.0 / p95 78.7 / p99 84.5 | §5.7, `--manual` |
| Energy, background flood (`yes`, occluded) | not re-measured | 10.2 W machine-wide on mains; 2.6 W in Low Power Mode; idle, occluded and a static image within the machine's noise floor | `scripts/measure-energy.sh` |

Both runs were on battery for the core benchmarks, not the mains power
§5.2 asks for; the 1.0.0 keypress and energy runs were on AC. Every
1.0.1 figure is inside the run-to-run spread the 1.0.0 run recorded, and
the frame-CPU difference is the machine's state on the day, not the
change: the claim for 1.0.1 is "no regression".

### 5.7 Keypress → glass, measured from inside the app

A third-party screen-capture tool — one that grabs the window in a loop
until the pixels change — can measure keypress to glass, but Corta
measures the same interval from the inside, with nothing installed and no
permission asked:

- `TerminalView`'s three key-delivery sites hand `RenderMetrics` the
  event's `timestamp` — the HID timestamp for a real key, the posting
  time for a synthetic one;
- the reader thread marks the first parse batch after that keystroke
  as its echo (the assumption a screen-capture tool makes too: "the
  pixels changed after the key");
- the next drawable to be presented closes the sample in its
  *presented handler*, using `MTLDrawable.presentedTime` — the moment
  the frame reached the glass, not the moment it was scheduled. A
  drawable the compositor replaced before showing (`presentedTime ==
  0`, about half the frames of a burst) hands the keystroke back so
  the frame that *did* show the echo closes it; dropping those would
  keep only the lucky frames.

`CORTA_RENDER_METRICS=1` turns it on; 200 samples print one line on the
unified log (`keypressToPresent: n=200 avg=… p50=… p95=… p99=… max=…`),
and `scripts/measure-keypress-latency.sh` launches, drives 230 synthetic
keystrokes (or, with `--manual`, waits while a person types) and reads
the line back. Two kinds of number come out of it, and a quoted figure
says which:

| Kind | Includes | Comparable to |
| --- | --- | --- |
| Scripted (`key code` via System Events) | Corta's whole path plus the compositor and scanout; **not** the keyboard's HID stage (1–8 ms on USB/Bluetooth) | a lower bound on what a finger sees |
| `--manual` (a person typing) | everything a screen-capture tool saw | the pre-1.0 screen-capture figures (`history/`) |

The two kinds differ by the keyboard's HID stage plus the wider spread of
human keystrokes: a synthetic `key code` arrives at a fixed cadence, a
typist's do not, and the p95–p99 tail is where that shows. §5.6 has both
numbers for each release.

Both kinds say the same thing the target row in §1 says: above one
frame plus input latency, on a 60 Hz panel a good three to four frames.
Where those frames go is the `os_signpost` chain's job (§5.3); the
in-app number is what says whether a change moved it.

### 5.8 The frame-CPU baseline, under Release (D17)

D17's number is a Release number. One command produces it:

```sh
xcodebuild test -project Corta.xcodeproj -scheme Corta \
  -testPlan Release -configuration Benchmark -destination 'platform=macOS'
cat /tmp/corta-frame-cpu-baseline.txt
```

`TestPlans/Release` holds `FrameCPUBaselineTests`,
`InstanceUploadBenchmarkTests` and `RendererConstructionCostTests`, in the
`CortaPerformanceTests` bundle; `-configuration Benchmark` builds it and
the app with Release's compiler settings (`-O`, whole-module, no
`-enable-testing`) and the development identity (D22), so the test host is
`CortaDev.app` and never the installed Corta. The bundle imports the app
*without* `@testable` — testability inhibits exactly the optimisation this
number exists to see — and so reaches only what the renderer declares
`public`. Every report names the configuration it was built in: the same
plan under the scheme's default configuration is a Debug run, and says
`Debug, -Onone` on its first line.

`CORTA_BASELINE_OUTPUT`, `CORTA_UPLOAD_OUTPUT` and
`CORTA_CONSTRUCTION_OUTPUT` move the three reports, which default to
`/tmp/corta-frame-cpu-baseline.txt`, `/tmp/corta-instance-upload.txt` and
`/tmp/corta-renderer-construction.txt`.

**What the figure includes.** The timed window runs from the `render`
call to `waitUntilCompleted`, so it holds the instance rebuild, the
upload, the encode *and* the GPU's round trip. In Release the CPU side is
the small part: `InstanceUploadBenchmarkTests`' full-rebuild row, which
stops the clock before the commit, reads ~0.13 ms p50 where this one
averages ~0.6 ms, and its p95 is the GPU's scheduling. A change to the
CPU path is best read on that row; the averaged figure stays the D17
baseline so the history below remains comparable.

**The bridge (2026-09-27).** Until 1.1.0 this figure was taken under the
Debug test action (`-Onone`), which is the column §5.6 still shows for
1.0.x. It was re-recorded both ways once, on the same commit, machine and
toolchain, three alternating runs each:

| Build | Frame CPU avg (runs) | Full rebuild p50, CPU only |
| --- | --- | --- |
| Debug, `-Onone` | **2.12 ms** (2.14 / 2.10 / 2.13) | 1.18 ms |
| Release, `-O` | **0.74 ms** (0.82 / 0.68 / 0.74) | 0.13 ms |

Apple M5, macOS 27.0 (26A428), Xcode 27.0 (27A266a), on mains power. The
Debug build spends nine times the CPU on the rebuild; that ratio, not
the GPU wait both share, is what the Debug figure was mostly measuring.

**Shapes that were only there for Debug.** Three render-loop idioms were
written against the Debug figure and were re-measured under Release
before being kept or undone (five alternating runs each, full-rebuild
p50 median, same machine):

| Shape | Release, kept | Release, ordinary Swift | Outcome |
| --- | --- | --- | --- |
| Raw masks instead of `OptionSet.contains` | 0.127 ms | 0.130 ms | Undone — `contains` is elided under `-O` |
| `nil` instead of an empty overrides dictionary | 0.137 ms | 0.132 ms | Undone — no cost to avoid |
| The palette read once per row, not per cell | 0.130 ms | 0.137 ms | Kept — the per-cell global read costs ~5% in Release too |

A fourth shape turned out to be doing real work: removing the
single test that rejects cells with no underline, strikethrough, conceal
or link cost ~8% (0.128 → 0.139 ms), so it stays — spelled as an
`OptionSet` test rather than a mask. After the cleanup the Release figure
is **0.58 ms** avg (0.50 / 0.62 / 0.63; full rebuild p50 0.128–0.135 ms),
which is inside the bridge's spread.

**Metal 4 as the only backend (#109, 2026-09-27).** Same machine,
toolchain and power as the bridge, three runs each side; before is
`main` with the classic path as the default, after is the branch:

| | Before (classic path) | After (Metal 4 only) |
| --- | --- | --- |
| Frame CPU avg | 0.68 ms (0.677 / 0.653 / 0.692) | **0.55 ms** (0.586 / 0.535 / 0.526) |
| Frame CPU p95 | 2.65–2.98 ms | **0.70–0.86 ms** |
| Typing (1 row) p50, CPU only | 0.035 ms | 0.018 ms |
| Scroll (shift + 1 row) p50, CPU only | 0.012 ms | 0.016 ms |
| Full rebuild p50, CPU only | 0.123–0.129 ms | 0.140–0.151 ms |
| Backend construction, warm | 0.000 ms (`QuadRenderer`) | 0.057 ms p50 (`Metal4Backend`) |

The averaged figure and its tail both fall: a frame is now one render
pass, where the classic path ran up to three, each a tile load and store
of its own. The CPU-only rows are not like for like and are recorded as
such: `render` now commits inside its window (the backend owns the
command buffer), and the upload benchmark waits for each frame's GPU
completion outside it, because a frame slot is released only when its
previous frame completes. A warm backend costs 0.06 ms per pane where
`QuadRenderer` cost nothing: each pane's backend owns its own queue,
command buffers, allocators and residency set.


### 5.9 A snapshot's lifetime (#111)

A `Grid` snapshot shares the scrollback's arenas with the reader. While it
lives, the reader's next `Scrollback.push` copies the `batches` array and
the tail arena (up to 256 rows × width × 16 bytes) — once, since the copy
is the reader's own from then on. Until 1.1.0 the frame's snapshot was
held from one `prepareFrame` to the next, so the reader paid that copy
once per frame under any flood; since #109 it is released as soon as it
is diffed.

`corta-bench`'s *feed throughput under a 60 Hz snapshotter* measures the
difference: the reader feeds in the session's 16 KiB lock slices while a
`.userInteractive` thread takes a snapshot under the same lock at 60 Hz,
and drops it at once or holds it to the next tick. Median of three
alternating runs, `-c release`:

| Corpus | No snapshotter | Released at once | Held to the next tick |
| --- | --- | --- | --- |
| `yes` lines (`y\r\n`, 32 MiB) | 53.1 MiB/s | 52.4 MiB/s | 52.1 MiB/s |
| 200-column lines (64 MiB) | 207.6 MiB/s | 199.5 MiB/s | 199.8 MiB/s |

The copy itself, timed on its own — one 200-column line fed into a full
scrollback, 1,000 samples each:

| | p50 | p95 | p99 | max |
| --- | --- | --- | --- | --- |
| Nothing sharing the scrollback | 0.001 ms | 0.001 ms | 0.002 ms | 0.005 ms |
| A snapshot alive (the copy-on-write) | 0.008 ms | 0.014 ms | 0.020 ms | 0.089 ms |

Apple M5, macOS 27.0 (26A428), Xcode 27.0 (27A266a), on battery.
Held and released are inside each other's run-to-run spread, and the
second table says why: the copy is ~8 µs, so a snapshot held across
every frame cost the reader ~0.5 ms a second at 60 Hz — well under the
noise of a throughput run (a one-off run at 2 kHz could not separate the
two either). What a snapshot does cost is the lock hand-off, the ~4%
between no snapshotter and either mode on wide lines, which is the
frame's to pay. The benchmark stays so that a snapshot that starts
outliving its frame again shows up as a number.

Two holders outlive a frame on purpose: a search sweep (`Task.detached`,
for the sweep's duration) and an export (until the save panel's row walk
finishes). Each pays the copy once. A selection drag re-snapshots per
mouse event, so it holds one for at most an event's interval.

### 5.10 Main-actor wakes under a flood (#112)

The reader calls `onOutput` once per parse batch, and a `yes` flood is
tens of thousands of batches a second. Until 1.1.0 each one enqueued a
`Task` on the main actor to resume the display link and restart the
long-task notifier's idle `Timer`. Now each session has an
`OutputWakeGate`: a batch hops only when the gate was idle, and the frame
that takes the flag in `prepareFrame` re-arms it, so a flood wakes the
main actor at most once a frame. The notifier no longer hears about
output at all; its idle timer reads the gate's last-output time when it
fires and re-arms itself for the rest of the grace, which also keeps it
right while a hidden pane's frames are paused. The reader's batch is fed
to the parser as slices of its buffer (`Terminal.feed(_: ArraySlice)`),
not copied into an `Array` per 16 KiB lock slice.

| Measure | Before | After |
| --- | --- | --- |
| `corta-bench`, `yes` at 200 columns, frames taken at 60 Hz | 42,499 batches/s, one hop each | **50 hops/s** |
| The app, Debug, one `yes` pane, 5 s `os_signpost` trace: `output` / `wake` events | 22,014 / 43,904 (a hop per batch) | 22,005 / **167** (as many as `frame`, 167) |
| Release frame CPU (D17), three alternating runs | 0.689 ms avg (0.684 / 0.712 / 0.670) | 0.691 ms avg (0.707 / 0.617 / 0.749) |
| Parser-only / parser + grid / core feed, three alternating runs | 716–768 / 158–161 / 140–144 MiB/s | 739–748 / 164–165 / 143–146 MiB/s |

Apple M5, macOS 27.0 (26A428), Xcode 27.0 (27A266a), on battery. The
signpost counts are intervals' begin and end events, so a hop or a frame
is two. The frame-CPU figure does not move, as it should not: the render
loop is unchanged, and D17 is recorded because the frame's entry point
is. `corta-bench`'s *main-actor wakes under flood* holds the number.
