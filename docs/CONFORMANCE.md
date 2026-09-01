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
| **Character width**: CJK wide, emoji, combining, zero-width | P0 | Wrong widths mean misaligned CJK text                 |
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
| **CJK IME** (`NSTextInputClient`)                | P0   | Harder than it looks — `DESIGN.md` §7.1             |
| Copy / paste with bracketed paste                | P0   |                                                    |
| Keyboard and mouse text selection                | P0   | Must respect the soft-wrap flag                     |
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
| Selection highlight                              | P0   |                                                    |
| Retina / HiDPI scaling                           | P0   |                                                    |
| **Font fallback** for CJK and emoji              | P0   | Core Text's strongest suit                          |
| Atlas eviction (LRU or multi-page)               | P0   | A CJK session exhausts a single page                |
| Gamma-corrected glyph blending                   | P1   | Otherwise light-on-dark text looks too thin         |
| Runtime font scaling (⌘+ / ⌘−)                   | P1   |                                                    |
| Ligatures                                        | P2   | Conflicts with the cell grid — `DESIGN.md` §7.3     |
| Background transparency, blur, padding           | P2   |                                                    |

### 2.3 Windows and sessions

| Capability                                              | Tier | Notes                                        |
| ------------------------------------------------------- | ---- | -------------------------------------------- |
| Single window, single terminal                          | P0   | M1                                           |
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
- [ ] ⌘+ / ⌘− resize the font
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

### 4.4 Manual scenario pass

Run at every milestone, because these are the actual workload:

1. `tmux` with a split running `htop`, resize the window
2. Neovim editing a UTF-8 file with mixed CJK and emoji
3. `ssh` to a remote host, run `vim`, resize the window
4. A long training run producing continuous output for minutes
5. A Python REPL, paste a multi-line function
6. `git log --graph --color` through a pager
