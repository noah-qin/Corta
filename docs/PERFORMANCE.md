# Corta — Performance

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

Set at M1 and defended from then on. A change that regresses one of these
is a bug regardless of what it improves.

| Metric                     | Target                        | Why                                            |
| -------------------------- | ----------------------------- | ---------------------------------------------- |
| Frame budget (CPU)         | **< 4 ms**                    | 120 Hz ProMotion is an 8.3 ms frame            |
| Parser throughput          | **> 100 MB/s** single-thread  | `cat` of a large file must not be the slow part |
| Keypress → pixel latency   | **< 1 frame + input latency** | The metric a user actually feels               |
| Scrollback memory          | **100k 120-column lines within ~200 MB** | Log-heavy ML workloads are a target use case; unstated column count made this unfalsifiable — 120 matches the M1 baseline measurement below |
| Idle CPU                   | **~0%**                       | No redraw when nothing changed                  |

Numbers are recorded at M1 and re-measured at every milestone. "It feels
fast" is not a measurement.

### 1.1 User-visible targets (B01)

§1's table states engineering targets (frame budget, parser throughput) — the
numbers a change is checked against. This table states what those numbers are
*for*: the categories a person actually notices, each with a target stated in
terms a user would recognize and the harness that is supposed to hold it
accountable. Where no repeatable number exists yet, that is stated plainly
rather than filled in with a guess.

| Category      | Target                                              | Held accountable by |
| -------------- | ---------------------------------------------------- | -------------------- |
| Input          | Keypress → pixel feels immediate; §1's latency target | Typometer (§5.1–§5.3), `corta-bench`'s `benchmarkKeypressLatency` |
| Sustained output | A flood (`yes`, a build log, a training run) does not fall behind or drop frames below §1's frame budget | `corta-bench`'s parse-throughput and write-backpressure benchmarks; `scripts/measure-app-baseline.sh` phase B flood |
| Scrolling      | Scrolling a long buffer tracks the pointer/trackpad with no visible stutter | `scripts/measure-render-metrics.sh` (`CORTA_RENDER_METRICS` ring buffer); no dedicated automated scroll benchmark exists yet — a real gap, not an oversight |
| Startup        | A warm launch reaches an interactive window fast enough that switching to Corta does not feel like waiting for an app to open | `scripts/measure-app-baseline.sh` phase A (5 warm launches + 1 cold-ish) |
| Memory         | §1's scrollback figure holds, and closing panes/windows returns memory rather than leaking it | `corta-bench`'s scrollback-footprint and peak-RSS benchmarks; `scripts/measure-app-baseline.sh`'s post-close recovery phase |
| Energy         | An idle pane draws no more power than idle CPU (§1) implies; a flooding pane does not keep the GPU busier than the frames it is actually producing require | No dedicated energy harness exists — Activity Monitor / `powermetrics` spot-checks only, manual and not repeatable. Stated as an open gap rather than a met target |
| Compatibility  | The real-program and esctest pass rates `CONFORMANCE.md` already tracks | `CONFORMANCE.md` §4.2 (esctest), §4.4.2 (real-program table), §4.6 (manual scenario pass) — cross-referenced here rather than duplicated |
| Recovery       | A crashed or force-quit Corta restores its window/split/scrollback state on next launch without asking the user to rebuild it by hand | `scripts/measure-app-baseline.sh`'s SessionRestore-driven multi-pane phases; U07's crash-marker mechanism (`CHANGELOG.md`) |

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

