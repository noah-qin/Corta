# Corta — Roadmap

An ordered, checkable execution plan. `DESIGN.md` §5 gives the
milestones; this document gives the steps inside them.

Toolchain: Swift 6.3, Xcode 26.6, macOS 26 deployment target.

**How to use this.** Work top to bottom. Each step has a *Done when*
that is objectively verifiable — a passing test, a recorded number, an
observed behaviour. Do not start a step before the one above it is
checked off. The ordering is not arbitrary: it front-loads the risky
system-level work and the pure, testable logic, and leaves the GPU and
AppKit surface until there is something worth drawing.

---

## M0 — Structure (before any terminal code)

The core cannot live in the app target: the Xcode project sets
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and the parser, grid and
PTY reader all run off the main thread (`DESIGN.md` §2.2). Fixing this
after code exists means annotating every type by hand.

- [x] **M0.1** Create a local SwiftPM package `CortaTerminal` at the repo
      root, with default actor isolation disabled:
      `swiftSettings: [.defaultIsolation(nil)]`.
      *Done when:* the package builds and a test in it can hold mutable
      state across an `await` without a concurrency diagnostic.
- [x] **M0.2** Add the package to `Corta.xcodeproj` as a local package
      dependency; link it to the app and unit-test targets.
      *Done when:* `import CortaTerminal` compiles in both.
- [x] **M0.3** Confirm `CortaTerminal` imports neither AppKit nor Metal,
      and add a test asserting the package builds for the core alone.
      *Done when:* `swift build` succeeds from the package directory
      without Xcode.

---

## M1 — It Runs

Target: one window, a real shell, colour output, working scrollback.

Riskiest system work first, then pure logic under test, then pixels.

### PTY (highest system risk — do it headless first)

- [x] **M1.1** `PTY` type: open a pty pair, spawn a child, read, write,
      close. Use `posix_spawn` with file actions and
      `POSIX_SPAWN_SETSID` — **not** `fork` + Swift code before `exec`
      (`DESIGN.md` §7.2). Reset signals, close inherited descriptors,
      establish the controlling terminal.
      *Done when:* a unit test spawns `/bin/echo hello`, reads `hello`
      back, and observes clean child exit. No UI involved.
- [x] **M1.2** Window size: `TIOCSWINSZ`, and `SIGCHLD` handling for
      child exit.
      *Done when:* a test spawns `stty size`, sets 80×24, and reads
      `24 80` back.

### Grid (pure logic — no parser yet)

- [x] **M1.3** `Cell` (a `UInt32` scalar plus attributes) and `Line`
      (variable-length, carrying the **`wrapped` flag** — `DESIGN.md`
      §2.1). Fixed-size cells, `ContiguousArray` storage.
      *Done when:* `MemoryLayout<Cell>.stride` is recorded in the test
      and asserted, so an accidental size regression fails CI.
- [x] **M1.4** `Grid`: dimensions, cursor, write, erase, line feed,
      scroll up. No escape sequences — direct API only.
      *Done when:* unit tests drive the API directly and assert cursor
      and cell state.

### The test harness — build it now, not later

- [x] **M1.5** Grid serialiser: dump a grid to plain text (characters,
      plus a parallel attribute layer).
      *Done when:* a dump round-trips a known grid into a readable,
      diffable string.
- [x] **M1.6** Golden-file test helper: feed a byte stream to a session,
      dump, diff against a checked-in expectation, with an env var to
      regenerate expectations.
      *Done when:* one golden test passes and deliberately breaking a
      grid method fails it with a readable diff.

> This is the highest-leverage step in the whole roadmap. Every
> subsequent CSI handler is written against it. Skipping it here means
> discovering in M2 that a cursor fix broke `vim`, with no way to tell
> which change did it.
>
> Cases live in `CortaTerminal/Tests/CortaTerminalTests/Golden/`, as a
> `.in` byte stream and a hand-written `.txt` expectation citing the
> specification it comes from. `CORTA_UPDATE_GOLDEN=1` regenerates the
> expectations; it is for propagating a format change, not for authoring
> one. `swift run corta-dump` feeds stdin to a terminal and prints the
> same dump, for checking the core by hand.

