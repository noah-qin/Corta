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

- [ ] **M1.3** `Cell` (a `UInt32` scalar plus attributes) and `Line`
      (variable-length, carrying the **`wrapped` flag** — `DESIGN.md`
      §2.1). Fixed-size cells, `ContiguousArray` storage.
      *Done when:* `MemoryLayout<Cell>.stride` is recorded in the test
      and asserted, so an accidental size regression fails CI.
- [ ] **M1.4** `Grid`: dimensions, cursor, write, erase, line feed,
      scroll up. No escape sequences — direct API only.
      *Done when:* unit tests drive the API directly and assert cursor
      and cell state.

### The test harness — build it now, not later

- [ ] **M1.5** Grid serialiser: dump a grid to plain text (characters,
      plus a parallel attribute layer).
      *Done when:* a dump round-trips a known grid into a readable,
      diffable string.
- [ ] **M1.6** Golden-file test helper: feed a byte stream to a session,
      dump, diff against a checked-in expectation, with an env var to
      regenerate expectations.
      *Done when:* one golden test passes and deliberately breaking a
      grid method fails it with a readable diff.

> This is the highest-leverage step in the whole roadmap. Every
> subsequent CSI handler is written against it. Skipping it here means
> discovering in M2 that a cursor fix broke `vim`, with no way to tell
> which change did it.

### Parser

- [ ] **M1.7** UTF-8 decoder over a byte buffer. Incremental — a
      multi-byte sequence may be split across two PTY reads.
      *Done when:* tests cover split sequences, overlong encodings and
      invalid bytes; invalid input yields U+FFFD and never traps.
- [ ] **M1.8** VT500 state machine (Ground / Escape / CSI entry / CSI
      param / CSI intermediate / OSC string), emitting actions. No
      screen knowledge. Follow the Paul Williams state diagram.
      *Done when:* table-driven tests map byte streams to expected
      action sequences.
- [ ] **M1.9** Parameter parsing: `;` separators, `?` private prefix,
      defaults, **and the caps from `SECURITY.md` §3** — max 16
      parameters, clamped values.
      *Done when:* a test feeds 10,000 parameters and asserts bounded
      memory and no hang.

### Performer — the M1 sequence set

- [ ] **M1.10** Printable characters, `\r` `\n` `\t` `\b`.
- [ ] **M1.11** Cursor: `CUU` `CUD` `CUF` `CUB` `CUP`.
- [ ] **M1.12** Erase: `ED`, `EL`.
- [ ] **M1.13** `SGR`: 16 colour, 256 colour, 24-bit true colour, bold,
      underline, reverse.
      *Done when:* each has golden tests; `ls --color` and
      `git log --color` dumps match expectations.
- [ ] **M1.14** Scrollback ring buffer; line feed at the bottom margin
      scrolls and pushes into history.
      *Done when:* a test writes 10,000 lines into a 1,000-line
      scrollback and asserts O(1) eviction and a bounded memory ceiling.

### Renderer — quads before glyphs

- [ ] **M1.15** Metal pipeline drawing **solid coloured quads only**,
      instanced, into a **given rectangle** (not "the window" —
      `DESIGN.md` §2.4). Correct HiDPI scaling.
      *Done when:* cell background colours render correctly at 1× and
      2×, one draw call per frame, and the same grid can be drawn twice
      into two different rects.
- [ ] **M1.16** Glyph atlas: rasterise via Core Text into a texture
      atlas, with an **ASCII fast path** using
      `CTFontGetGlyphsForCharacters` and no shaping
      (`PERFORMANCE.md` §2.2).
      *Done when:* ASCII text renders, and a profile confirms no Core
      Text shaping call in the steady-state frame.
- [ ] **M1.17** Cursor and selection rendering as quads.

### Shell and wiring

- [ ] **M1.18** `NSView` backed by `CAMetalLayer`, driven by
      `CVDisplayLink`. Keyboard input translated to bytes and written to
      the PTY. Do **not** route through `interpretKeyEvents:` yet.