**M9** replaced the live screen's line-granularity check itself —
comparing each row's full `Line` value against the cache — with a
`UInt64` stamp (`Grid.lineRevision(_:)`, bumped centrally by
`ScreenLines` on every row it touches: `ScreenLines.swift`). The
granularity is unchanged, still one row, not one cell; only the cost of
asking "did this row change" dropped, from an `O(row length)` comparison
to one integer compare. Scrolled into history the rows come from
immutable scrollback storage with no such stamp, so that path still
compares `Line` values directly, exactly as before this change
(`TerminalRenderer.rebuildDamagedRows`). The same milestone also merged
the shell's two per-frame `session.snapshot()` + diff calls
(`ViewController.updateDamage`/`render`, now `prepareFrame`/`render`)
into one, since the second was diffing a grid the first had just
diffed moments earlier in the same vsync callback.

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
`QuadRenderer`'s ring buffers already copy the whole array in one
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
  Fixed 200-cell rows over 100k lines is ~320 MB (`DESIGN.md` §2.3).
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

Latency (keypress → pixel) is measured separately with a tool such as
Typometer; it is invisible to throughput benchmarks and is the number
users actually perceive.

**M6 measurement:** Typometer 1.0.1 against a Release build, 200
characters, 150 ms delay, 50 ms period, 1,000 ms length, synchronous mode:
45.5 ms average, 24.8 ms minimum, 56.4 ms maximum, 6.8 ms standard
deviation. The in-process write → PTY echo → parse → grid portion measured
separately at 0.005 ms average / 0.007 ms p95, placing essentially all of
the observed latency after the grid mutation.

**0.1.1 measurement (2026-09-09):** Typometer 1.0.1, same settings — 200
characters, 150 ms delay, 50 ms period, 1,000 ms length, synchronous, no
intermediate pauses — against the Release build at commit `12ac1b8`:
**57.8 ms average, 45.3 ms minimum, 78.9 ms maximum, 5.6 ms standard
deviation** over 200 samples.

The §5.2 table as held for this run: MacBook Air, Apple M5 (Mac17,3),
macOS 26.6.2; Release build; built-in Liquid Retina at 60 Hz, native 2x
(2940×1912 pixels, 1470×956 points); System Monospaced 12 pt, the default;
120×30, one pane, not full screen; mains power; nothing else in the
foreground; **test program `cat > /dev/null`**, so the tty echoes and no
shell line editor is between the keystroke and the screen.

**Against M6.12's 45.5 ms this is 12.3 ms worse, and the comparison is
weaker than it looks.** M6.12 recorded its Typometer settings and not its
test program, and neither run recorded the machine beyond "MacBook Air,
Apple silicon" — §5.2's own first row. So the two runs are known to differ
in at least one variable that was never written down, and possibly in the
machine. What can be said is that this run's environment *is* recorded, in
full, so the next one has something to be compared against.

This also closes what M9 owed. M9 measured 70.1 ms for the default
configuration in an environment §5.2's table was not held for, and flagged
that it could not be read against 45.5 ms. It still cannot; what exists now
is a properly held measurement of the same configuration, which is the
number future work should move.

**Still not §5.1-shaped.** Typometer reports minimum, maximum, average and
standard deviation — not p50, p95 and p99. That is exactly the shape §5.1
objects to, and it is a limit of the tool rather than a choice: the
percentiles need the raw samples exported and summarised. `corta-bench`
reports all four for the parts of the path it can see.

**The percentile-shaped alternative for the render stage (B01).** Between
`corta-bench` (headless, core-only) and a full Typometer run (end-to-end,
but avg/min/max/SD only) sits `CORTA_RENDER_METRICS=1`
(`RenderMetrics.swift`'s 600-sample ring buffer, streamed by
`scripts/measure-render-metrics.sh`): it dumps real p50/p99 for `cpuFrame`,
`drawableWait` and `gpu` from a live, on-screen app, without Instruments.
Its limit is the opposite of Typometer's: it needs a person at the keyboard
typing and scrolling for the ring to fill with real frames (the
`scripts/measure-app-baseline.sh` finding that synthetic System Events keystrokes
never reach `TerminalView` applies here too — a scripted flood through the
PTY slave fills `drawableWait`/`gpu`, but `cpuFrame` specifically wants real
keyDown-triggered frames), so running it and reading its output is recorded
here as the next step, not as something this pass produced a number for.

