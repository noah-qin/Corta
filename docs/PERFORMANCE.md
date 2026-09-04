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
xcrun xctrace record --template 'os_signpost' --launch -- \
    /path/to/Corta.app/Contents/MacOS/Corta
```

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

**Attempted, no valid data.** Two Instruments recordings against the
Release build both showed zero `keyDown` and `output` events — only
`wake`/`frame`/`commit`/`gpu` from idle cursor-blink activity — because
the typing done immediately after launching Corta from Instruments'
Record button never reached `TerminalView` (launching a target this way
does not appear to hand it window focus). The question above is still
open; it needs a recording where `keyDown` is confirmed non-zero before
its `output`/`frame` ordering means anything.

One incidental result from those two recordings, unrelated to the
missed-frame question but relevant to §5.4: Instruments' own
`CAMetalLayer.Stalls` track recorded real stalls from idle cursor-blink
redraws alone — 146 stalls averaging 30.6 ms in the first recording, 305
stalls averaging 30.5 ms in the second. Drawable stalling is happening on
this machine at rest, not only under load.

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

**Not yet measured.**

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