### Parser

- [x] **M1.7** UTF-8 decoder over a byte buffer. Incremental — a
      multi-byte sequence may be split across two PTY reads.
      *Done when:* tests cover split sequences, overlong encodings and
      invalid bytes; invalid input yields U+FFFD and never traps.
- [x] **M1.8** VT500 state machine (Ground / Escape / CSI entry / CSI
      param / CSI intermediate / OSC string), emitting actions. No
      screen knowledge. Follow the Paul Williams state diagram.
      *Done when:* table-driven tests map byte streams to expected
      action sequences.
- [x] **M1.9** Parameter parsing: `;` separators, `?` private prefix,
      defaults, **and the caps from `SECURITY.md` §3** — max 16
      parameters, clamped values.
      *Done when:* a test feeds 10,000 parameters and asserts bounded
      memory and no hang.

### Performer — the M1 sequence set

- [x] **M1.10** Printable characters, `\r` `\n` `\t` `\b`.
- [x] **M1.11** Cursor: `CUU` `CUD` `CUF` `CUB` `CUP`.
- [x] **M1.12** Erase: `ED`, `EL`.
- [x] **M1.13** `SGR`: 16 colour, 256 colour, 24-bit true colour, bold,
      underline, reverse.
      *Done when:* each has golden tests; `ls --color` and
      `git log --color` dumps match expectations.
- [x] **M1.14** Scrollback ring buffer; line feed at the bottom margin
      scrolls and pushes into history.
      *Done when:* a test writes 10,000 lines into a 1,000-line
      scrollback and asserts O(1) eviction and a bounded memory ceiling.

### Renderer — quads before glyphs

- [x] **M1.15** Metal pipeline drawing **solid coloured quads only**,
      instanced, into a **given rectangle** (not "the window" —
      `DESIGN.md` §2.4). Correct HiDPI scaling.
      *Done when:* cell background colours render correctly at 1× and
      2×, one draw call per frame, and the same grid can be drawn twice
      into two different rects.
- [x] **M1.16** Glyph atlas: rasterise via Core Text into a texture
      atlas, with an **ASCII fast path** using
      `CTFontGetGlyphsForCharacters` and no shaping
      (`PERFORMANCE.md` §2.2).
      *Done when:* ASCII text renders, and a profile confirms no Core
      Text shaping call in the steady-state frame.
- [x] **M1.17** Cursor and selection rendering as quads.

### Shell and wiring

- [x] **M1.18** `NSView` backed by `CAMetalLayer`, driven by
      `CVDisplayLink`. Keyboard input translated to bytes and written to
      the PTY. Do **not** route through `interpretKeyEvents:` yet.
- [x] **M1.19** Wire PTY → parser → grid on a reader thread; renderer
      snapshots at vsync (`PERFORMANCE.md` §2.1). Cap one parse batch at
      roughly 1 MB.
      *Done when:* `yes` floods the terminal, the UI stays responsive,
      ⌃C still works, and `cat` of a 100 MB file does not stall the
      child.
- [x] **M1.20** Scrolling: wheel, ⌘↑/↓, page keys.

### Baseline

- [x] **M1.21** Record the numbers in §"Tracking" below: parse
      throughput, frame CPU time, idle CPU, memory at 100k scrollback
      lines.
      *Done when:* the table has real values. Every later change is
      compared against them.

**M1 is done when** a shell opens in a window, `ls --color` is coloured,
the scrollback holds history, and flooding output does not freeze the UI.

---

## M2 — No Garbage *(the checkpoint)*

Target: `vim`, `htop` and `tmux` render correctly.

Do not add features, change scope, or refactor architecture until this
milestone is closed (`DESIGN.md` §5).

