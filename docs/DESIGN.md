# Corta — Design

[Documentation index](README.md) · [Project overview](../README.md)

A native macOS terminal emulator written in Swift, with an AppKit shell,
Metal rendering and an independent terminal core.

This document describes 1.1.1 and the development tree on `main` since it.
The B01–B16 implementation batches shipped in 1.0.0, and the 1.1.0
milestone's work in 1.1.0; the download is linked
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

## 2. Settled Decisions

The decisions that constrain the data structures — changing one later
means a rewrite, not a patch — are argued once, in
[DECISIONS.md](DECISIONS.md), one record each:

| Record | Decision |
| --- | --- |
| D03 | Lines carry a `wrapped` flag from the first commit |
| D04 | The terminal core is not `@MainActor`; it is a SwiftPM package of its own |
| D05 | Cells are 16 bytes and full; complex graphemes spill to a side table; rows are variable-length |
| D06 | Selection lives in the core and is document-anchored (§3.1) |
| D07 | Multi-viewport from day one; no singletons in the core |
| D08 | `$TERM` is `xterm-256color` |

One more property is not a data-structure decision but outranks every
feature: **reading the PTY is never blocked by rendering.** If the terminal
stops draining the PTY, the child blocks on `write`, and the terminal
becomes the reason a training job is slow. `PERFORMANCE.md` §2.1 has how.

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
Nothing is shared between windows — that is what D07 buys.

The two thread boundaries are the interesting part of this diagram:

- **PTY/parse → render** is a snapshot taken at vsync, not a push. The
  parser runs as fast as data arrives; the renderer runs at most once per
  frame and always reads a consistent grid.
- **Main thread → PTY** is a write; the main thread never touches the
  grid directly.

### 3.1 Document coordinates


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
monotonic count of every line ever pushed. `scrollback.count`
cannot do that job: it saturates at the ring's limit, so once the ring is
full every push evicts a row while the count reports no growth, and a
selection anchored on it would drift onto whatever text arrived
underneath it. The counter keeps rising, so the shift is right whether the ring is
filling or flooding.

Reflow and search must preserve these invariants: reflow
rewrites document rows wholesale and must invalidate or re-anchor any
live selection, and search matches must be reported in the same document
coordinates so a match can be selected verbatim.

**Every consumer shifts by `totalPushed`, through one mapping.**
`ScrollbackCoordinates` (core) is the single translation between a stored
document row and the live grid for viewport anchoring, selection, search,
command navigation and image placement — both ends of a copied selection
included. With two mappings — the render path shifting by
`scrollback.count` while `⌘C` shifts by `totalPushed` — a saturated ring
would put the highlight and an image placement on the wrong row while
the copied text stayed right, and the two would silently disagree.
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

## 4. Modules

| Module              | Where                                | Isolation   | Responsibility                                       |
| ------------------- | ------------------------------------ | ----------- | ---------------------------------------------------- |
| `Parser`            | `CortaTerminal`                      | nonisolated | UTF-8 decode + VT500 state machine, no screen knowledge |
| `Performer`         | `CortaTerminal`                      | nonisolated | Applies parsed actions to the grid; decides every reply |
| `Grid`              | `CortaTerminal`                      | nonisolated | Cells, cursor, attributes, scroll region, alt screen |
| `Scrollback`        | `CortaTerminal`                      | nonisolated | Ring buffer of variable-length lines                 |
| `TerminalSession`   | `CortaTerminal`                      | nonisolated | Owns PTY + Parser + Grid; the unit a split renders   |
| `PTY`, `corta-exec` | `CortaTerminal`                      | nonisolated | Spawn, read/write, winsize, child lifecycle          |
| `CortaSFTP`         | `CortaTerminal/Sources/CortaSFTP/`   | nonisolated | The SFTP protocol over the system `ssh`, no SSH library (§7.9); a sibling library, not part of the core |
| Renderer            | `Corta/Renderer/`                    | nonisolated | `TerminalRenderer`, `Metal4Backend` (the only GPU backend: one render pass per frame, D21), `QuadPipelineCache`, `GlyphAtlas`, `KittyImageRenderer`; draws a session into a rect, driven from the display link |
| Font stack          | `Corta/Renderer/`                    | nonisolated | `TerminalFont`, `MonospacedFontCatalog`, `CellMetrics`: Core Text shaping, fallback, verification, the ASCII fast path |
| Shell               | `Corta/`                             | MainActor   | Windows, tabs, the split tree, key bindings, IME, settings, shell integration, remote context |

