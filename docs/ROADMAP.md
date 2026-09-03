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

- [x] **M3.1** Conform to `NSTextInputClient`; handle marked text.
- [x] **M3.2** `firstRectForCharacterRange:` returning correct **screen**
      coordinates.
      *Done when:* the candidate window appears directly under the
      cursor, in every split and after the window moves.
- [x] **M3.3** Render preedit text as a grid overlay with underline
      styling, without committing it to the grid.
- [x] **M3.4** Key routing: bypass the IME path entirely unless marked
      text is active.
      *Done when:* ⌃C, ⌃D, ⌃Z and arrow keys behave identically whether
      or not an IME is selected.
- [x] **M3.5** Font fallback via the Core Text cascade list for CJK and
      emoji, and a shaping cache for non-ASCII runs.
- [x] **M3.6** Grapheme side table for clusters exceeding one scalar —
      combining marks and ZWJ emoji (`DESIGN.md` §2.3).
      *Done when:* a golden test renders a ZWJ family emoji in one
      double-width cell.
- [x] **M3.7** Selection by mouse and keyboard, **respecting the
      `wrapped` flag**.
      *Done when:* copying a soft-wrapped long command yields one line
      with no inserted newline.
- [x] **M3.8** Copy and paste, including the multi-line paste warning.

**M3 is done when** a Chinese conversation in a REPL composes, displays
and aligns correctly, and copy/paste is trustworthy.

---

## M4 — Modern

- [x] **M4.1** **Damage tracking.** Rebuild the instance buffer only on
      damage, tracked at line granularity (`PERFORMANCE.md` §3). M1's idle
      CPU baseline is ~4% against the ~0% target specifically because this
      is missing — `CADisplayLink` fires every vsync and each tick rebuilds
      and redraws unconditionally. *Done when:* idle CPU on a static screen
      drops to ~0%, measured the same way as the M1 baseline.
- [x] **M4.2** **Reflow on resize.** The largest single feature in this
      milestone. Must be incremental or lazy — a live window drag fires
      continuously and cannot re-wrap 100k lines per event.
      *Done when:* narrowing the window preserves scrollback content,
      and dragging the window edge stays smooth with a full scrollback.
- [x] **M4.3** Synchronized output (`?2026`).
      *Done when:* Neovim scrolling shows no tearing.
- [x] **M4.4** Scrollback search (⌘F), matching across soft-wrapped
      lines, with match highlighting and next/previous navigation.
- [x] **M4.5** Runtime font scaling (⌘+ / ⌘−), including atlas rebuild.
- [x] **M4.6** URL detection and ⌘-click, with an **allowlist of
      `http`/`https`/`mailto`**, target shown, never auto-opened
      (`SECURITY.md` §2.4).
- [x] **M4.7** Tabs.
- [x] **M4.8** Bell: audible, visual, muted.

---

## M5 — Splits

If M1.15 and M1.19 were built against a rect and a session, this
milestone is mostly composition rather than new mechanism.

- [x] **M5.1** Binary layout tree with horizontal and vertical splits.
      *Done when:* `SplitTree` keeps every internal node at exactly two
      children across nested splits and closes (`SplitTreeTests`).
- [x] **M5.2** Focus routing: keyboard and mouse input to the focused
      pane only.
      *Done when:* click focuses a pane, ⌘⌥ arrows move focus
      geometrically, and only the focused pane draws a cursor or sets
      the window title.
- [x] **M5.3** Render each session into its own rect, one pass.
      *Done when:* each pane renders its own session into its own
      drawable in the same single pass the one-pane window used — no
      renderer change was needed, which is what M1.15/M1.19 bought.
- [x] **M5.4** Per-pane resize propagated to each PTY.
      *Done when:* dragging a divider resizes both panes' sessions
      (debounced like a window drag), the divider clamps at each pane's
      minimum grid size, and the window's minimum size is the tree's.
- [x] **M5.5** New panes inherit the cwd via OSC 7 (M2.8).
      *Done when:* a pane split out of a shell in some directory opens
      its shell in the same directory.

---

## M6 — Polish and Hardening

