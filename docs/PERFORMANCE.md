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
        ▼  CVDisplayLink (vsync)  snapshot taken here, at most 1× per frame
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

**Establish the baseline at M1.** Without a baseline, "performance is the
first priority" is a slogan rather than a constraint.
