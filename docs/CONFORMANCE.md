# Corta — Feature Conformance

What Corta must implement, in what order, and how completeness is
measured. Priorities:

- **P0** — without it the terminal is unusable; `vim`/`tmux`/`htop`
  visibly break, or programs hang.
- **P1** — expected by any modern terminal; needed to be a daily driver.
- **P2** — enhancement, deferrable, or explicitly declined.

> **A note on "features".** Coloured `git` output, SSH and plain `tmux`
> are *not* features. They are consequences of a correct parser and a
> correct grid. Nothing in this repository is written "for git". Build
> the primitives; the applications light up on their own.

---

## 1. VT Parsing and Screen Model

### 1.1 Rendering correctness

| Capability                                              | Tier | Notes                                                   |
| ------------------------------------------------------- | ---- | ------------------------------------------------------- |
| UTF-8 byte stream decoding                              | P0   | The foundation                                          |
| SGR: ANSI / 256 / 24-bit true colour, bold, underline, reverse | P0 |                                                  |
| Cursor movement, absolute positioning, save/restore     | P0   |                                                         |
| Erase display / line, insert / delete lines and columns | P0   |                                                         |
| **Alternate screen** (`?1049`)                          | P0   | `vim`/`less`/`htop` depend on it entirely               |
| **Scroll region** (`DECSTBM`)                           | P0   | tmux and vim status lines depend on it                  |
| **Character width**: CJK wide, emoji, combining, zero-width | P0 | Wrong widths mean misaligned CJK text; wide pairs draw scaled into their two-cell box (M3.5) |
| Scrollback                                              | P0   | Ring buffer, variable-length rows                       |
| Soft-wrap flag per line                                 | P0   | Required by reflow, selection and search — see `DESIGN.md` §2.1 |
| Reflow on resize                                        | P1   | Must be incremental; live window drag fires continuously |
| **Synchronized output** (`?2026`)                       | P1   | Neovim, tmux ≥ 3.4 and fzf use it; absence causes visible tearing |
| Cursor style (`DECSCUSR`)                               | P1   |                                                         |
| OSC 0 / 2 — set window and tab title                    | P1   | Set only. Query is **never** implemented, see `SECURITY.md` §2.2 |
| **OSC 7** — report working directory                    | P1   | Prerequisite for new tabs and splits inheriting the cwd |
| Bracketed paste (`?2004`)                               | P0   | A safety feature, not a convenience — see `SECURITY.md` §2.3 |
| Mouse reporting (SGR, `?1006`)                          | P1   | Mouse inside tmux and vim                               |
| Focus reporting (`?1004`)                               | P2   | Neovim autoread, tmux focus events                      |
| OSC 8 — hyperlinks                                      | P2   | Display text and target differ by design; see `SECURITY.md` §2.4 |
| DCS and rare CSI sequences                              | P2   | The long tail                                           |

### 1.2 Query / response sequences

**These are P0 and are the most commonly missed requirement.** They are
not about rendering: a program that asks a question and receives no
answer either waits for a timeout or misdetects the terminal's
capabilities.

| Sequence                        | Asked by                                       | Consequence if unanswered            |
| ------------------------------- | ---------------------------------------------- | ------------------------------------ |
| **DA1** (`ESC [ c`)             | vim / Neovim at startup                        | Startup stalls until timeout         |
| **DA2** (`ESC [ > c`)           | Capability detection                           | Feature misdetection                 |
| **DSR-CPR** (`ESC [ 6 n`)       | zsh, starship and similar prompts              | Prompt corrupts or hangs             |
| DECRQM (mode query)             | tmux, Neovim capability probes                 | Conservative fallback behaviour      |
| XTVERSION (`ESC [ > 0 q`)       | Modern TUIs                                    | Feature misdetection                 |

Every response is written to the child's stdin. Responses must therefore
be **fixed-format and never echo attacker-controlled text** — see
`SECURITY.md` §2.2.