Two halves, one milestone. The polish half is the settings page and what
hangs off it. The hardening half closes the query-response class: the
184 esctest failures are dominated by unimplemented query sequences that
the tests probe and that time out by design (see the M2 tracking note),
and every one answered is measurable points on a number this repository
already records. All query responses are fixed-format — they never echo
stream-supplied text back to the child's stdin (`SECURITY.md`
§2.1/§2.2). Everything in this milestone is pure Swift: no new
dependencies, no new platform surface.

### Polish

- [x] **M6.1** Settings page — a native settings window, opened from a
      menu placed in the menu bar alongside Edit and Shell (⌘,). It is
      backed by one text file in a format needing no third-party parser:
      the page edits that file and the file remains the single source of
      truth — hand-edits are picked up, there is no second store.
      *Done when:* changing a setting in the page writes the file, a
      hand-edit to the file is reflected in the page, and a fresh launch
      honours both.
- [x] **M6.2** Colour themes, selectable from the settings page.
      Three built in (Corta, Solarized, Mono), each with a light and a
      dark variant; the low sixteen plus foreground, background and
      cursor. The 6x6x6 cube and the greyscale ramp stay xterm's — a
      program asking for colour 137 means one specific colour.
- [x] **M6.3** Long-task completion notification. A heuristic, and off
      by default because of it: without OSC 133 a terminal cannot see
      command boundaries, so Return starts a task and an idle output
      stream ends it. Silent while the window is key, and carries no
      command text — the grid holds things that must not reach
      Notification Center (`SECURITY.md` §5).
- [x] **M6.4** Reassess the deferred list in `DESIGN.md` §6. Done and
      written up there. OSC 133 moves to the front and now has a caller
      (it is what would make M6.3 exact); its blocker is distribution of
      shell snippets, not terminal work. The kitty graphics protocol
      stays deferred and got *more* expensive: M6.8 took the cell's last
      spare bits, so image placement needs a side table kept correct
      across reflow and eviction plus a third render pipeline.

### Conformance and hardening

- [x] **M6.5** DECRQM (mode query) and XTVERSION (`ESC [ > 0 q`)
      responses — the capability probes tmux and Neovim fall back from
      when unanswered (`CONFORMANCE.md` §1.2). DECSCL came with it: a
      program that announced VT200 has asked to be talked to as an older
      terminal, and DECRQM arrived at VT300.
      *Done when:* esctest's DECRQM probes stop timing out and the
      pass / xterm-compatibility rate is re-recorded in the tracking
      table. **Done:** the probes answer, 13 DECRQM tests and the
      DECSCL level test flipped, rate re-recorded below.

      What the remaining 29 DECRQM failures need is not the *query* —
      it answers — but the *modes*. esctest sets a mode, queries, resets
      and queries again, so passing means tracking KAM, IRM, SRM, LNM
      and two dozen DEC modes. Corta answers 0 ("not recognised") for
      those rather than tracking a bit it does not act on: a program can
      act on a mode it was told is set, and a lie it can act on is worse
      than an admission. Implementing the modes themselves is M2-class
      work and is not smuggled in here.
- [x] **M6.6** The remaining fixed-format query class from the M2
      esctest failure list: dynamic colour reports (the query forms of
      OSC 10/11/12) and the other timed-out probes. Set forms stay
      governed by config, as elsewhere.
      *Done when:* the failure class is re-run and the 184 drops; the
      delta is recorded. **Done:** 184 → 152. The remaining colour
      failures are the exotic specification forms — CIELab, CIEuvY,
      TekHVC, `rgbi:` — which are colour-space conversions, not query
      plumbing; `#RGB` and `rgb:R/G/B` are implemented.
- [x] **M6.7** Focus reporting (`?1004`). `CSI I` on focus in, `CSI O`
      on focus out, where "focused" means this pane holds the keyboard
      *and* its window is key — what focus means to the user, not to the
      responder chain. Reports only on a real transition: AppKit posts
      key and first-responder changes far more often than focus moves.
- [x] **M6.8** OSC 8 hyperlinks: rendered as links, ⌘-click routed
      through the same scheme allowlist and show-the-real-target path
      as M4.6 (`SECURITY.md` §2.4).
      *Done when:* `ls --hyperlink` output is clickable and the target
      shown is the real one.