**Establish the baseline at M1.** Without a baseline, "performance is the
first priority" is a slogan rather than a constraint.

### 5.1 Report distributions, never averages

Every latency number in this document must carry **p50, p95, p99 and the
maximum**. `corta-bench` reports all four (`LatencyDistribution`); the
M6 Typometer figure above predates the rule and is reported as its
average, which is exactly the shape of the problem.

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

**A fresh headless sample (B01, 2026-09-10, this machine — see §5.2's
toolchain table below).**

```sh
swift build --package-path CortaTerminal -c release --product corta-bench
CortaTerminal/.build/release/corta-bench
```

| Benchmark | p50 | p95 | p99 | max | n |
| --- | --- | --- | --- | --- | --- |
| keypress → grid latency | 0.009 ms | 0.012 ms | 0.013 ms | 0.020 ms | 2,000 |
| keypress → grid latency, flooding neighbour | 0.009 ms | 0.012 ms | 0.015 ms | 0.046 ms | 2,000 |
| snapshot latency under flood | 0.000 ms | 0.000 ms | 0.000 ms | 0.032 ms | 2,000 |
| search response, 100k-line scrollback (warm) | 385.1 ms | 410.6 ms | 442.6 ms | 442.6 ms | 50 |

Parser-only throughput 628.3 MiB/s, parser+grid 141.1 MiB/s, core feed
130.0 MiB/s — all above §1's 100 MB/s target. Scrollback at 100k lines:
185.0 MB resident, inside §1's ~200 MB target. Full raw output, including
the resize-delivery, spawn-decomposition and multi-pane-fixed-cost
benchmarks not tabulated above, is reproducible with the command above; it
is headless and scripted, so — unlike the Typometer numbers below — this
much of §5.2's table is trivially held exactly by running it again. This is
core-side only; it says nothing about the AppKit/render stages §5.3 and
§5.4 cover, which is exactly the boundary `scripts/measure-app-baseline.sh` and
`CORTA_RENDER_METRICS` exist to close.

### 5.2 The fixed benchmark environment

Numbers recorded in this document or in `ROADMAP.md` are only comparable
against numbers taken the same way. Any run that is quoted must state:

| Variable          | Fixed at                                              |
| ----------------- | ----------------------------------------------------- |
| Machine           | The recorded machine and chip (M6: MacBook Air, Apple silicon) |
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

**Toolchain (B01).** Compiler, SDK, language mode and deployment target are
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

A run quoted without this table is a run from before B01 that predates the
distinction — not a claim that it used a different toolchain.

### 5.3 Attributing latency: `os_signpost`

An end-to-end number says whether the last change helped. It cannot say
*where* the time goes, and each stage has a different fix — so the whole
chain emits `os_signpost` intervals (`Corta/InputLatencySignposts.swift`),
subsystem `dev.noahqin.Corta`, category `input-latency`:

| Signpost  | Covers                                              |
| --------- | --------------------------------------------------- |
| `keyDown` | key event → bytes written to the PTY                |
| `output`  | a parse batch has been applied to the grid (a point, not an interval — it is emitted on the reader thread) |
| `wake`    | the MainActor hop that un-parks the display link    |
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
span — confirms this is not where the M6.12 45.5 ms figure goes.

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

Corta ships the default (3), which is what the M6 figure was measured
against. `CORTA_MAX_DRAWABLES=2` sets it for one launch, so the
comparison is two launches of the same binary rather than a code change.
Pair it with a signpost trace: if double buffering is costing rather than
saving, it appears as the `frame` interval growing at its front.