---

## 2. Input, Rendering, Windows

### 2.1 Input

| Capability                                       | Tier | Notes                                              |
| ------------------------------------------------ | ---- | -------------------------------------------------- |
| Keyboard → PTY, including control and function keys | P0 |                                                    |
| **CJK IME** (`NSTextInputClient`)                | P0   | Harder than it looks — `DESIGN.md` §7.1. Composition, candidate window and commit verified in the launched app (§4.4) |
| Copy / paste with bracketed paste                | P0   | Copy joins soft-wrapped lines into one and trims trailing blanks; ⌘C / Edit ▸ Copy |
| Keyboard and mouse text selection                | P0   | Drag, double-click word, triple-click logical line, ⇧-click extend; document-anchored — `DESIGN.md` §2.7 |
| Configurable key bindings                        | P1   |                                                    |
| Click-to-position, drag-to-select                | P1   |                                                    |
| ⌘-click to open a URL                            | P1   | Scheme allowlist required — `SECURITY.md` §2.4      |
| Kitty keyboard protocol                          | P2   | Deferred, not declined                              |

### 2.2 Rendering

| Capability                                       | Tier | Notes                                              |
| ------------------------------------------------ | ---- | -------------------------------------------------- |
| GPU glyph atlas + instanced quads                | P0   | One draw call per screen                            |
| Foreground / background, bold, italic, underline | P0   |                                                    |
| Cursor: block / bar / underline, blink           | P0   |                                                    |
| Selection highlight                              | P0   | Document-anchored quads; follows its text as output scrolls |
| Retina / HiDPI scaling                           | P0   |                                                    |
| **Font fallback** for CJK and emoji              | P0   | Core Text cascade list; the shaped run's font rasterises the glyph (M3.5) |
| Atlas eviction (LRU or multi-page)               | P0   | Full-page reset on exhaustion + `generation` rebuild (M3, `DESIGN.md` §7.4) |
| Gamma-corrected glyph blending                   | P1   | Otherwise light-on-dark text looks too thin         |
| Runtime font scaling (⌘+ / ⌘−)                   | P1   |                                                    |
| Ligatures                                        | P2   | Conflicts with the cell grid — `DESIGN.md` §7.3     |
| Background transparency, blur, padding           | P2   |                                                    |

Runtime font scaling landed at M3 (⌘= bigger, ⌘- smaller, ⌘0 reset).
The glyph atlas is rasterised for one size and scale, so a change
rebuilds the renderer and re-fits the window around the unchanged
grid. Measured on a 2x display (Menlo): 14pt → 9x17pt cell, 1100x554pt
content (120x30 grid); 15pt → 10x18pt cell, 1220x584pt content; the
13pt step was re-measured live (980x524pt) when fixing the ⌘- shadowing
below. The stock storyboard's Format menu (font panel, rich-text
traits) was removed at the same time: its Font ▸ Smaller item claimed
⌘- first in menu order and routed it to `modifyFont:`, which a terminal
never implements — the shortcut arrived dead. `MenuShortcutTests` pins
the invariant: no keystroke is claimed by two menu items. The
cursor renders the core's DECSCUSR state — block, bar and underline;
blinking variants render steadily, because a blink timer would force
frames on an idle screen (`PERFORMANCE.md` §1, idle CPU ~0%).

### 2.3 Windows and sessions