`CortaTerminal` is the terminal core — PTY, parser, grid, selection,
search, shell integration — and nothing else. `CortaSFTP` sits beside it
in the same package: the app imports the two separately, and neither
imports the other. A dependency either way would put the core into the app
through two products, which Xcode resolves by linking it twice over; the
one piece of descriptor machinery both need (`GuardedDescriptor`) is a
byte-for-byte copy instead, held equal by `SharedSourceTests`, and the ssh
child's environment is passed in by the app (the core's
`ChildEnvironment`). Neither library may import AppKit or Metal
(`PackageIsolationTests` and `ModuleBoundaryTests` hold those lines).

### 4.1 A pane and its collaborators

A pane is a `ViewController` that composes collaborators, each owning one
concern with its own state and tests; new behaviour is added as a
collaborator, never as another `ViewController+X.swift`. The controller
keeps the session, the view, the renderer, focus, sizing, teardown, and
the forwarding between them.

| Collaborator      | Owns                                                                 |
| ----------------- | -------------------------------------------------------------------- |
| `PaneFrameLoop`   | When a frame is owed (the output wake, forced redraws, `?2026`), the diff into the renderer and the draw. The pane supplies the frame's content and an `onOutputBatch` stage — title, notifications, accessibility, history — run once per frame that saw output |
| `PaneWindowTitle` | The window title and proxy icon: their composition and sanitising, the interval-cached process facts behind them, the off-main directory probe |
| `PaneSearch`      | Scrollback search: the bar and its placement, key routing (Esc, ⌘G), the debounced off-main sweeps and their generations, the matches the renderer highlights, the pre-search viewport it restores. Reaches the pane only through `PaneSearchHost` |
| `PaneRemote`      | Whether the pane talks to another machine (`PaneRemoteState`, with the report tracker both the title and one-off questions read through), Reconnect and its wording, `path:line` references resolved on the remote host and opened as managed copies, and the SFTP browser's entry and its menu gate. Reaches the pane through `PaneRemoteHost` |
| `PaneCommands`    | The menu and context-menu commands: font size and pinch zoom, copy and export (one cancellable large-text task between them), drops, Services and Look Up, the Finder actions, and app-initiated `cd` with its safety gate. Reaches the pane through `PaneCommandsHost` |

A collaborator that owns menu actions implements them, and the pane
forwards each from an `@objc` method of the same name: menu items, the
palette and key bindings send to the first responder, and the pane is the
object in that chain. Its `validateMenuItem` asks the owner the same way.
Not `supplementalTarget(forAction:sender:)`: an item whose target is the
pane by name never consults it, and AppKit sends the action to the pane
anyway.

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
manual edit; it is not a separate settings store. It is an AppKit split
view — a system sidebar item listing the categories, and SwiftUI grouped
forms beside it — because SwiftUI's own split view inside a hosting
controller drew neither the system sidebar nor steady sidebar icons.

### Deferred, not rejected

- **Kitty graphics:** direct RGB, RGBA and PNG transmission and placement
  are implemented. Animation and Unicode-placeholder placement remain out
  of scope. File-based transmission is rejected because terminal output must
  not cause arbitrary local files to be read; see [Security](SECURITY.md).
- **Shell integration:** OSC 133 command boundaries, with installable hooks
  for zsh, bash and fish — the login shell's, chosen from `$SHELL`.
- **Kitty keyboard:** implemented; see [Conformance](CONFORMANCE.md).

The original ordering decision for Kitty graphics is recorded in
[the roadmap](history/ROADMAP-0.1.md). The implementation uses `ImagePlacementTable` and the
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

