# Corta — Design

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

A cell stores a `UInt32` scalar plus attributes. Grapheme clusters that
do not fit in one scalar (combining marks, emoji ZWJ sequences such as
`👨‍👩‍👧‍👦`) store a tag pointing into an interned side table.

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

One known limit: the anchoring shift is computed from the scrollback's
count, which stops growing once the ring is full, so a selection made
while a full ring floods stays put instead of tracking its text. Exact
anchoring under eviction needs a monotonic line counter on `Scrollback`.

Reflow (M4.2) and search (M4.4) must preserve these invariants: reflow
rewrites document rows wholesale and must invalidate or re-anchor any
live selection, and search matches must be reported in the same document
coordinates so a match can be selected verbatim.

---

## 3. Architecture

```
┌───────────────────────────────────────────────────────────────┐
│  MAIN THREAD — AppKit shell                                   │
│  NSWindow / tabs / split layout tree / key bindings           │
│  NSTextInputClient (CJK IME, marked text)                     │
└──────────┬──────────────────────────────────┬─────────────────┘
           │ key, mouse, paste                │ CVDisplayLink (vsync)
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
| **M6 — Polish**      | Config file, themes, bell, notifications                               |

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
| A graphical settings UI                       | One text config file                                        |
| Implementing SSH or git                       | They are programs running on a PTY; rendering correctly is the whole job |
| Bidirectional text (RTL)                      | Large complexity, and a security footgun (see `SECURITY.md`) |
| Terminal title *query* responses              | Command injection vector; see `SECURITY.md` §2.2            |

### Deferred, not rejected

Worth doing eventually, deliberately not in the M1–M6 path:

- **Kitty graphics protocol** — inline images. Genuinely useful for
  viewing plots from ML work without leaving the terminal.
- **Shell integration / OSC 133** — jump to previous prompt, command
  duration, exit-code marks. High value per line of code; consider
  pulling forward if M4 finishes early.
- **Kitty keyboard protocol** — distinguishes `Ctrl+I` from `Tab`,
  reports key release. Wanted by heavy Neovim users.

---

## 7. Known Hard Parts

Ordered by how badly they are usually underestimated.

1. **CJK IME is not free.** `NSTextInputClient` provides marked text, but
   `firstRectForCharacterRange:` must return correct *screen* coordinates
   or the candidate window lands in the wrong place; preedit text must be
   drawn into the grid as an overlay without being committed to it; and
   `interpretKeyEvents:` swallows control keys the terminal needs. The
   standard structure is to bypass the IME path entirely unless marked
   text is active.

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
   at typical sizes. A CJK session exceeds that easily. LRU eviction or
   multiple atlas pages is required, not optional.

5. **Text rendering weight.** macOS has had no subpixel antialiasing
   since Mojave. Naively alpha-blending grayscale-AA glyphs makes light
   text on a dark background look visibly thinner than Terminal.app.
   Gamma-corrected blending or stem darkening is needed to match.

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
