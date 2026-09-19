# Corta — Design

[Documentation index](README.md) · [Project overview](../README.md)

A native macOS terminal emulator written in Swift, with an AppKit shell,
Metal rendering and an independent terminal core.

This document describes 1.0.0 and the development tree on `main` since it.
The B01–B16 implementation batches shipped in 1.0.0; the download is linked
from [the README](../README.md#install). Historical milestone plans live in
[history/](history/), and current limitations are listed in
[Features](FEATURES.md#known-limits).

---

## 1. Goals and Constraints

Every trade-off in this repository derives from this table. If a proposal
conflicts with a row here, the row wins.

| Dimension    | Decision                          | Rationale                                                        |
| ------------ | --------------------------------- | ---------------------------------------------------------------- |
| Platform     | **macOS only**                    | A single target lets us use the fastest native API directly       |
| Performance  | **First priority**                | The bottleneck is the GPU pipeline design, not the language       |
| Complexity   | **Small, not heavy**              | Anything the OS or tmux can do, we do not reimplement             |
| Language     | **Pure Swift**                    | One language end to end, no FFI, memory layout tuned for the grid |
| Rendering    | **Metal** (no wgpu/abstraction)   | One platform needs no portability layer                           |
| Text shaping | **Core Text**                     | Best CJK fallback, emoji and ligature quality on macOS            |
| Shell / IME  | **AppKit** (SwiftUI optional)     | CJK input, clipboard and key handling come for free               |

**The accepted core trade-off:** we write the VT parser ourselves. In
exchange we get zero FFI, the tightest possible system integration, and a
single-language codebase. The cost is maintaining protocol correctness,
resource limits and a regression suite alongside the parser.

---

## 2. Locked Decisions

These constrain data structures. Changing one later means a rewrite, not
a patch. They are settled — do not relitigate them without a concrete
reason.

### 2.1 Lines carry a `wrapped` flag from day one

A line that reached the right margin and continued onto the next row must
record that fact. This is required by three separate features:

- **Reflow** on window resize (otherwise narrowing the window corrupts
  scrollback permanently),
- **Selection** across a soft-wrapped line (otherwise copying a long
  command inserts a spurious newline),
- **Search** matching across a wrap boundary.

The flag is part of every line. Reflow of a large scrollback must be
incremental or lazy, because a live window drag fires resize continuously.

### 2.2 The terminal core is not `@MainActor`

The PTY reader, parser and grid run off the main thread. The Xcode
project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which is
correct for the AppKit shell and wrong for the core.

Therefore the core lives in a **local SwiftPM package** (`CortaTerminal`)
with default isolation disabled. Side benefit: the core is unit-testable
and benchmarkable without launching an app.

### 2.3 Cells are fixed-size; complex graphemes spill to a side table

A cell stores a `UInt32` word plus attributes and two 16-bit table keys,
16 bytes in total, asserted by `CellTests`. Grapheme clusters that
do not fit in one scalar (combining marks, emoji ZWJ sequences such as
`👨‍👩‍👧‍👦`) store a tag pointing into an interned side table.

**That `UInt32` is now fully spent.** Unicode's codespace ends at
U+10FFFF, so a scalar needs 21 bits; the other 11 hold the OSC 8
hyperlink id (M6.8), keyed into a second interned side table. The
alternative was an 18-byte cell, and `PERFORMANCE.md` §4 measures what
that costs across a 100k-line scrollback. Anything else wanting per-cell
identity — an image placement, for one — needs a side table keyed by
document position instead of a new field.

Rows are **variable length** — stored up to the last non-blank cell. A
fixed 200-cell row over 100k scrollback lines is ~320 MB, which is not
acceptable for the log-heavy workloads this terminal targets.

### 2.4 Everything is multi-viewport from day one

Rendering and input routing are written against a `TerminalSession` and a
target rectangle, never against "the window". Splits (M5) then become
"instantiate more sessions" rather than a rewrite of the renderer.

The core owns no global state and no singletons.

### 2.5 `$TERM` is `xterm-256color`

A benevolent lie. Announcing a custom value requires shipping a terminfo
entry to every remote host over SSH; until conformance is proven, that
trades a cosmetic gain for broken remote sessions. Revisit only after the
conformance targets in `CONFORMANCE.md` are met.

### 2.6 Reading the PTY is never blocked by rendering

See `PERFORMANCE.md` §2. The single most important performance property:
if we stop draining the PTY, the child process blocks on `write`, and the
terminal becomes the reason a training job is slow.

### 2.7 Selection is anchored to the document, not the viewport

Selection coordinates are document coordinates (`CortaTerminal/Selection.swift`):
row ≥ 0 is a live-screen row, row < 0 addresses the scrollback counting
backwards from the screen boundary (row −1 is the newest history line).
A selection therefore survives the user scrolling, and when output pushes
lines into the scrollback the stored rows shift by the growth — the
highlight follows its text. The rules that consult the grid live in the
core, not the shell:

- **Copying a soft-wrapped line yields one line** with no inserted
  newline, and trailing blanks are trimmed from every other copied line.
- **Word selection** covers letters, digits and `_ - . /` — a path
  selects as one word. Triple-click selects the logical line, following
  `wrapped` in both directions.

The anchoring shift is computed from `Scrollback.totalPushed`, a
monotonic count of every line ever pushed (M6.10). `scrollback.count`
cannot do that job: it saturates at the ring's limit, so once the ring is
full every push evicts a row while the count reports no growth, and a
selection anchored on it drifted onto whatever text arrived underneath
it. The counter keeps rising, so the shift is right whether the ring is
filling or flooding.

Reflow (M4.2) and search (M4.4) must preserve these invariants: reflow
rewrites document rows wholesale and must invalidate or re-anchor any
live selection, and search matches must be reported in the same document
coordinates so a match can be selected verbatim.

**Every consumer shifts by `totalPushed`, through one mapping.**
`ScrollbackCoordinates` (core) is the single translation between a stored
document row and the live grid for viewport anchoring, selection, search,
command navigation and image placement — both ends of a copied selection
included. It exists because the render path once shifted by
`scrollback.count` while `⌘C` shifted by `totalPushed`: once a ring
saturated, the highlight and an image placement drifted onto the wrong row
while the copied text stayed right, and the two silently disagreed (B04).
The render cache's invalidation key is `totalPushed` for the same reason —
a `.count` comparison stops noticing that scrollback changed once the ring
is full. Pinned by `ScrollbackCoordinatesTests` and
`SelectionRendererTests.selectionTracksItsLineAfterTheRingSaturates`.

**A column change clears the selection and the scroll offset.** Only a
column change reflows (`Grid.resize` rebuilds `Scrollback`, resetting
`totalPushed`), so `resizeSessionToFitView` clears both when the new column
count differs from the last requested one; a row-only resize is ordinary
scrollback growth and is left alone. The path is gated on
`SplitViewController.sizeSettled`, which the offscreen test target never
reaches, so it is verified by launching the app and narrowing a window
(`CONFORMANCE.md` §4.4).

**`scrollOffset` is a document position, not a row count.**
`ViewController.scrollAnchorTotalPushed` records `totalPushed` whenever the
offset changes while off the bottom, and `prepareFrame` shifts the offset by
the growth in that total on every output batch, so the text a person
scrolled to stays under the pointer as output arrives; ring eviction still
clamps an offset whose rows are gone. Typing and pasting
(`returnToBottomOnInput`) return the viewport to the bottom, because input
is the user's request to talk to the live screen, whereas output arriving
while they read is deliberately left alone. Pinned by
`ScrollIndicatorIntegrationTests` (`scrolledOffsetStaysAnchoredAsOutputArrives`,
`typingWhileScrolledReturnsToTheBottom`, `returnToBottomOnInputOnlyActsWhenScrolled`).

**A drag ends when the window loses key status mid-gesture** (⌘-Tab, a
global shortcut opening a window, Mission Control) rather than
`nextEvent(matching:)` blocking on drag events for a window nobody is
looking at — the same early return the pane-closed-mid-drag case uses.
Like the rest of `handleSelectionMouseDown` it runs inside a real window's
blocking event loop, which the offscreen target cannot drive, so it is
verified by parity with the tested pane-close guard rather than by its own
regression case.

**A TUI that owns the mouse owns the gesture.** Mouse event subscriptions
(`?1000`, `?1002`, `?1003`) are tracked separately from SGR encoding
(`?1006`): normal tracking sends press, release and wheel; button-event
tracking adds held-button motion; any-event tracking adds motion with no
button, coalesced to cell changes. While tracking and SGR encoding are both
on, a plain drag goes to the program; holding `mouse-override-modifier`
(Option by default) at mouse-down selects terminal text for that whole
gesture even if the modifier is released before mouse-up, and a pane-local
first-use hint says so (`MouseReportingTests` in the app, `PrivateModeTests`
in the core).

**Selection stays hand-rolled.** `NSTextView`/TextKit was prototyped
against these invariants and not adopted — `DECISIONS.md` D19 has the
four reasons and what it would have bought.

---

## 3. Architecture

```
┌───────────────────────────────────────────────────────────────┐
│  MAIN THREAD — AppKit shell                                   │
│  NSWindow / tabs / split layout tree / key bindings           │
│  NSTextInputClient (CJK IME, marked text)                     │
└──────────┬──────────────────────────────────┬─────────────────┘
           │ key, mouse, paste                │ CAMetalDisplayLink (vsync)
           │                                  │
           ▼                                  ▼
┌──────────────────────┐         ┌──────────────────────────────┐
│  PTY layer           │         │  Metal renderer              │
│  posix_spawn + pty   │         │  glyph atlas (Core Text)     │
│  TIOCSWINSZ, SIGCHLD │         │  instanced quads, one pass   │
└──────────┬───────────┘         │  renders into a given rect   │
           │ bytes               └──────────────▲───────────────┘
           │                                    │ snapshot
           ▼                                    │
┌───────────────────────────────────────────────┴───────────────┐
│  READER THREAD — terminal core (CortaTerminal)                │
│  Parser (VT500 state machine) → Performer → Grid              │
│  Scrollback (ring buffer) · AltScreen · ScrollRegion          │
└───────────────────────────────────────────────────────────────┘
```

Data flows one way: **bytes in → grid → pixels**. Input flows the other
way: **key/IME → PTY → child**. Nothing else crosses those arrows.

Windows are cheap composition: each window is a `SplitViewController`
owning a binary split tree whose leaves are `ViewController` +
`TerminalSession` pairs (⌘N instantiates the storyboard scene again;
`AppDelegate` retains the window controllers until their windows close).
Nothing is shared between windows — that is what §2.4 buys.

The two thread boundaries are the interesting part of this diagram:

- **PTY/parse → render** is a snapshot taken at vsync, not a push. The
  parser runs as fast as data arrives; the renderer runs at most once per
  frame and always reads a consistent grid.
- **Main thread → PTY** is a write; the main thread never touches the
  grid directly.

---

## 4. Modules

| Module              | Where                                | Isolation   | Responsibility                                       |
| ------------------- | ------------------------------------ | ----------- | ---------------------------------------------------- |
| `Parser`            | `CortaTerminal`                      | nonisolated | UTF-8 decode + VT500 state machine, no screen knowledge |
| `Performer`         | `CortaTerminal`                      | nonisolated | Applies parsed actions to the grid; decides every reply |
| `Grid`              | `CortaTerminal`                      | nonisolated | Cells, cursor, attributes, scroll region, alt screen |
| `Scrollback`        | `CortaTerminal`                      | nonisolated | Ring buffer of variable-length lines                 |
| `TerminalSession`   | `CortaTerminal`                      | nonisolated | Owns PTY + Parser + Grid; the unit a split renders   |
| `PTY`, `corta-exec` | `CortaTerminal`                      | nonisolated | Spawn, read/write, winsize, child lifecycle          |
| `SFTP`              | `CortaTerminal/…/SFTP/`              | nonisolated | The SFTP protocol over the system `ssh`, no SSH library (§7.9) |
| Renderer            | `Corta/Renderer/`                    | nonisolated | `TerminalRenderer`, `QuadRenderer`, `GlyphAtlas`, the MTL3 and Metal 4 backends; draws a session into a rect, driven from the display link |
| Font stack          | `Corta/Renderer/`                    | nonisolated | `TerminalFont`, `MonospacedFontCatalog`, `CellMetrics`: Core Text shaping, fallback, verification, the ASCII fast path |
| Shell               | `Corta/`                             | MainActor   | Windows, tabs, the split tree, key bindings, IME, settings, shell integration, remote context |

`CortaTerminal` must not import AppKit or Metal (`PackageIsolationTests`
and `ModuleBoundaryTests` hold that line).

---

## 5. Milestones

The original M1–M10 plan and its measurements are preserved in
[the 0.1 roadmap](history/ROADMAP-0.1.md). The completed B01–B16 implementation
batches are in the [v1 milestone](https://github.com/noah-qin/Corta/milestone/1).
Neither is a list of remaining work; consult open issues for follow-up tasks.

---

## 6. Non-Goals

Explicitly out of scope. Each has been considered and rejected.

| Not doing                                     | Why                                                        |
| --------------------------------------------- | ---------------------------------------------------------- |
| Built-in multiplexer (daemon, attach/detach)  | tmux exists and is better; heaviest possible feature        |
| Cross-platform                                | Forfeits Metal and Core Text, the entire premise            |
| tmux control mode (`-CC`)                     | A second protocol *and* a second window model; same cost class as building a multiplexer |
| AI features, command blocks, cloud sync       | Conflicts with "small, not heavy"                           |
| Automation that runs commands (a "run this" intent or URL) | An external input reaching a child's stdin; `SECURITY.md` §4.6. Open/focus intents ship; execution does not |
| Implementing SSH or git                       | They are programs running on a PTY; rendering correctly is the whole job |
| Bidirectional text (RTL)                      | Large complexity, and a security footgun (see `SECURITY.md`) |
| Terminal title *query* responses              | Command injection vector; see `SECURITY.md` §2.2            |

The native Settings window edits the same text configuration file as a
manual edit; it is not a separate settings store.

### Deferred, not rejected

- **Kitty graphics:** direct RGB, RGBA and PNG transmission and placement
  are implemented. Animation and Unicode-placeholder placement remain out
  of scope. File-based transmission is rejected because terminal output must
  not cause arbitrary local files to be read; see [Security](SECURITY.md).
- **Shell integration:** OSC 133 command boundaries and installable zsh
  hooks are implemented. Bundled bash and fish hooks remain unavailable.
- **Kitty keyboard:** implemented; see [Conformance](CONFORMANCE.md).

#### M6.4 — the reassessment

The original ordering decision is recorded in [the roadmap](history/ROADMAP-0.1.md).
The resulting graphics implementation uses `ImagePlacementTable` and the
existing colour-quad pipeline. Column resize discards live image placements
rather than reflowing image geometry; clients can place retained images again.

---

## 7. Known Hard Parts

Ordered by how badly they are usually underestimated.

### 7.1 CJK IME is not free

`NSTextInputClient` provides marked text, but
`firstRectForCharacterRange:` must return correct *screen* coordinates
or the candidate window lands in the wrong place; preedit text must be
drawn into the grid as an overlay without being committed to it; and
`interpretKeyEvents:` swallows control keys the terminal needs.

As implemented (M3.1–M3.4, `TerminalView+IME.swift`,
`TerminalView+Keyboard.swift`):

- The conformance must be **declared** on the view — `NSView` does not
  conform by default, and its `inputContext` is nil until it does.
- Routing: an event carrying ⌘ or ⌃ bypasses the IME entirely; every
  other event is offered to `inputContext.handleEvent(_:)` first and
  falls through to direct byte translation only when unconsumed. The
  input context consumes more than text keys — Return, Delete, Escape,
  the arrows, Tab and Shift-Tab come back through `doCommand(by:)`, and
  forwarding those there is load-bearing: without it they are silently
  eaten. Tab is the sharp case (B02): plain, unmodified Tab and
  Shift-Tab carry neither ⌘ nor ⌃, so they are always offered to the
  input context first, and any candidate UI — a shell completion menu,
  an IME — that resolves the keystroke as a command rather than
  `insertText` sends it to `doCommand(by:)` as `insertTab(_:)` /
  `insertBacktab(_:)`. Those two cases forward `0x09` and the same
  `CSI Z` backtab sequence `TerminalView+Keyboard.swift` already sends
  for the direct (non-IME) path, and deliberately do not participate in
  the kitty-protocol disambiguate re-encoding — Tab, Enter and
  Backspace stay legacy there regardless of which path delivered them.
- Committed text arrives via `insertText(_:replacementRange:)` and is
  written to the PTY there. Marked text is app-layer only — never the
  grid, never the PTY — drawn by `MarkedTextOverlayView` over the cells
  at the cursor with the IME's underline styling intact. The overlay
  must be layer-backed (`wantsLayer`); the terminal view is
  layer-hosting, and a subview without a backing layer never composites
  over the Metal layer — the preedit is silently invisible.
- `firstRect` converts the cursor cell to screen coordinates on demand,
  so it stays correct after the window moves.
- Verification caveat: synthetic key events — `NSEvent.keyEvent(with:)`
  in tests, or `CGEvent`s with `keyboardSetUnicodeString` — carry baked
  characters, which an IME treats as already-translated text;
  composition never opens for them. Live IME verification needs
  character-less HID-level events; see `CONFORMANCE.md` §4.4.

### 7.2 `fork` in a Cocoa process

Between `fork` and `exec` only
async-signal-safe functions are legal, and the Swift runtime is not —
touching `String`, allocating, or retaining can deadlock. Resolved by
not calling `fork()` at all: `CortaTerminal/Spawn.swift` `posix_spawn`s
a small helper executable (`corta-exec`, its own SwiftPM product) onto
the pty replica, with `POSIX_SPAWN_SETSID` and file actions dup'ing the
replica to fds 0/1/2. `posix_spawn_file_actions_t` cannot express
`ioctl(TIOCSCTTY)` — required on Darwin because a session leader does
not acquire a controlling terminal merely by having the tty on fd 0 —
so `corta-exec` does that one call and then `execve`s over itself into
the real shell. Because `corta-exec` is a freshly `execve`'d image
rather than a forked one, there is no fork-in-a-multithreaded-process
hazard to mitigate: ordinary Swift throughout, no C helper, no FFI.
This replaced an earlier `fork`-based implementation that pre-marshalled
every argument into C buffers before forking and still `SIGKILL`ed the
child roughly 8% of the time under test — a hazard serializing this
process's own `fork()` calls could not remove, because it came from
locks other threads held at the moment of the call, not from this
process's own concurrency.

### 7.3 Ligatures conflict with a one-glyph-per-cell atlas

A Fira Code
ligature spans cells and does not align to the grid, and a cursor
inside a ligature must break it. Treat as P2, or accept the
simplification that the cursor row disables ligatures.

### 7.4 Glyph atlas eviction

A 2048×2048 atlas holds roughly 2,000 glyphs
at typical sizes. A CJK session exceeds that easily. Resolved at M3 with
the strategy Alacritty uses: shelf packing cannot reclaim individual
slots without fragmenting, so a full page is *reset* — caches cleared,
allocator rewound — and glyphs re-rasterise on demand. A `generation`
counter on `GlyphAtlas` lets the renderer detect a mid-build reset and
rebuild once, since every UV issued before the reset is stale. A screen
whose live content alone exceeds one page cannot be served by any
eviction policy; those cells draw blank.

### 7.5 Text rendering weight

macOS has had no subpixel antialiasing
since Mojave. Naively alpha-blending grayscale-AA glyphs makes light
text on a dark background look visibly thinner than Terminal.app.
Gamma-corrected blending or stem darkening is needed to match.

### 7.6 Ownership and synchronization audit (B03)

Every mutable-state
owner on the input/output path, and what makes each one safe to touch
from more than one thread:

| Owner | Isolation | Mechanism |
|---|---|---|
| `Parser`, `Performer`, `Grid`, `Scrollback` | `nonisolated` | Pure value types / state machines; mutated only while `TerminalSession.state`'s lock is held. |
| `TerminalSession` | `nonisolated`, `@unchecked Sendable` | `Synchronization.Mutex` around every mutable field (`State`, `Callbacks`, `PendingWrites`, `stopped`, `started`, `requestedResize`). Verified case by case (`docs/history/V0.1.1-ENGINEERING-AUDIT.md` A02); no `@unchecked` is load-bearing on its own. |
| `PTY` | `nonisolated`, `@unchecked Sendable` | Same pattern: a `Mutex<State>` around the exit/reaping/closed flags a descriptor's use depends on (S08). |
| AppKit shell (`ViewController`, `SplitViewController`, `AppDelegate`, `TaskNotifier`) | `@MainActor` (project default) | The Xcode target's `SWIFT_DEFAULT_ACTOR_ISOLATION`; see §2.2 for why the core opts out instead. |

The PTY reader is a dedicated `Thread`, not a `Task` (§2.2, §2.6): it
calls `onOutput`/`onChildExit` directly from that thread, and the shell
is responsible for hopping to `@MainActor` — never the other way
around. Every such hop needs to know two things a bare `[weak self]`
does not tell it: whether the controller is still alive (`weak` answers
that) and whether it is still the controller *for this session*
(`sessionGeneration`, `ViewController.swift`, answers that). A pane can
in principle run `setUpPane()` twice on the same, still-alive instance
(a retry after a failure); `sessionGeneration` is bumped each time and
captured by that session's callbacks at install time, so a callback
from a session a later `setUpPane()` has since replaced is a no-op
instead of mutating state that belongs to a different session. The one
precedent this generalises is older and narrower:
`ViewController+Search`'s `searchRefreshGeneration` guards a detached
background sweep's result the same way, scoped to search alone.

`onChildExit` (`TerminalSession`) is fully built — replay-safe if
installed after the child already exited — but was never installed by
the app before B03, so a child that exited on its own (`exit`, a crash,
`kill`) produced no reaction; `teardown()`'s own `SIGHUP`-driven exit
goes through the identical callback, and `didTeardown` (already the
guard against a second `teardown()`) is what tells the two apart —
`sessionGeneration` alone would not, since a user-initiated close never
installs a new session to bump it for.

### 7.7 Search state that looked pane-local was not, all the way (B05)

`ViewController+Search.swift`'s query, match list, current-match index
and anchor were already stored per pane — but `search-case-sensitive`
and `search-regex` were read live from `ConfigurationStore` on every
sweep, so toggling either in one pane silently changed what a second,
already-open pane's *next* sweep matched, without that pane's own button
ever updating to say so. Fixed by seeding `searchCaseSensitive`/
`searchRegex` from the config default when a bar opens, using only that
local copy for sweeps and for the button tint, and writing back to
`ConfigurationStore` only as the default for bars opened after this one.

A related gap one level up: `NSEvent.addLocalMonitorForEvents` fires
app-wide, and B02 scoped its Esc handler to the event's own *window* —
but a split puts two panes, each with an open bar, in one window, where
the window check alone can't tell them apart. Fixed by additionally
comparing the window's field-editor delegate against this pane's own
`searchField`.

`scheduleBackgroundSearchRefresh` (M9) drops an output-triggered refresh
request outright when a sweep is already in flight, on the reasoning
that "the next output frame starts a fresh sweep as soon as this one
lands" — true only while output keeps arriving. At the tail of a burst,
nothing else re-triggers a sweep once the render loop pauses, so the
last few lines of a flood could go unsearched until an unrelated
keystroke or scroll happened to nudge it. Fixed with a `searchNeedsRefresh`
flag, set instead of dropped, consumed once the in-flight sweep lands.

`scrollOffsetBeforeSearch`, restored verbatim on close, has the same
drift problem §2.7 documents for a selection: a raw offset does not
track output that arrived while the bar was open. Fixed the one
instance of it (not the general `scrollOffset` anchoring problem, still
open — see B04's item above) by shifting the restore by the growth in
`Scrollback.totalPushed` since the bar opened, the same pattern a
selection's `baseScrollbackTotal` already uses.

Large copy (⌘C/⌘A) and export (⇧⌘S) built their text — `Selection.text`,
O(the range, which for the whole document is O(scrollback)) —
synchronously on the *main actor*, which is the interaction path in this
app (§2.2). Both now run that build on `Task.detached`, a compiler-level
guarantee of leaving the main actor rather than an inference — a plain
`Task {}` created from `@MainActor` code inherits that isolation for its
body, so relying on a nonisolated callee to implicitly escape it again
would be exactly the fragile assumption this fix replaces. A shared
`largeTextTask` handle, generation-guarded together with `didTeardown`,
keeps a superseded build's completion — or the pane's own, from
`teardown()` — from touching state that no longer belongs to it.
`Task.cancel()` here only ever discards a build's result, though: neither
`Selection.text` nor `exportableText` polls cancellation internally (M9's
`Search.find` does), so an in-flight row walk runs to completion off the
main actor regardless of whether it is later applied — see
`ViewController.swift`'s own doc comment on `largeTextTask` for the exact
line this was found and fixed to state accurately, after an earlier draft
of this paragraph overclaimed it. `Data.write(options: .atomic)` already
made the file write itself atomic (`ViewController+Export.swift`, tested
by `ExportWriteTests`) — that half of the issue needed no change.

### 7.8 Three conformance gaps closed, two more scoped and declined (B06)

`CSI s` / `CSI u` (SCOSC/SCORC) were not dispatched at all — a program
that saved and restored the cursor with the CSI form rather than
DECSC/DECRC (`ESC 7`/`ESC 8`) got nothing back. Corta has no DECLRMM
(left/right margins), so xterm's own behaviour without that mode is to
treat both forms as unconditional aliases; fixed by routing `0x73`/
`0x75` in `Performer+Cursor.performCursorControl` to the existing
`grid.saveCursor()`/`restoreCursor()`. The kitty keyboard protocol's
marker-based `CSI u` forms are intercepted earlier in `csiDispatch` and
never reach this switch, so the alias cannot shadow them —
`SaveRestoreCursorTests.bareCSIuDoesNotTouchKittyProtocol` asserts that
directly rather than by inspection.

OSC 4 (indexed-palette set/query) and OSC 104 (reset) were entirely
unimplemented — a program picking colour 137 by number, or resetting
its overrides on exit, got silence for the query and a no-op for the
set. Added `IndexedPalette` (mirrors `DynamicColors`'s shape: `defaults`
seeded once, a sparse `overrides` dictionary OSC 4 writes into and OSC
104 clears), wired through `PerformerState`/`Terminal`/
`TerminalSession` the same way `dynamicColors` already was, and seeded
`defaults` from `Theme.Variant.indexedPaletteDefaults` — ANSI 0–15 from
the active theme (so index 1 answers with *this* theme's red, not a
generic one), 16–255 from xterm's fixed 6×6×6 cube and 24-step
greyscale ramp, matching `TerminalColorPalette.swift`'s independent
render-side copy of the same formula. `oscDispatch` gained a
`parseOSCCode` helper because OSC 104 is the one code with a real
no-semicolon form (`OSC 104 ST`, which is what xterm itself sends) —
every other code needs a payload and was already unreachable without
one.

**OSC 5** ("special colours" — bold, underline, blink, reverse, italic
default colours) was implemented in a follow-up pass, once the exact
semantics were pinned down from xterm's own `ctlseqs.txt` (the
`Pc` values — 0 bold, 1 underline, 2 blink, 3 reverse, 4 italic — and
the OSC 105 reset pairing) rather than guessed: an *independently
documented* specification is what B06's original pass lacked access
to, not esctest specifically, and the two turned out not to be the
same requirement. Added `SpecialColors` — five fixed slots, no themed
default to seed (unlike `IndexedPalette`, an unset slot means Corta's
ordinary SGR-attribute rendering applies, not a placeholder colour),
with the query form answering black for an unset slot rather than
silence, matching OSC 4's own precedent for "always some numeric
answer." Its own render-path integration — a special colour actually
changing how bold/underline/blink/reverse/italic text paints — was
not attempted in that pass and remains open.

**OSC 4's render-path integration — done in a follow-up pass, measured
before and after.** `Theme.Variant.resolve(_:indexedOverrides:)` now checks a
session's OSC 4 overrides before falling through to the existing
ansi/cube/ramp arithmetic; `TerminalRenderer` carries the overrides and
an `overridesGeneration` counter (`IndexedPalette`'s own new field,
the identical shape `GlyphAtlas.generation`/`ScreenLines.generation`
already use) so a set/reset invalidates the render cache even for a
cell whose *content* never changed — an OSC 4 override is invisible to
the ordinary per-cell revision check, since it changes what an index
resolves to, not what any `Cell` stores. Verified with offscreen
pixel-sampled tests (`IndexedPaletteRenderTests.swift`), including the
specific case that proves the cache invalidation actually matters: a
cell painted before the override, then repainted with no content
change in between.

`CLAUDE.md`'s own rule ("measure the frame-CPU baseline after touching
the render loop") was followed with `CortaTests/FrameCPUBaselineTests`
— the same headless, scriptable tool the M6 render-loop regression
this rule itself documents was found and fixed with, not the
screen-capture/live-signpost route the first attempt at this pass assumed
was the only option (that route needs a real, focused GUI session;
this one does not). The first implementation *did* measure a real,
reproducible regression — about 5%, ~0.1 ms, isolated by A/B runs
against 11 samples per side after system-load noise alone had first
produced a misleading 21% swing between two same-code runs. The cause:
`indexedOverrides` was an always-passed, defaulted-to-empty
`Dictionary` parameter, and passing a `Dictionary` — even an empty one
— costs a retain/release pair Swift cannot elide across the call
boundary, paid twice a cell (foreground and background) across ~4800
cells a frame. Switched the parameter to `IndexedColorOverrides?`
(`nil` when a session has no overrides, computed once a frame rather
than re-checked per cell) — passing `nil` retains nothing — which
closed the gap back into noise (~1.6 ms both sides, matched runs
immediately before and after the fix). The regression-and-fix, not
just the final number, is the artifact worth keeping: it is a second,
independent instance of the exact failure mode this file's frame-CPU
rule was written to catch.

`BS`/`CUB` also did not reverse-wrap — a program editing at a wrap
boundary (`readline`'s own line editing among them) that expected
backspace to walk back onto the previous row instead saw the cursor
stick at column 0. The quality-plan record that first found this
named the blocker as needing "a behavioural decision" about which
reverse-wrap semantics to implement; xterm's own answer, `?45`
(reverse-wraparound mode, off by default — not DECBKM, which is the
separate `?67` backarrow-key mode) is the one every other terminal a
comparison would be made against also implements, so it is the one
Corta implements too rather than inventing a bespoke variant. Added
`Grid.reverseWraparoundEnabled` (mirrors `insertMode`'s
pattern: a Grid-owned flag a private-mode DECSET/DECRST toggles, with
a DECRQM case reporting it), and taught `moveCursorLeft`/`backspace`
to continue onto the row above's last column when the mode is on and
that row's own `wrapped` flag says the two rows are one logical line
— never across a hard newline, since `wrapped` is set only where
DECAWM's own auto-wrap actually happened (§2.1). `CUB`'s repeat count
can cross more than one wrapped row in a single call; `BS` is always
one step, matching its existing pending-wrap-disarm behaviour.

`exitAlternateScreen` restores the parked main screen wholesale
(`self = main`), the same mechanism `cursorStyle` already has to be
explicitly carried across for the identical reason: a private mode a
program set is terminal-wide state, not part of either screen's own
content, so the parked copy's stale value would otherwise silently
win. `reverseWraparoundEnabled` is now carried across the same way
`cursorStyle` already was — a real gap a review round caught, not
something reasoned out in advance.

### 7.9 SFTP without an SSH library (B14)

A file-transfer feature wants
libssh2 or a Swift SSH stack; Corta has neither and adds no dependency.
The engine speaks the SFTPv3 wire protocol itself
(`CortaTerminal/Sources/CortaTerminal/SFTP/`) over a channel that is
simply the system's `ssh -s -- <host> sftp` subprocess with **plain
pipes** — a PTY would corrupt binary frames — so authentication, host
keys, `ProxyJump` and every `~/.ssh/config` behavior stay with OpenSSH,
where they belong (B13's rule). Two consequences are owned rather than
hidden. The channel has no terminal (it is spawned into its own
session), so ssh can prompt for nothing: password, passphrase and
host-key questions fail as their own typed errors whose wording says
to connect once in the terminal first — agent- or keychain-held keys
and a host already in `known_hosts` are what work. And the host a
pane names is the remote shell's OSC 7 report — child output — so it
is never connected to on the far end's say-so: the first connection
to a host per run is asked with the name in front of the user,
editable (`RemoteHostConsent`), whether from the browser or a ⌘-click.
The hard parts this creates are all
owned deliberately: the codec treats the peer as hostile (bounded frame
and field lengths, checked counts before allocation, every truncation a
typed error rather than a trap — the same discipline as the escape
parser); a cancelled request's id is tombstoned until its late reply
lands so it is never mistaken for a protocol violation; and destination
writes go to a `<name>.corta-part` partial that is renamed over
the target only on completion, so an interrupted transfer can never
leave a silently-accepted partial file. Resume validates both endpoints
— the partial's own mtime carries the source's mtime stamp, and any
drift restarts from zero rather than appending to a file that no longer
matches. Where the server cannot answer (`statvfs@openssh.com`
unadvertised), the capability reports unavailable instead of guessing.
A directory is a walk plus one such file transfer per regular file —
nothing re-implemented — with two rules of its own: directories merge
(the policy is asked about files, as it would be for each alone), and
only regular files and directories move; a symbolic link at either end
is skipped and reported, since following one is how "download this
folder" walks off into `/etc`.

---

## 8. What "Done" Looks Like

The honest success criterion is **not** feature parity with Ghostty or
iTerm2. Those have years of work and thousands of bug reports behind
them, and the gap is long-tail volume that cannot be designed away.

The criterion is: **for this repository's own workload — zsh, tmux,
Neovim, git, SSH, Python/Node REPLs, dev servers, and high-volume
training logs — a full day of use produces no reason to switch back.**

That is a finite, reachable target. Section 3 of `CONFORMANCE.md` states
it as a checklist.