- [ ] **M1.19** Wire PTY → parser → grid on a reader thread; renderer
      snapshots at vsync (`PERFORMANCE.md` §2.1). Cap one parse batch at
      roughly 1 MB.
      *Done when:* `yes` floods the terminal, the UI stays responsive,
      ⌃C still works, and `cat` of a 100 MB file does not stall the
      child.
- [ ] **M1.20** Scrolling: wheel, ⌘↑/↓, page keys.

### Baseline

- [ ] **M1.21** Record the numbers in §"Tracking" below: parse
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

- [ ] **M2.1** Character width table: CJK wide, combining marks
      (zero-width), emoji presentation. Wide cells occupy two columns
      with a spacer.
      *Done when:* a golden test mixing Chinese, emoji and ASCII shows
      no column drift, and the cursor lands correctly after each.
- [ ] **M2.2** **Query responses — do these early, they cause hangs, not
      artifacts** (`CONFORMANCE.md` §1.2): DA1 (`ESC[c`), DA2
      (`ESC[>c`), DSR-CPR (`ESC[6n`).
      *Done when:* `vim` starts with no startup delay, and a prompt
      using cursor-position queries (starship or similar) renders
      correctly.
- [ ] **M2.3** Alternate screen (`?1049`), including save and restore of
      cursor and screen state.
      *Done when:* `less` on a long file, then `q`, leaves the previous
      screen contents exactly as they were.
- [ ] **M2.4** Scroll region (`DECSTBM`) and the cursor semantics at its
      margins.
      *Done when:* the tmux status line stays fixed while content
      scrolls above it.
- [ ] **M2.5** Remaining editing sequences: `DECSC`/`DECRC`, `IL`, `DL`,
      `ICH`, `DCH`, `SU`, `SD`, `DECSCUSR`.
- [ ] **M2.6** Bracketed paste (`?2004`), with control characters
      stripped from pasted text (`SECURITY.md` §2.3).
- [ ] **M2.7** Mouse reporting, SGR encoding (`?1006`).
      *Done when:* mouse selection and pane focus work inside tmux.
- [ ] **M2.8** OSC 0/2 title (**set only — never implement the query**,
      `SECURITY.md` §2.2) and OSC 7 working directory.
- [ ] **M2.9** Resize debouncing so a live window drag does not hammer
      the child with `SIGWINCH`.
- [ ] **M2.10** Run `esctest` and `vttest`. Record the pass rate.
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

- [ ] **M4.1** **Reflow on resize.** The largest single feature in this
      milestone. Must be incremental or lazy — a live window drag fires
      continuously and cannot re-wrap 100k lines per event.
      *Done when:* narrowing the window preserves scrollback content,
      and dragging the window edge stays smooth with a full scrollback.
- [ ] **M4.2** Synchronized output (`?2026`).
      *Done when:* Neovim scrolling shows no tearing.
- [ ] **M4.3** Scrollback search (⌘F), matching across soft-wrapped
      lines, with match highlighting and next/previous navigation.
- [ ] **M4.4** Runtime font scaling (⌘+ / ⌘−), including atlas rebuild.
- [ ] **M4.5** URL detection and ⌘-click, with an **allowlist of
      `http`/`https`/`mailto`**, target shown, never auto-opened
      (`SECURITY.md` §2.4).
- [ ] **M4.6** Tabs.
- [ ] **M4.7** Bell: audible, visual, muted.

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

| Metric                    | M1 | M2 | M3 | M4 | M5 | M6 |
| ------------------------- | -- | -- | -- | -- | -- | -- |
| Parse throughput (MB/s)   |    |    |    |    |    |    |
| Frame CPU (ms)            |    |    |    |    |    |    |
| Idle CPU (%)              |    |    |    |    |    |    |
| Memory @ 100k lines (MB)  |    |    |    |    |    |    |
| Keypress → pixel (ms)     |    |    |    |    |    |    |
| `esctest` pass rate (%)   | —  |    |    |    |    |    |
| Core LOC                  |    |    |    |    |    |    |

Expect roughly 6,000–10,000 lines in `CortaTerminal` by M4
(`DESIGN.md` §1). Reaching 3,000 does not mean the work is nearly done —
that is where the long tail starts.