| Capability                                              | Tier | Notes                                        |
| ------------------------------------------------------- | ---- | -------------------------------------------- |
| Single window, single terminal                          | P0   | M1                                           |
| Multiple windows (⌘N), each its own session             | P1   | Landed at M3; composition, not new mechanism |
| PTY lifecycle: spawn, read/write, `TIOCSWINSZ`, `SIGCHLD` | P0 | Resize must be reported or remote `vim` and `htop` desynchronise |
| Resize debouncing                                       | P1   | A live window drag otherwise hammers the child |
| Tabs                                                    | P1   |                                              |
| Split panes (layout tree + focus routing)               | P1   | Renderer and input are multi-viewport from M1 |
| Search scrollback (⌘F)                                  | P1   | Must match across soft-wrapped lines          |
| Scrolling (wheel, ⌘↑↓, page)                            | P0   |                                              |
| Bell (audible / visual / mute)                          | P1   |                                              |
| Config file                                             | P1   | One text file. Prefer a format with no third-party parser |
| Multiplexing                                            | —    | Not doing; use tmux                           |

---

### 2.4 Shrinking the screen

Reducing the row count moves rows off the **top**, into scrollback, until
the cursor fits. Only rows below the cursor — which are blank — come off
the bottom. Truncating from the bottom instead destroys the newest output
and does not preserve it in history, so making a window smaller silently
ate the last commands that ran.

## 3. The Daily-Driver Checklist

The operational definition of success from `DESIGN.md` §8. If all ten
hold, Corta has replaced Terminal.app for this repository's own use.

- [ ] Opens to a working shell with correct colour output
- [ ] `vim` / `less` / `htop` render without artifacts
- [ ] Chinese input works, displays, and never drifts out of alignment
- [ ] Copy and paste work; pasting multi-line code does not auto-execute
- [ ] Scrollback holds a long training run and scrolls smoothly
- [ ] ⌘F searches scrollback
- [ ] New tab and split pane
- [x] ⌘+ / ⌘− resize the font
- [ ] Resizing the window resizes the program inside it
- [ ] ⌘-clicking a `localhost:` URL opens the browser

---

## 4. Measuring Completeness

Built during **M1**. Fixing the long tail without these is guesswork.

### 4.1 Golden-file grid tests

The primary harness. Feed a recorded byte stream to a `TerminalSession`,
serialise the resulting grid to plain text (characters plus attributes),
and diff against a checked-in expectation.

This is how a change to one CSI handler is prevented from silently
breaking `vim`. Written once, useful for the life of the project.

### 4.2 External suites

| Suite      | What it covers                        | Use                                  |
| ---------- | ------------------------------------- | ------------------------------------ |
| `esctest`  | xterm's own conformance suite         | The objective completeness number    |
| `vttest`   | Classic VT100/VT220 behaviour         | Manual sanity pass at each milestone |

Record the pass rate at each milestone. "Conformance improved" is only
meaningful against a previous number.

### 4.3 Fuzzing

The parser consumes untrusted bytes and must never crash, hang, or
allocate without bound. Fuzz it (SwiftPM supports libFuzzer via
`-sanitize=fuzzer`) with the resource caps in `SECURITY.md` §3 asserted.

### 4.4 App-layer verification requires a launched app

Offscreen render tests assert pixel coverage: that a cell with a known
background produces that colour, that a glyph produces non-background
pixels inside its cell. Every one of the following passed those tests
and still shipped a blank or unusable window:

- a view whose frame did not track its superview, so most of the grid
  was drawn outside the visible area,
- glyphs rasterised upside down,
- the grid laid out in points against a pixel coordinate space, so
  everything rendered at half size on a Retina display,
- a transient window size at startup that the shell laid its early
  output out against,