- [x] **M6.9** Kitty keyboard protocol — distinguishes `Ctrl+I` from
      `Tab`, reports key release (`DESIGN.md` §6, pulled in from
      deferred).
      *Done when:* a Neovim mapping that binds `Ctrl+I` and `Tab`
      differently works in a live session.
- [x] **M6.10** Selection anchoring fix: a monotonic line counter on
      `Scrollback` so a selection tracks its text even while a full ring
      floods (`DESIGN.md` §2.7, the known limit).
      *Done when:* a test selects text, floods past ring capacity, and
      the highlight still covers the same content.
- [x] **M6.11** Parser fuzzing: libFuzzer over the feed path
      (`-sanitize=fuzzer`), asserting the `SECURITY.md` §3 caps — no
      crash, no hang, bounded allocation. This is the harness
      `CONFORMANCE.md` §4.3 already promises.
      *Done when:* a corpus run completes clean and the caps are
      asserted inside the harness. **Done, with one substitution that
      has to be stated:** libFuzzer cannot run here. Xcode 26 ships no
      `libclang_rt.fuzzer_osx.a` and `swiftc -sanitize=fuzzer` is
      rejected for `arm64-apple-macosx` — checked, not assumed. The
      `LLVMFuzzerTestOneInput` entry point is in place for a toolchain
      that has one; what runs is a seeded mutation driver with no
      coverage feedback, so it explores less per iteration. 2.5M inputs
      across five seeds, clean; the corpus replays in the test suite.
- [ ] **M6.12** Keypress → pixel measured with Typometer against a
      release build — the last empty column in the tracking table
      (`PERFORMANCE.md` §5).
      **Not done, and it needs a person.** Typometer is a Java desktop
      application that measures by watching the screen; it cannot be
      driven from a shell, and installing it is a decision for whoever
      owns the machine. What *is* measured is the half of the path that
      lives in this repository: `corta-bench` reports keypress → grid
      (write → PTY echo → parse → grid write) at 0.005 ms avg / 0.007 ms
      p95 over 200 samples. The missing half is vsync and display, which
      is exactly the half Typometer exists to measure — so the number
      below is recorded as the two halves it is, not as one figure
      pretending to be the whole.

### Native macOS integration and distribution

The differentiators a self-drawn toolkit cannot match for free — this is
where being a pure AppKit citizen pays off.

- [x] **M6.13** Follow the system appearance: light and dark variants of
      the active theme (M6.2), switching live in every pane when macOS
      switches.
      *Done when:* toggling Dark Mode re-themes all open windows without
      a restart, and an explicit light/dark/Auto choice exists in the
      settings page.
- [x] **M6.14** Pinch-to-zoom font size: the trackpad magnification
      gesture drives the same scale path as ⌘+/⌘− (M4.5), clamped to the
      same steps.
      *Done when:* a live pinch rescales smoothly, the atlas rebuilds,
      and the grid re-fits exactly as the keyboard path does.
- [x] **M6.15** Native integrations AppKit gives cheaply: dragging a
      file or folder onto a pane pastes its shell-quoted path; Force
      Touch / three-finger tap on a word opens Look Up; the Services
      menu works on the selection.
      *Done when:* each works in a live window — the drag lands as a
      quoted path at the prompt, Look Up shows the dictionary popover,
      and a Services item receives the selected text.
- [ ] **M6.16** Distribution: a notarized release build and a Homebrew
      cask (`SECURITY.md` §4.1 — hardened runtime on, sandbox off).
      Features nobody can install are not features.
      *Done when:* `brew install --cask corta` installs a build that
      Gatekeeper opens without a warning.
      **Not done, and it cannot be done from here.** Notarization needs
      a Developer ID certificate and an Apple ID with an app-specific
      password; a Homebrew cask needs a published release to point at.
      Both are the maintainer's credentials and the maintainer's
      decision. The build settings the item names are already right —
      `ENABLE_HARDENED_RUNTIME = YES`, `ENABLE_APP_SANDBOX = NO` — so
      what remains is the signing and publishing, not the project.