**Preliminary signal, not the A/B itself.** `RenderMetrics`
(`Corta/RenderMetrics.swift`, `CORTA_RENDER_METRICS=1`,
`scripts/measure-render-metrics.sh`) reports `drawableWait` — how long
`nextDrawable()` blocks — directly, without Typometer or Instruments. One
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
Typometer A/B this section is still waiting on — that is the only way to
turn "probably not worth it" into a number — but reason enough to
de-prioritize it behind M8.19 and M9's own measurement pass.

**The Typometer A/B itself.** `scripts/measure-drawable-ab.sh` launches
the same Release build twice, back to back, so the only variable between
the two Typometer runs is `CORTA_MAX_DRAWABLES`. Same machine, same
Typometer settings as §5.5 (200 chars / 150 ms delay / 50 ms period /
1,000 ms length, synchronous mode, no intermediate pauses), mains power,
Corta frontmost with nothing else running:

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
Typometer settings; §5.2's environment table was not fully controlled for
this pair either, e.g. other background load on the machine varied
between sessions. The A vs. B *comparison* is still valid, since both
runs shared whatever that day's uncontrolled conditions were — only the
absolute numbers should not be cross-cited against §5.5's.)

### 5.5 Cross-terminal comparison

Typometer 1.0.1, 200 characters / 150 ms delay / 50 ms period / 1000 ms
length, synchronous mode, same machine, same font (system monospaced,
12 pt), power connected, target app frontmost with nothing else running:

| Terminal | Min, ms | Max, ms | Avg, ms | SD, ms |
| -------- | ------- | ------- | ------- | ------ |
| Corta    | 32.8    | 64.1    | 45.4    | 8.1    |
| iTerm2   | 28.1    | 63.0    | 42.7    | 7.7    |
| Ghostty  | 17.8    | 45.2    | 31.9    | 5.9    |

Corta is slower on average than iTerm2 and noticeably slower than
Ghostty on this machine. (Terminal.app is missing — Typometer would not
measure it; figures above are Typometer's min/max/avg/SD, not the §5.1
percentile distribution.)

---

## 6. B11 — CPU, locking and memory hot-path pass (2026-09-13)

**Locking.** `TerminalSession` already carries exactly one hot-path lock
(`state: Mutex<State>`, guarding the parser, grid and scrollback
together) plus the `stateWaiters`/`yieldToStateWaiters` anti-starvation
mechanism a prior pass added and `TerminalSessionLockWaitTests` already
holds to a 100 ms per-wait / 30 s total ceiling under a `yes` flood. This
pass re-ran that measurement rather than restructuring lock ownership:
`corta-bench`'s snapshot-latency-under-flood benchmark reports p50/p95/p99
all 0.000 ms and max 0.030–0.032 ms on this machine, level with the
figure already on record in §5.1. No batch-budget or ownership change is
justified by that number.

**Copy-on-write / allocation cost.** `Scrollback` already packs rows into
shared batch arenas (`Batch`, ≤256 rows each) rather than one
`ContiguousArray` per row — a prior pass's fix for the growth-headroom
waste `corta-bench`'s `diagnoseScrollbackFootprint` still reports
(608 B/row slack, 57 MB at 100k lines, entirely in the *live-screen* ring
`ScreenLines` uses, which cannot use the same batching since its rows are
still being edited). `snapshot()` itself is an O(1) struct copy
(`Grid`/`ScreenLines`/`Scrollback` are all value types over
`ContiguousArray`); the actual deep-copy cost is deferred COW, paid one
row at a time by whichever side next mutates it. Measured scrollback
footprint at 100k×120-column lines: 185.0 MB, inside §1's ~200 MB target
and unchanged from the last recorded figure — this pass made no change
here; the existing batching already addresses what "immutable blocks"
would otherwise be evaluating.

