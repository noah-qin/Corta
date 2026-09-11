# Corta — Design

> **Next-development scope (2026-09-10).** The active
> [B01–B16 GitHub roadmap](https://github.com/noah-qin/Corta/milestone/1)
> includes intelligent navigation, SSH/SFTP, modern macOS/Swift UI work and a
> real Metal 4 backend. Built-in AI remains excluded; compatibility with
> existing AI command-line tools is in scope. This supersedes conflicting
> auxiliary-workflow restrictions below. Native macOS, the Swift terminal
> core, correctness and explicit resource/security boundaries remain. Roadmap
> entries describe planned work, not shipped capabilities; the milestones and
> pre-M1 status below are historical design context.

A native macOS terminal emulator written in pure Swift. Optimised for
performance, deliberately small in scope.

Status: **pre-M1** (project scaffold only).

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
single-language codebase. Realistic cost is **6,000–10,000 lines** for a
terminal that is correct for daily use — not the 3,000 that a first
estimate suggests. The parser skeleton is small; the long tail is not.

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

The flag is mandatory in M1. The reflow *implementation* may land later;
reflow of a large scrollback must be incremental or lazy, because a live
window drag fires resize continuously.

### 2.2 The terminal core is not `@MainActor`

The PTY reader, parser and grid run off the main thread. The Xcode
project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which is
correct for the AppKit shell and wrong for the core.

Therefore the core lives in a **local SwiftPM package** (`CortaTerminal`)
with default isolation disabled. Side benefit: the core is unit-testable
and benchmarkable without launching an app.

### 2.3 Cells are fixed-size; complex graphemes spill to a side table

A cell stores a `UInt32` word plus attributes and two 16-bit table keys,
16 bytes in total, asserted by `CellLayoutTests`. Grapheme clusters that
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

**B04 found the render path violating its own invariant.**
`TerminalRenderer.selectionQuads` and `KittyImageRenderer`'s visibility/draw
math were shifting by `scrollback.count`, not `totalPushed` — exactly the
mistake this section warns against, three paragraphs up, in the type this
code itself belongs to. Once a ring saturated, the on-screen highlight (and
image placement) drifted onto the wrong row while `⌘C` — which already used
`totalPushed` — copied the right text; the two silently disagreed. Fixed by
using `totalPushed` throughout (`cachedScrollbackTotalPushed` replaces
`cachedScrollbackCount` as the render cache's own invalidation key, which had
the same bug: a `.count`-based comparison stops noticing scrollback changed
once the ring is full). Regression: `SelectionRendererTests
.selectionTracksItsLineAfterTheRingSaturates`.

Reflow's half of the invariant — "must invalidate or re-anchor any live
selection" — was not implemented at all before B04: a column change (the
only kind that reflows, `Grid.resize`) rebuilds `Scrollback` from scratch,
resetting `totalPushed`, but nothing cleared `ViewController.selection` or
`scrollOffset` across that. `resizeSessionToFitView` now clears both when the
new size's column count differs from the last requested one (a row-only
resize is ordinary scrollback growth, already handled correctly by the
`baseScrollbackTotal` shift, and is deliberately left alone). This path is
gated by window-visibility lifecycle state (`SplitViewController
.sizeSettled`) that the offscreen test target never exercises — verified
instead by launching the app and resizing a window narrower, per
`CONFORMANCE.md` §4.4.

**Re-anchoring `scrollOffset` and the bottom-return behavior, closed in a
follow-up pass.** `scrollOffset` was a raw distance-from-bottom count that
silently drifted as `totalPushed` grew — the same-numbered offset pointed at
whatever was now that many lines above the live bottom, not at the text a
person had actually scrolled to. `scrollAnchorTotalPushed` (`ViewController
.swift`) records `scrollbackTotalPushed` on every `scrollOffset` change while
off the bottom; `prepareFrame` shifts the offset by the growth in that total
on every output batch, keeping the *document position* fixed instead of the
row count. Ring eviction still clamps the same way any other over-large
offset does, in the renderer — a stable position can't survive its own rows
being evicted, only stop drifting while they exist. With that anchor in
place, ordinary typing and paste (`ViewController.returnToBottomOnInput`,
called from `onKeyBytes` and `pasteFromClipboard`) now return the viewport to
the bottom, matching every comparable terminal — input is the user's own
request to talk to the live screen, unlike output arriving while they read,
which the anchor now deliberately leaves alone. Regression:
`ScrollIndicatorIntegrationTests.scrolledOffsetStaysAnchoredAsOutputArrives`,
`.typingWhileScrolledReturnsToTheBottom`,
`.returnToBottomOnInputOnlyActsWhenScrolled`.