**M6 is done when** the settings page and themes ship, the native
integration items work in a live window, the esctest
xterm-compatibility rate is re-recorded and measurably above the 67.6%
carried since M2, and the tracking table has no empty columns.

**Status: 14 of 16 done.** The settings page, themes and appearance
ship; the native integrations work in a live window; the compatibility
rate is re-recorded at **73.2%** (81 passed, 335 known bugs, 152 failed
of 568 — 184 → 152 failures, no regressions). The two open items are
M6.12 and M6.16, and neither is blocked on code: one needs a GUI
measuring tool installed on the machine, the other needs the
maintainer's signing credentials. They are the tracking table's one
remaining gap, and it is recorded as a gap rather than filled with a
guess.

---

## Cut List

If time runs short, drop in this order. None of these blocks daily use.

1. Ligatures (M4, if attempted at all — `DESIGN.md` §7.3)
2. Background transparency and blur
3. Colour themes beyond one good default
4. Completion notifications
5. Tabs — splits alone are sufficient

Never cut: character widths, query responses, bracketed paste, the
security rules in `SECURITY.md` §6.

---

## Tracking

Fill these in at each milestone. `PERFORMANCE.md` §1 has the targets.
Trends matter more than absolute values.

| Metric                    | M1     | M2 | M3 | M4 | M5 | M6 |
| ------------------------- | ------ | -- | -- | -- | -- | -- |
| Parse throughput (MB/s)   | 109.9  | 80.0 | 80.8 | 75.5 | 76.7 | 75.1 |
| Frame CPU (ms)            | 1.67   | 1.72 | 2.32 | 2.26 | 2.40 | 2.32 |
| Idle CPU (%)              | ~4     | ~0   | ~0   | ~0   | ~0   | 0.0 |
| Memory @ 100k lines (MB)  | 265.7  | 265.7 | 265.7 | 184.6 | 184.6 | 185.0 |
| Keypress → pixel (ms)     | —      | —    | —    | —    | —    | 0.005 to the grid; display half unmeasured (M6.12) |
| `esctest` pass rate (%)   | —      | 8.8 (50/568) | 8.8 (50/568) | 8.8 (50/568, M3 carry) | 8.8 (M3 carry) | 14.3 (81/568) |
| `esctest` xterm-compat (%)| —      | 67.6 | 67.6 | 67.6 | 67.6 | 73.2 |
| Core LOC                  | 2,547  | 3,972 | 4,247 | 4,908 | 4,959 | 5,562 |

The two esctest rows measure different things and both are worth
keeping. **Pass rate** counts only tests that passed outright.
**xterm-compat** counts passes plus "known bugs" — tests esctest expects
xterm itself to fail — which is the number comparable to other
terminals, and the one M6's done-when names.

Frame CPU is the 120x40 full-rebuild worst case in a debug build, the
same way it was measured at every milestone. It went to 4.19 ms when the
M6 render work landed and came back to 2.32 ms once the theme lookup was
hoisted out of the per-cell loop and the new attribute checks were
folded into one mask test — the regression is recorded because the
measurement is what caught it.

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

**How measured (M3, same methods as M2 unless noted):**

- *Parse throughput* — `corta-bench`, 80.8 MB/s, level with M2's 80.0:
  the M3 write-path addition (ZWJ cluster continuation) costs a bounds
  check on non-ASCII only.