- a transient *winsize* delivered at startup: the first layout ran at
  the content-rect height (window frame minus titlebar, before
  `.fullSizeContentView` took effect) and shrank the session 30 → 28
  rows, then grew it back — stranding two blank rows under the prompt
  while `stty size` and the render rect both reported the correct 30
  (M2 closeout, D.1; fixed by gating session resizes on the view
  filling its window's frame).

These are properties of the live view hierarchy, of orientation, and of
startup ordering — none of which a texture readback can see. Any change
under `Corta/` is therefore verified by launching the app and checking:

1. the window's content size matches columns x rows x point metrics,
2. `stty size` in the child agrees with it,
3. a screenshot shows text upright, full size, and filling the window,
4. output longer than the screen scrolls and uses every row.

### 4.4.1 IME verification (M3.1–M3.4)

IME behaviour additionally requires driving a *real* input method in the
launched app; no offscreen or in-suite test can do it (`DESIGN.md` §7.1 —
synthetic events with baked characters bypass composition). Procedure used
at M3:

1. Launch the app with a wrapper `$SHELL` that records `stty size` and
   ends with `exec cat > capture-file` (a *backgrounded* reader is stopped
   by `SIGTTIN`; the capture must own the terminal).
2. Select an enabled Chinese input source for the session via TIS
   (`TISSelectInputSource`, e.g. `com.apple.inputmethod.SCIM.ITABC`) and
   restore the previous source afterwards.
3. Inject key events at HID level (`CGEvent.post(tap: .cghidEventTap)`)
   with **key codes only** — setting a unicode string on the event makes
   the IME treat it as plain text. Requires the injecting process to be
   accessibility-trusted; without that grant this is a manual test.
4. Verify: typing pinyin opens a composition (marked text overlay at the
   cursor, underlined; nothing reaches the child), the candidate window
   appears under the cursor cell, selecting a candidate writes it to the
   child as UTF-8, and ⌃C / ⌃D / ⌃Z and the arrows behave identically
   with and without the IME selected.

### 4.5 Manual scenario pass

Run at every milestone, because these are the actual workload:

1. `tmux` with a split running `htop`, resize the window
2. Neovim editing a UTF-8 file with mixed CJK and emoji
3. `ssh` to a remote host, run `vim`, resize the window
4. A long training run producing continuous output for minutes
5. A Python REPL, paste a multi-line function
6. `git log --graph --color` through a pager

**2026-09-02 — M2 closeout pass (items 1 and 3).** tmux, htop and
Neovim were not installed and the machine has no Homebrew
(`/opt/homebrew` absent; installing Homebrew itself needs sudo, which
unattended runs must not do), so tmux 3.5a and htop 3.4.1 were built
from source into a user-writable prefix (`/tmp/corta-tools`). Neovim
was not installed; nothing in items 1 or 3 needs it, so item 2 is
unaffected either way.

- **Item 1 (`tmux` split running `htop`, resize) — ran, no
  artifacts.** A live Corta window was launched with a `SHELL` wrapper
  that started tmux (private socket), split the window, and ran htop
  in the lower pane. Resizing the OS window from outside requires
  Accessibility permission and would prompt, so that half was not
  attempted unattended — a human still needs to drag the window edge.
  Instead tmux's own layout changes exercised the same terminal
  machinery from inside the child: `resize-pane` and `select-layout`
  force DECSTBM reprogramming and deliver SIGWINCH to htop.
  `capture-pane` after each step (baseline, grown, shrunk, two forced
  relayouts, htop tree-view and sort toggles) showed no garbage cells,
  no misaligned status line and no missing rows; htop's F-key footer
  and the tmux status line stayed correct throughout. A screenshot of
  the live window showed the htop footer and tmux status line
  upright and full size. `stty size` in the child (30 120) agreed with
  the tmux client size (120x30).
- **Item 3 (`ssh` to a remote host, `vim`, resize) — cannot run
  here.** `~/.ssh/config` contains exactly one entry, `github.com`,
  which is a git forge with no shell access; there is no configured,
  reachable remote host, and unknown hosts were not probed. The item
  remains unticked until a real target exists.
- **esctest re-run — reproduces the M2 number exactly.** esctest2
  (ThomasDickey/esctest2) with `--expected-terminal xterm
  --max-vt-level 3`, run as the child of a live Corta window against
  the M2-closeout build: **50 passed, 334 known bugs, 184 failed of
  568** — identical totals to the M2 record, and the list of failing
  tests is byte-identical to the M2 run's. No new failures, no fixes.