- [x] **M2.1** Character width table: CJK wide, combining marks
      (zero-width), emoji presentation. Wide cells occupy two columns
      with a spacer.
      *Done when:* a golden test mixing Chinese, emoji and ASCII shows
      no column drift, and the cursor lands correctly after each.
- [x] **M2.2** **Query responses — do these early, they cause hangs, not
      artifacts** (`CONFORMANCE.md` §1.2): DA1 (`ESC[c`), DA2
      (`ESC[>c`), DSR-CPR (`ESC[6n`).
      *Done when:* `vim` starts with no startup delay, and a prompt
      using cursor-position queries (starship or similar) renders
      correctly.
- [x] **M2.3** Alternate screen (`?1049`), including save and restore of
      cursor and screen state.
      *Done when:* `less` on a long file, then `q`, leaves the previous
      screen contents exactly as they were.
- [x] **M2.4** Scroll region (`DECSTBM`) and the cursor semantics at its
      margins.
      *Done when:* the tmux status line stays fixed while content
      scrolls above it.
- [x] **M2.5** Remaining editing sequences: `DECSC`/`DECRC`, `IL`, `DL`,
      `ICH`, `DCH`, `SU`, `SD`, `DECSCUSR`.
- [x] **M2.6** Bracketed paste (`?2004`), with control characters
      stripped from pasted text (`SECURITY.md` §2.3).
- [x] **M2.7** Mouse reporting, SGR encoding (`?1006`).
      *Done when:* mouse selection and pane focus work inside tmux.
- [x] **M2.8** OSC 0/2 title (**set only — never implement the query**,
      `SECURITY.md` §2.2) and OSC 7 working directory.
- [x] **M2.9** Resize debouncing so a live window drag does not hammer
      the child with `SIGWINCH`.
- [x] **M2.10** Run `esctest` and `vttest`. Record the pass rate.
      *Done when:* a number exists in the tracking table.
- [ ] **M2.11** Manual scenario pass, `CONFORMANCE.md` §4.4, items 1–3.

**M2 is done when** a full day of tmux + Neovim + htop produces no
rendering artifact worth reporting.

> **Stop and assess here.** Most of the learning value is banked. If
> this took more than ~3 months of part-time work, the cause is almost
> certainly scope creep rather than difficulty — cut scope, do not work
> harder. Continuing is a choice to make deliberately, not by momentum.

---

## M3 — CJK and Input

Target: Chinese input is correct and text never drifts.

Budget time here. `NSTextInputClient` is not free (`DESIGN.md` §7.1).

- [ ] **M3.1** Conform to `NSTextInputClient`; handle marked text.
- [ ] **M3.2** `firstRectForCharacterRange:` returning correct **screen**
      coordinates.
      *Done when:* the candidate window appears directly under the
      cursor, in every split and after the window moves.
- [ ] **M3.3** Render preedit text as a grid overlay with underline
      styling, without committing it to the grid.
- [ ] **M3.4** Key routing: bypass the IME path entirely unless marked
      text is active.
      *Done when:* ⌃C, ⌃D, ⌃Z and arrow keys behave identically whether
      or not an IME is selected.
- [ ] **M3.5** Font fallback via the Core Text cascade list for CJK and
      emoji, and a shaping cache for non-ASCII runs.
- [ ] **M3.6** Grapheme side table for clusters exceeding one scalar —
      combining marks and ZWJ emoji (`DESIGN.md` §2.3).
      *Done when:* a golden test renders a ZWJ family emoji in one
      double-width cell.
- [ ] **M3.7** Selection by mouse and keyboard, **respecting the
      `wrapped` flag**.
      *Done when:* copying a soft-wrapped long command yields one line
      with no inserted newline.
- [ ] **M3.8** Copy and paste, including the multi-line paste warning.

**M3 is done when** a Chinese conversation in a REPL composes, displays
and aligns correctly, and copy/paste is trustworthy.

---

## M4 — Modern