### 7.6 Ownership and synchronization

Every mutable-state owner on the input/output path, and what makes each
one safe to touch from more than one thread:

| Owner | Isolation | Mechanism |
|---|---|---|
| `Parser`, `Performer`, `Grid`, `Scrollback` | `nonisolated` | Pure value types / state machines; mutated only while `TerminalSession.state`'s lock is held. |
| `TerminalSession` | `nonisolated`, `@unchecked Sendable` | `Synchronization.Mutex` around every mutable field (`State`, `Callbacks`, `PendingWrites`, `stopped`, `started`, `requestedResize`); no `@unchecked` is load-bearing on its own. |
| `PTY` | `nonisolated`, `@unchecked Sendable` | A `Mutex<State>` around the exit/reaping/closed flags a descriptor's use depends on. |
| AppKit shell (`ViewController`, `SplitViewController`, `AppDelegate`, `TaskNotifier`) | `@MainActor` (project default) | The Xcode target's `SWIFT_DEFAULT_ACTOR_ISOLATION`; see `DECISIONS.md` D04 for why the core opts out instead. |

The PTY reader is a dedicated `Thread`, not a `Task` (`DECISIONS.md`
D04, `PERFORMANCE.md` §2.1). It
calls `onOutput`/`onChildExit` directly, and the shell hops to
`@MainActor` — never the other way around. Output hops at most once a
frame: a per-session `OutputWakeGate` lets a batch through only when the
last frame has taken the previous one (`PERFORMANCE.md` §5.10). Each hop
checks two things:
that the controller is still alive (`[weak self]`) and that it is still
the controller *for this session* (`sessionGeneration`, bumped by every
`setUpPane()`), so a callback from a replaced session is a no-op.
`onChildExit` is installed, so a child that exits on its own gets the
same reaction as a close; `didTeardown` tells the two apart.

The record of the audit that established this table is
[history/2026-09-10-B03-OWNERSHIP-AUDIT.md](history/2026-09-10-B03-OWNERSHIP-AUDIT.md).

### 7.7 Search state is pane-local, all the way

Two panes searching at once must not affect each other, and an app-wide
event monitor makes that easy to get wrong:

- **Per-pane flags.** `search-case-sensitive` and `search-regex` seed a
  bar's own copy when it opens; sweeps and the button tint use only that
  copy, and the config file only supplies the default for the next bar.
- **Esc belongs to one bar.** `NSEvent.addLocalMonitorForEvents` fires
  app-wide, so the handler checks the event's window *and* that the
  window's field-editor delegate is this pane's own search field — a
  split puts two bars in one window.
- **No refresh is lost.** An output-triggered refresh that arrives while
  a sweep is in flight sets `search.needsRefresh` instead of being
  dropped; the tail of a burst is searched once the sweep lands.
- **The bar keeps off what it searches.** It sits top-right and moves to
  the bottom-right while the cursor or the current match would be under it
  (`PaneSearch.placeClearOfContent`, on output, scroll, layout and match
  changes — a few rect tests, only while a bar is open); its field narrows
  with a split pane instead of the bar covering the pane.
- **Closing restores the text, not the row count.**
  `search.previousScrollOffset` is shifted by the growth in
  `Scrollback.totalPushed` since `search.previousTotalPushed`, recorded
  when the bar opened (§3.1).
- **Large copy and export leave the main actor.** `Selection.text` is
  O(the range) and export is O(scrollback), so both build on
  `Task.detached`, under a generation-guarded `largeTextTask`. Cancelling
  discards a build's result; it does not stop the row walk. The file
  write is atomic (`Data.write(options: .atomic)`).

The record: [history/2026-09-11-B05-SEARCH-STATE.md](history/2026-09-11-B05-SEARCH-STATE.md).

### 7.8 Colour and cursor conformance that has to reach the renderer

- **SCOSC / SCORC.** Bare `CSI s` / `CSI u` alias DECSC/DECRC, as xterm
  treats them without DECLRMM. The kitty keyboard protocol's `CSI u`
  forms are dispatched earlier and never reach the alias.