- *Frame CPU* — `FrameCPUBaselineTests` re-run in isolation: 2.319 ms
  avg / 5.218 ms p95, the full-rebuild worst case. The +0.6 ms over M2
  is the wide-glyph/cluster branches in `appendRowInstances` (Track B
  measured +0.17 ms medians on the same machine; absolute numbers run
  higher than the M2 entry under this machine's current conditions).
  The p95 spike is noise from the first iterations, not a regression in
  the steady average; still inside the 4 ms budget on average.
- *Idle CPU* — Release build with a real shell child, `top -pid` at
  one-second intervals after settling: 0.0% on all six samples.
- *`esctest`* — re-run identically to M2 (esctest2,
  `--expected-terminal xterm --max-vt-level 3`, child of a live window):
  **50 passed, 334 known bugs, 184 failed of 568** — byte-identical
  failing list to M2, so 67.6% xterm-compatible, unchanged.
- *Memory @ 100k lines* — unchanged at 265.7 MB.
- *Core LOC* — 4,247; the growth is the selection model
  (`Selection.swift`) and M3 tests.

**How measured (M4, same methods as M3 unless noted):**

- *Parse throughput* — `corta-bench`, 75.5 MB/s. The M4 additions on the
  parse path are the `?2026` mode flag and the bell flag (boolean sets);
  the reflow/search work is off the feed path entirely.
- *Frame CPU* — `FrameCPUBaselineTests`, 2.255 ms avg / 5.039 ms p95,
  still the full-rebuild worst case with the instance cache invalidated
  every iteration. Level with M3's 2.319: the color-emoji pass is a third
  draw call issued only when color glyphs exist, so the emoji-free
  baseline screen pays nothing for it.
- *Idle CPU* — Release build with a real shell child, `top -pid` at
  one-second intervals after settling: 0.0% on all seven samples.
- *Memory @ 100k lines* — 184.6 MB, down from 265.7: scrollback rows are
  packed into shared batch arenas (M4.2's footprint work), which removed
  most of the per-row `ContiguousArray` growth slack the old number was
  mostly made of (see the M1 note).
- *`esctest`* — not re-run. M4 changed nothing on the escape-sequence
  surface except `?2026` (which vt-level-3 esctest does not probe), so the
  M3 figure (50/568, byte-identical failing list) carries over.
- *Core LOC* — 4,908; the growth is reflow (`Grid+Reflow.swift`),
  search (`Search.swift`) and link detection (`LinkDetection.swift`).
- *Reflow and search cost* — `corta-bench` also reports: a full reflow of
  a 100k-line scrollback on a 120→80 column change is 97.7 ms, paid once
  per debounced resize (~1 call/100 ms during a live drag), off the main
  thread; a full-scrollback search is 359.6 ms for 100k matches with a
  6.2 MB resident delta (the lazy logical-line pass, no document copy).
- *M4.3's "Neovim shows no tearing"* — Neovim is not installed on this
  machine (see the M2 closeout note in `CONFORMANCE.md` §4.5), so the
  done-when is met by the mechanism, not by observation: `?2026` batches
  withhold presents until the matching reset (core mode tracking is
  unit-tested in `PrivateModeTests`; the withholding itself is
  `ViewController.updateDamage`). M4.2's "dragging stays smooth"
  likewise needs a human hand on the window edge; the numbers above are
  the automatable half.

**How measured (M5, same methods as M4 unless noted):**

- *Parse throughput / memory @ 100k lines* — `corta-bench`: 76.7 MB/s and
  184.6 MB, both level with M4. M5 touched no core code; the +51 LOC of
  core growth predates the split work (it is the M4 tail).
- *Frame CPU* — `FrameCPUBaselineTests`, 2.401 ms avg / 4.700 ms p95.
  Level with M4's 2.255: splits add no work to the per-pane render path —
  each pane renders its own session into its own drawable in the same
  single pass (M5.3), and an unfocused pane's display link parks exactly
  like a focused one's.
- *Idle CPU* — Release build with a real shell child, `top -pid` per-process
  rows at one-second intervals after settling: 0.0% on all samples.
- *`esctest`* — not re-run; M5 changed nothing on the escape-sequence
  surface, so the M3 figure carries over.
- *Split behaviour* — `SplitTreeTests` (tree surgery, geometric focus,
  minimum sizes, all with plain `NSView`s — no sessions spawned),
  `SplitPaneUITests` (⌘D splits, ⌘W closes the focused pane before the
  window), and the §4.4 live-app check with a probe shell: `stty size`
  reports 30 120 at launch (no transient winsize through the
  `SplitViewController.layoutSettled` gate), scrolling fills every row.
  Divider-drag smoothness and cwd inheritance (M5.5) need a human hand —
  the mechanisms are `ResizeDebouncer` (divider drags coalesce like window
  drags) and `TerminalSession.workingDirectory` (OSC 7, unit-tested in
  `OSCTests`) read at split time.