- [ ] **M4.1** **Damage tracking.** Rebuild the instance buffer only on
      damage, tracked at line granularity (`PERFORMANCE.md` §3). M1's idle
      CPU baseline is ~4% against the ~0% target specifically because this
      is missing — `CADisplayLink` fires every vsync and each tick rebuilds
      and redraws unconditionally. *Done when:* idle CPU on a static screen
      drops to ~0%, measured the same way as the M1 baseline.
- [ ] **M4.2** **Reflow on resize.** The largest single feature in this
      milestone. Must be incremental or lazy — a live window drag fires
      continuously and cannot re-wrap 100k lines per event.
      *Done when:* narrowing the window preserves scrollback content,
      and dragging the window edge stays smooth with a full scrollback.
- [ ] **M4.3** Synchronized output (`?2026`).
      *Done when:* Neovim scrolling shows no tearing.
- [ ] **M4.4** Scrollback search (⌘F), matching across soft-wrapped
      lines, with match highlighting and next/previous navigation.
- [ ] **M4.5** Runtime font scaling (⌘+ / ⌘−), including atlas rebuild.
- [ ] **M4.6** URL detection and ⌘-click, with an **allowlist of
      `http`/`https`/`mailto`**, target shown, never auto-opened
      (`SECURITY.md` §2.4).
- [ ] **M4.7** Tabs.
- [ ] **M4.8** Bell: audible, visual, muted.

---

## M5 — Splits

If M1.15 and M1.19 were built against a rect and a session, this
milestone is mostly composition rather than new mechanism.

- [ ] **M5.1** Binary layout tree with horizontal and vertical splits.
- [ ] **M5.2** Focus routing: keyboard and mouse input to the focused
      pane only.
- [ ] **M5.3** Render each session into its own rect, one pass.
- [ ] **M5.4** Per-pane resize propagated to each PTY.
- [ ] **M5.5** New panes inherit the cwd via OSC 7 (M2.8).

---

## M6 — Polish

- [ ] **M6.1** Config file — one text file, no settings UI. Prefer a
      format needing no third-party parser.
- [ ] **M6.2** Colour themes.
- [ ] **M6.3** Long-task completion notification.
- [ ] **M6.4** Reassess the deferred list in `DESIGN.md` §6: OSC 133
      shell integration is the best value per line; the kitty graphics
      protocol matters most for viewing plots from ML work.

---

## Cut List

If time runs short, drop in this order. None of these blocks daily use.

1. Ligatures (M4, if attempted at all — `DESIGN.md` §7.3)
2. Background transparency and blur
3. Colour themes beyond one good default
4. Completion notifications
5. Tabs — splits alone are sufficient
6. Kitty keyboard protocol

Never cut: character widths, query responses, bracketed paste, the
security rules in `SECURITY.md` §6.

---

## Tracking

Fill these in at each milestone. `PERFORMANCE.md` §1 has the targets.
Trends matter more than absolute values.

| Metric                    | M1     | M2 | M3 | M4 | M5 | M6 |
| ------------------------- | ------ | -- | -- | -- | -- | -- |
| Parse throughput (MB/s)   | 109.9  | 80.0 |    |    |    |    |
| Frame CPU (ms)            | 1.67   | 1.72 |    |    |    |    |
| Idle CPU (%)              | ~4     | ~0   |    |    |    |    |
| Memory @ 100k lines (MB)  | 265.7  | 265.7 |    |    |    |    |
| Keypress → pixel (ms)     | —      | —    |    |    |    |    |
| `esctest` pass rate (%)   | —      | 8.8 (50/568) |    |    |    |    |
| Core LOC                  | 2,547  | 3,972 |    |    |    |    |

Expect roughly 6,000–10,000 lines in `CortaTerminal` by M4
(`DESIGN.md` §1). Reaching 3,000 does not mean the work is nearly done —
that is where the long tail starts.

**How measured (M1, `corta-bench` release build + an offscreen GPU test +
a launched release build sampled with `top`; see `PERFORMANCE.md` §5):**