**A drag now ends if the window loses key status mid-gesture** (Cmd-Tab to
another app, a global shortcut opening a new window, Mission Control) rather
than `nextEvent(matching:)` continuing to block on drag/periodic events for a
window the user is no longer looking at — the same early-return shape the
pane-closed-mid-drag case already used. This closes the "focus-loss
cancellation" half of B04's blocking-mouse-tracking item; the loop itself is
otherwise unchanged, and — like the rest of `handleSelectionMouseDown` — is
gated on a real window's blocking local event loop that the offscreen test
target cannot drive, so this is verified by reasoning parity with the
already-tested pane-close guard rather than by an automated regression case.

**Still open, deliberately not attempted**, because each is a substantially
larger, riskier piece than the fixes above: unifying the document/absolute/
viewport conversions duplicated across the render, `ViewController
+ShellIntegration`, `ViewController+Search` and now the scroll-anchor paths
into one shared mapping, rather than fixing each concrete divergence found as
it turned up (four call sites now share the identical `totalPushed`-delta
shape, which is the functional requirement; consolidating them into one
helper afterward is a pure refactor with real risk to already-tested code and
no behavior change, not something this pass's fixes depend on); and a
discoverable override separating terminal text selection from application
mouse reporting — blocked on there being no `?1002`/`?1003` motion-tracking-
mode support to override *to* in the first place (every drag today
unconditionally becomes a local selection, which already makes selection
achievable in a reporting-enabled TUI, but means Corta cannot forward a drag
as reports at all — implementing motion-tracking mouse modes is a new
protocol capability, not a bug fix, and belongs in its own pass).

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

| Module              | Package         | Isolation  | Responsibility                                       |
| ------------------- | --------------- | ---------- | ---------------------------------------------------- |
| `Parser`            | `CortaTerminal` | nonisolated| UTF-8 decode + VT500 state machine, no screen knowledge |
| `Performer`         | `CortaTerminal` | nonisolated| Applies parsed actions to the grid                   |
| `Grid`              | `CortaTerminal` | nonisolated| Cells, cursor, attributes, scroll region, alt screen |
| `Scrollback`        | `CortaTerminal` | nonisolated| Ring buffer of variable-length lines                 |
| `TerminalSession`   | `CortaTerminal` | nonisolated| Owns PTY + Parser + Grid; the unit a split renders   |
| `PTY`               | `CortaTerminal` | nonisolated| Spawn, read/write, winsize, child lifecycle          |
| `Renderer`          | app             | —          | Metal, glyph atlas, draws a session into a rect      |
| `FontStack`         | app             | —          | Core Text shaping, fallback, ASCII fast path, cache  |
| `Shell`             | app             | MainActor  | Window, tabs, split tree, key bindings, IME          |

`CortaTerminal` must not import AppKit or Metal.

---

## 5. Milestones

| Milestone            | Done when                                                              |
| -------------------- | ---------------------------------------------------------------------- |
| **M1 — It runs**     | One window, a real shell, colour output, scrollback, scrolling         |
| **M2 — No garbage**  | `vim`, `htop`, `tmux` render correctly (alt screen, scroll region, widths) |
| **M3 — CJK & input** | IME composition and candidates correct, no width drift, bracketed paste |
| **M4 — Modern**      | ⌘F search, font zoom, URL click, tabs                                  |
| **M5 — Splits**      | Layout tree, focus routing, multi-viewport rendering                   |
| **M6 — Polish & hardening** | Settings page, themes, notifications; query-response class closed (esctest score up), OSC 8, focus reporting, kitty keyboard, fuzzing; native macOS integration, notarized distribution |

**M2 is the checkpoint.** Do not change scope, add features, or refactor
the architecture before M2 is done. By M2 most of the learning value is
banked and the decision to continue can be made honestly.

If M2 takes more than ~3 months of part-time work, the cause is almost
always scope creep (ligatures, transparency, a config system) rather than
difficulty. The response is to cut scope, not to work harder.

The test harness in `CONFORMANCE.md` §4 is built during **M1**, not
later. Fixing the long tail without golden-file tests is misery.

---

## 6. Non-Goals

Explicitly out of scope. Each has been considered and rejected.

| Not doing                                     | Why                                                        |
| --------------------------------------------- | ---------------------------------------------------------- |
| Built-in multiplexer (daemon, attach/detach)  | tmux exists and is better; heaviest possible feature        |
| Cross-platform                                | Forfeits Metal and Core Text, the entire premise            |
| tmux control mode (`-CC`)                     | A second protocol *and* a second window model; same cost class as building a multiplexer |
| AI features, command blocks, cloud sync       | Conflicts with "small, not heavy"                           |
| Implementing SSH or git                       | They are programs running on a PTY; rendering correctly is the whole job |
| Bidirectional text (RTL)                      | Large complexity, and a security footgun (see `SECURITY.md`) |
| Terminal title *query* responses              | Command injection vector; see `SECURITY.md` §2.2            |

A graphical settings UI was on this list until M6 planning reversed it:
M6.1 adds one native settings page, kept honest by remaining a thin
front over the single text config file.

### Deferred, not rejected

Worth doing eventually, deliberately not in the M1–M6 path:

- ~~**Kitty graphics protocol**~~ — shipped as M10: direct (base64,
  in-band) transmission and placement in RGB, RGBA and PNG, exactly the
  side table the M6.4 reassessment below predicted it would cost.
  File-based transmission (`t=f`/`t=t`/`t=s` — the remote stream names a
  local path to read) is not implemented and will not be: `SECURITY.md`
  §1 assumes every PTY byte is hostile, and a stream that can make Corta
  open an arbitrary local file is exactly what that threat model exists
  to reject. Animation frames and Unicode placeholder ("virtual")
  placement are also not implemented — real protocol features, out of
  scope for a first pass rather than attempted badly.
- ~~**Shell integration / OSC 133**~~ — shipped as M7.2: prompt and
  exit-status marks on the line, command-to-command jumping, and an exact
  long-task notification. It cost four sequences and a per-line mark, as
  the M6.4 reassessment below predicted. Corta still ships no shell
  snippets, so the marks appear only for a shell the user has configured
  to emit them — the distribution half of the problem is open.

The kitty keyboard protocol was on this list; it shipped as M6.9.

#### M6.4 — the reassessment

Both items were re-examined at the end of M6, as that step required.
Neither moves into M6; both keep their place, and the ordering between
them changed.

**OSC 133 moves to the front, and now has a caller.** M6.3 shipped a
long-task notification built on a heuristic — Return starts a task, an
idle output stream ends it — because a terminal without shell
integration cannot see command boundaries. That heuristic is the
feature's whole weakness: it is off by default precisely because a
command that pauses for two seconds mid-run gets an early notification.
OSC 133 replaces the guess with a fact, and the same marks pay for jump
to previous prompt, per-command duration and exit-code marks. It is the
next thing to build, and it is small: four sequences and a per-line
mark, no new rendering.

The cost that stopped it being pulled into M6 is not the terminal side.
It is that the marks only exist if the user's shell emits them, which
means shipping and installing shell snippets for zsh, bash and fish —
distribution work, and M6.16 shows distribution is not yet solved.

**The kitty graphics protocol stayed deferred through M6-M8, and shipped
as M10.** The M6 estimate — a placement side table keyed by document
position, plus a second texture path — held: `ImagePlacementTable`
(`CortaTerminal/Sources/CortaTerminal/ImagePlacementTable.swift`) is
exactly that table, addressed by document row the same way
`TerminalSelection` is, and images draw through the existing color quad
pipeline (`Corta/Renderer/KittyImageRenderer.swift`) rather than a third
one — a placed image is geometrically a rect, which the instanced-quad
path already draws. What the M6 estimate did not anticipate: reflow
across a column resize is not attempted — a resize drops every live
placement rather than re-wrapping image geometry, on the reasoning that
a wrongly-positioned image is worse than a missing one that a client can
re-place without re-transmitting (`ImagePlacementTable`'s doc comment).

---

## 7. Known Hard Parts

Ordered by how badly they are usually underestimated.

1. **CJK IME is not free.** `NSTextInputClient` provides marked text, but
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

2. **`fork` in a Cocoa process.** Between `fork` and `exec` only
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

3. **Ligatures conflict with a one-glyph-per-cell atlas.** A Fira Code
   ligature spans cells and does not align to the grid, and a cursor
   inside a ligature must break it. Treat as P2, or accept the
   simplification that the cursor row disables ligatures.

4. **Glyph atlas eviction.** A 2048×2048 atlas holds roughly 2,000 glyphs
   at typical sizes. A CJK session exceeds that easily. Resolved at M3 with
   the strategy Alacritty uses: shelf packing cannot reclaim individual
   slots without fragmenting, so a full page is *reset* — caches cleared,
   allocator rewound — and glyphs re-rasterise on demand. A `generation`
   counter on `GlyphAtlas` lets the renderer detect a mid-build reset and
   rebuild once, since every UV issued before the reset is stale. A screen
   whose live content alone exceeds one page cannot be served by any
   eviction policy; those cells draw blank.

5. **Text rendering weight.** macOS has had no subpixel antialiasing
   since Mojave. Naively alpha-blending grayscale-AA glyphs makes light
   text on a dark background look visibly thinner than Terminal.app.
   Gamma-corrected blending or stem darkening is needed to match.

6. **Ownership and synchronization audit (B03).** Every mutable-state
   owner on the input/output path, and what makes each one safe to touch
   from more than one thread:

   | Owner | Isolation | Mechanism |
   |---|---|---|
   | `Parser`, `Performer`, `Grid`, `Scrollback` | `nonisolated` | Pure value types / state machines; mutated only while `TerminalSession.state`'s lock is held. |
   | `TerminalSession` | `nonisolated`, `@unchecked Sendable` | `Synchronization.Mutex` around every mutable field (`State`, `Callbacks`, `PendingWrites`, `stopped`, `started`, `requestedResize`). Verified case by case (`docs/V0.1.1-ENGINEERING-AUDIT.md` A02); no `@unchecked` is load-bearing on its own. |
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

7. **Search state that looked pane-local was not, all the way (B05).**
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

8. **Three conformance gaps closed, two more scoped and declined (B06).**
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

   Deliberately not attempted: **OSC 5** ("special colours" — bold,
   underline, blink, reverse, italic default colours), because unlike OSC
   4 its exact index semantics are not independently documented anywhere
   verifiable without the esctest suite itself, and this sandbox cannot
   run esctest (`docs/CONFORMANCE.md` §4.2 needs a live GUI process and
   network access to fetch it) — guessing the mapping wrong would be
   worse than not answering. **Render-path integration** — making an OSC
   4 override actually repaint indices 16–255 differently — was also cut:
   `TerminalRenderer`/`TerminalColorPalette` sit on the hot path this
   file's own rule (`CLAUDE.md`, "measure the frame-CPU baseline") gates
   behind a Typometer/`corta-bench` measurement this session had no way to
   take safely, and every OSC 4/104 behaviour that *is* verifiable —
   set, query, multi-pair parsing, reset-one/-several/-all, and the
   default-colour formula itself — was checked directly against the core
   package via `corta-dump --serve`, independent of whether a renderer
   ever reads the result.

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