- **OSC 4 / 104.** `IndexedPalette` holds themed `defaults` (ANSI 0–15
  from the active theme, then xterm's 6×6×6 cube and greyscale ramp) and
  sparse `overrides`. An override changes what an index *resolves to*,
  not what any `Cell` stores, so the per-row revision check cannot see
  it: `IndexedPalette.overridesGeneration` invalidates the render cache
  instead. The renderer receives `IndexedColorOverrides`, empty when a
  session has none; an empty dictionary costs nothing measurable under
  Release (`PERFORMANCE.md` §5.8).
- **OSC 5 / 105.** `SpecialColors` holds the five special colours
  (xterm's `ctlseqs.txt` `Pc` values); a query of an unset slot answers
  black. They are query/set state only — they do not yet change how bold,
  underline, blink, reverse or italic text paints.
- **Reverse wraparound (`?45`).** Off by default, as in xterm (not DECBKM,
  which is `?67`). When on, `BS`/`CUB` continue onto the previous row's
  last column only across a `wrapped` boundary (D03), never across a
  hard newline.
- **Private modes survive the alternate screen.** Leaving it restores
  the parked main screen wholesale, so terminal-wide modes
  (`cursorStyle`, `reverseWraparoundEnabled`) are carried across
  explicitly.

The record: [history/2026-09-11-B06-CONFORMANCE-GAPS.md](history/2026-09-11-B06-CONFORMANCE-GAPS.md).

### 7.9 SFTP without an SSH library

A file-transfer feature wants
libssh2 or a Swift SSH stack; Corta has neither and adds no dependency.
The engine speaks the SFTPv3 wire protocol itself
(`CortaTerminal/Sources/CortaSFTP/`) over a channel that is
simply the system's `ssh -s -- <host> sftp` subprocess with **plain
pipes** — a PTY would corrupt binary frames — so authentication, host
keys, `ProxyJump` and every `~/.ssh/config` behavior stay with OpenSSH,
where they belong. Two consequences are owned rather than
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

## Follow-up lifecycle and storage boundaries

SFTP sessions reserve their single-use connection lifecycle before starting
one reader. Handshake cancellation closes the transport. The connection
wrapper rejects concurrent connects, tracks the pending session so close
can cancel a handshake, and refuses installing an engine after close.

Directory proxy validation is asynchronous, bounded process-wide and rejects
stale results. Search outcomes likewise check generation before updating any
UI status. Remote editing persists a SHA-256 remote baseline, validates
content before upload, and sends the approved private snapshot rather than
a live editor file. See [Security](SECURITY.md) for race and ACL boundaries.

## Local status and appearance editing

SystemMetrics uses public Mach, getloadavg, getifaddrs, Foundation volume and
ProcessInfo thermal APIs. A shared main-actor SystemMetricsStore owns visible
bar clients and one two-second timer. Its actor sampler performs reads off the
main thread; cancellation and generation checks discard obsolete results.
Window bars are siblings of the terminal split tree, so toggling the optional
24-point bar does not reconstruct sessions. No metric is collected for SSH
hosts. Host details are also reachable independently of the bar.

ThemeEditorModel holds a draft copied from the active theme, validates names
and HEX colors and detects concurrent changes. ThemeEditorView previews that
draft; Save persists through ConfigurationStore and Cancel discards it. The
primary font is System Monospaced; fallback shaping remains Core Text’s job.
Cursor preference supplies block/bar/underline and blinking; explicit DECSCUSR
styles override it until reset. Idle blinking invalidates cursor drawing and
pauses outside visible active panes rather than polling terminal output.

The input-source badge observes macOS input-source metadata, never typed text.
The default fixed toolbar slot hosts the focused pane's existing accessible
badge, separated from action buttons by a window-owned native spacer. Disabling
it or selecting prompt placement removes both the slot and its spacer. The
optional right-edge prompt placement avoids live command content without
changing the grid or sending bytes to the child. Unknown private IME modes use
neutral styling; enabled non-Latin layouts and IMEs determine automatic display.