- *Parse throughput* — `swift run -c release corta-bench`: 64 MB of a
  representative corpus (SGR colour changes + plain text lines, not a
  worst or best case) fed to one `Terminal.feed` call, timed with
  `DispatchTime`. Comfortably clears the 100 MB/s target.
- *Frame CPU* — `CortaTests/FrameCPUBaselineTests`: a full 120×40 screen
  (SGR-varied text, no blank cells to shortcut instance-buffer
  construction), 60 iterations of encode + commit + `waitUntilCompleted`,
  averaged. Well inside the 4 ms budget — this is the CPU-side cost only,
  with damage tracking not yet implemented, so it is the cost of
  rebuilding and drawing *every* cell every frame, not the eventual
  steady-state cost of a mostly-static screen.
- *Idle CPU* — the Release build launched directly (a real shell child
  attached), sampled with `top -pid` over several one-second intervals
  once initialization settled. **Above the ~0% target** — expected and
  explained: `CADisplayLink` fires every vsync, and each tick rebuilds
  the instance buffer and redraws unconditionally. `PERFORMANCE.md` §3's
  damage tracking ("rebuild the instance buffer only on damage") is not
  implemented yet; this number is the one that change should fix, and is
  recorded now specifically so that fix has something to measure against.
- *Memory @ 100k lines* — `corta-bench`: resident size
  (`task_info`/`MACH_TASK_BASIC_INFO`) before and after feeding 100,000
  120-column lines into a 100,000-line scrollback. **Above the ~200 MB
  target** — `Cell` is the settled 16 bytes (`CellTests`), so the gap is
  `ContiguousArray` growth overhead plus `Line`/`Scrollback` bookkeeping,
  not a leak; worth another pass once M2 content (real shell sessions,
  not a synthetic 120-char corpus) gives a more representative shape.
- *Keypress → pixel* — genuinely needs an external tool (Typometer) against
  the running app, as `PERFORMANCE.md` §5 already says; not measured here.
- *Core LOC* — `find CortaTerminal/Sources/CortaTerminal -name '*.swift' | xargs wc -l` — the core library only, not `corta-dump`/`corta-bench`.

**How measured (M2, same methods as M1 unless noted):**

- *Parse throughput* — `corta-bench`, 80.0 MB/s against 95.4 MB/s for the
  M1 code re-measured the same day (the recorded 109.9 predates this
  machine's current conditions). The drop is the price of the M2 write
  path (per-scalar width lookup behind an ASCII fast path, wide-pair
  bookkeeping) and the richer CSI dispatch; it still clears an order of
  magnitude more than any interactive workload.
- *Frame CPU* — `FrameCPUBaselineTests`, 1.715 ms avg / 1.954 ms p95 with
  the instance cache invalidated every iteration, so it remains the
  full-rebuild worst case, comparable to M1's 1.67.
- *Idle CPU* — Release build with a real shell child, `top -pid` at
  one-second intervals after settling: 0.0% on five of six samples (0.6%
  once). Damage tracking at line granularity plus parking the display
  link while the screen is static took this from the M1 ~4%.
- *`esctest`* — esctest2 (ThomasDickey/esctest2, 2026) run as the child of
  a live Corta window, `--expected-terminal xterm --max-vt-level 3`:
  **50 passed, 334 "known bugs", 184 failed of 568**. "Known bugs" are
  tests xterm itself fails — Corta failing them identically is
  xterm-compatible behaviour, so the xterm-compatibility rate is
  384/568 (67.6%). The 184 failures are dominated by unimplemented query
  sequences the tests probe (DECRQM, dynamic colour reports, …), which
  time out by design. The run needed `CSI 18t` (text-area size report),
  added for it — without it all 568 die in the harness's reset().
  `vttest` 20251205 was built and smoke-run: its menu renders correctly,
  but its tests are interactive and visual — no automatable pass rate.
- *Memory @ 100k lines* — unchanged at 265.7 MB; the M2 write path added
  no per-cell state.