**ASCII fast path.** Both existing fast paths (`Parser.parse([UInt8],
performer:)`'s run scan; `Grid.writeASCII`/`Line.overwriteASCII`'s
batched cell write) read/wrote through `Array`/`ContiguousArray`
subscripting, which re-checks bounds and the exclusivity flag on every
element even though each scan/write's range is already fixed before it
starts. Both now go through `Span` (`Array.span`, Swift 6.2): the
run-boundary scan in `Parser.swift` indexes `bytes.span` instead of
`bytes`, and `Line.overwriteASCII`'s inner loop writes through
`cells.withUnsafeMutableBufferPointer`. `Span` was chosen over a raw
`UnsafeBufferPointer` for the parser scan specifically because it keeps
the lifetime/exclusivity reasoning checked by the compiler against
`bytes`' scope rather than resting on the caller's manual promise inside
an `withUnsafeBufferPointer` closure — `Line.overwriteASCII` still needs
the closure form because it *writes*, and `Span`'s mutable counterpart
(`MutableSpan`) is not yet what `ContiguousArray` exposes on this
toolchain.

Measured, `-c release`, this machine, 5 runs each before/after (noise
band shown as the full min–max spread rather than one sample, per §5.1's
spirit — `corta-bench`'s own harness reports percentiles only for the
latency benchmarks, not throughput):

| Benchmark | Before | After |
| --- | --- | --- |
| Parser-only throughput | 643.6–650.5 MiB/s | 635.3–684.3 MiB/s |
| Parser + grid throughput | 144.0–145.6 MiB/s | 144.9–154.1 MiB/s |
| Core feed throughput | 129.7–130.9 MiB/s | 128.2–139.5 MiB/s |

The grid-write side (`Line.overwriteASCII`) shows a consistent, real gain
— parser+grid and core-feed throughput both moved up across every
sample, never below the old range. The parser-only scan's gain is
smaller and its range now overlaps the old one at the bottom end; kept
anyway because it is never worse than the old code in any sample taken,
and because `Span` is the safer construct at no measured cost, which is
worth keeping on its own terms even where the throughput case is weak.
All 541 `CortaTerminalTests`, the 18 golden-file cases and a 500,000-input
`corta-fuzz` run against `Tests/Fuzz/corpus` (`--seed 1` and `--seed 2`)
stayed green throughout — no correctness change, byte-identical golden
output.

**Span, borrowing and `@specialize` more broadly.** `Span` is now used at
the two boundaries above; extending it further (e.g. `Grid.write`'s
single-scalar path) found nothing to gain — that path has no
array-range loop left to bounds-check-eliminate, it is one table lookup
per call already behind `@inline(__always)`. `borrowing`/`consuming`
parameters were not introduced: every hot-path type here is a small
value (`Cell`, `UInt32`, `UInt8`) where a `borrowing` annotation changes
nothing measurable, and the one place a large value crosses a call
boundary (`Grid` itself, at `snapshot()`) is COW-cheap already, not a
copy `borrowing` would avoid. `@_specialize` was evaluated and not added:
`Parser.parse<P: ParserPerformer>` and `Performer` are both defined in
`CortaTerminal`, and every production call site (`Terminal.feed`,
`corta-bench`) calls it with the concrete `Performer` type from within
the same module, so whole-module optimization (SwiftPM's release default)
already specializes and devirtualizes it — an explicit `@_specialize`
annotation exists to buy this across a module boundary that does not
exist here, and adding one changed nothing in either binary size or the
throughput numbers above (not tabulated: confirmed and reverted).

**Not attempted.** Restructuring `state`'s single-lock ownership (e.g.
splitting parser/grid from scrollback under separate locks) was
considered and rejected: the measured wait times above show no
contention problem to justify it, and `TerminalSession`'s own header
comment already documents why a single lock plus the waiter-yield
mechanism was chosen over finer-grained locking. Widening the ASCII
fast path itself (SIMD-scanning the printable range, or admitting C0
controls into a run instead of ending it) was not attempted this pass —
`Span`'s subscript is not the vectorizing kind of win a real SIMD compare
would be, and that is a larger, separate change with its own
before/after case to make.
