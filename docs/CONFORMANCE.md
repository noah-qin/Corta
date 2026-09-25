# Corta — Feature Conformance

[Documentation index](README.md) · [Project overview](../README.md)

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
| CHA / HPA / HPR / VPA / VPR — absolute and relative position | P0 | A TUI that lays a line out in segments jumps between columns rather than writing spaces; without these the whole screen collapses |
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
| **OSC 4 / 104** — indexed palette query, set, reset (B06) | P1 | 256-entry palette, seeded from the theme (0–15) and xterm's cube/greyscale (16–255); an override now repaints, not just answers a query — `docs/DESIGN.md` §7 |
| **OSC 5 / 105** — special colours query, set, reset (B06) | P2 | Five fixed slots (bold/underline/blink/reverse/italic), no themed default — see `SpecialColors`; `docs/DESIGN.md` §7 |
| **CSI s / u (SCOSC/SCORC)** — cursor save/restore alias (B06) | P1 | Corta has no DECLRMM, so these are unconditional aliases for DECSC/DECRC, matching xterm without left/right margins |
| **`?45` — reverse-wraparound mode** (B06) | P2 | `BS`/`CUB` cross onto the row above when it auto-wrapped into this one; off by default, matching xterm. Not DECBKM, which is the separate `?67` backarrow-key mode |
| Bracketed paste (`?2004`)                               | P0   | A safety feature, not a convenience — see `SECURITY.md` §2.3 |
| Mouse reporting (`?1000`/`?1002`/`?1003`, SGR `?1006`) | P1 | Press/release, wheel, cell-coalesced drag and motion; configurable local-selection override |
| Focus reporting (`?1004`)                               | P2   | Implemented; Neovim autoread and tmux focus events                |
| OSC 8 — hyperlinks                                      | P2   | Implemented; display text and target may differ — see `SECURITY.md` §2.4 |
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
| **DECRQM** (`ESC [ Ps $ p`)     | tmux, Neovim capability probes                 | Conservative fallback behaviour      |
| **XTVERSION** (`ESC [ > 0 q`)   | Modern TUIs                                    | Feature misdetection                 |
| **Dynamic colour** (OSC 10/11/12 query form) | Themes and TUI capability probes  | Probe times out                      |
| **Kitty keyboard** (`ESC [ ? u`) | Editors that bind `Ctrl+I` and `Tab` apart    | Both keys arrive as `0x09`           |

All four shipped in M6 (M6.5, M6.6, M6.9), plus **DSR operating status**
(`ESC [ 5 n` → `ESC [ 0 n`) and **DECXCPR** (`ESC [ ? 6 n`), both of which
went unanswered until M8. A status query is the one sequence where silence
is read as "the terminal is dead", and the programs that wait for it
without a timeout wait forever.

DECRQM answers 0 — "not recognised" — for the modes Corta does not track,
which is the honest reply and the one that unblocks the probe; the failure
mode this table is about is *silence*, not a negative answer.

**A mode reported as supported has to behave.** DECRQM's four-state answer
is a contract: a program that is told a mode is set lays its next screen
out against that behaviour, so answering 1 or 2 for a bit nothing acts on
is worse than answering 0. The four modifiable ANSI modes therefore split:

| Mode      | Answer | Why                                                     |
| --------- | ------ | ------------------------------------------------------- |
| IRM (4)   | 1 / 2  | Implemented (`Grid.insertMode`) — a print inserts and shifts the row right |
| LNM (20)  | 1 / 2  | Implemented (`PerformerState.newLineModeEnabled`) — LF/VT/FF also return the carriage, and Return sends CR LF |
| KAM (2)   | 4      | Deliberately not implemented: a terminal that stops accepting input on a byte from the child is one a runaway program can wedge, with no way for the user to tell it from a hang |
| SRM (12)  | 4      | Deliberately not implemented: Corta never echoes keystrokes itself, so there is no local echo to switch off |

4 is "permanently reset", which is a stronger answer than 0 — a program
learns not to ask again.

**Colour-space specifications (P2).** OSC 10/11/12 accept `#RGB` through
`#RRRRGGGGBBBB` and `rgb:R/G/B`. `rgbi:`, `CIELab:`, `CIEuvY:`, `CIExyY:`,
`CIEXYZ:` and `TekHVC:` are **refused**: the sequence is parsed, no colour
is changed, and nothing is written back. Each of those is a colour-space
conversion needing a white point and a gamma curve — the answer depends on
the display profile, so an implementation is either colour-managed
properly or it is a wrong number dressed as a right one. Refusing is also
the safe direction: a program that sets a colour and sees no change keeps
legible text, whereas a mis-converted `CIELab` black-on-black is a
terminal you cannot read. The corresponding esctest cases are recorded as
expected failures for this reason (`docs/history/ROADMAP-0.1.md`), and
`Performer+Query.parseColorSpecification` carries the policy in full.

**DECSCL gates DECRQM.** A program that announced VT200 with
`ESC [ 62 ; 0 " p` has asked to be talked to as an older terminal, and
DECRQM arrived at VT300. Answering anyway is the terminal ignoring what
it was told.

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
| Configurable key bindings                        | P1   | `bind.<command>` in the config file, one table for menus, palette and file — `CONFIGURATION.md` §5 |
| Click-to-position, drag-to-select                | P1   | Drag selects; a TUI that owns the mouse is overridden with `mouse-override-modifier` |
| ⌘-click to open a URL                            | P1   | Scheme allowlist required — `SECURITY.md` §2.4      |
| Kitty keyboard protocol                          | P2   | Implemented; progressive enhancement flags and protocol stack                                        |
| Tab / Shift-Tab through a candidate UI            | P0   | A completion menu or IME that resolves Tab as a command sends `insertTab(_:)` / `insertBacktab(_:)` to `doCommand(by:)`; both are forwarded to the child (B02) — `DESIGN.md` §7.1, `TerminalViewIMETests.doCommandForwardsTabAndBacktab` |

The candidate-UI row is the one whose evidence is incomplete. The code gap
was real and is closed, but a live confirmation that Claude Code's
slash-command menu accepts Tab inside a built Corta, compared side by side
with a reference terminal under an English input source, a CJK source with
no marked text and an active composition, has not been collected: the
original report's environment cannot be recovered (CHANGELOG 1.0.0). The
2026-09-17 record's A1 items are the closest evidence since.


### 2.2 Rendering

| Capability                                       | Tier | Notes                                              |
| ------------------------------------------------ | ---- | -------------------------------------------------- |
| GPU glyph atlas + instanced quads                | P0   | One draw call per screen                            |
| Foreground / background, bold, italic, underline | P0   | Real faces where the family has them; synthetic oblique and stroked weight where it does not |
| Missing glyph is visible, not blank              | P0   | Hollow box for a scalar no font in the cascade covers |
| Every glyph clipped to its cell box              | P0   | Overwide ink is scaled to fit rather than painted into the next column |
| Cursor: block / bar / underline, blink           | P0   | DECSCUSR shapes; blinking variants render steadily (see below) |
| Selection highlight                              | P0   | Document-anchored quads; follows its text as output scrolls |
| Retina / HiDPI scaling                           | P0   | Grid laid out in pixels, not points — one of §4.4's shipped bugs |
| **Font fallback** for CJK and emoji              | P0   | Core Text cascade list; the shaped run's font rasterises the glyph (M3.5) |
| Atlas eviction (LRU or multi-page)               | P0   | Full-page reset on exhaustion + `generation` rebuild (M3, `DESIGN.md` §7.4) |
| Gamma-corrected glyph blending                   | P1   | Otherwise light-on-dark text looks too thin         |
| Runtime font scaling (⌘+ / ⌘−)                   | P1   | Per-window, temporary; never writes `font-size` |
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
| Tabs                                                    | P1   | Native window tabs; a restored group keeps its order and selection (§4.4 item 6) |
| Split panes (layout tree + focus routing)               | P1   | Renderer and input are multi-viewport from M1 |
| Search scrollback (⌘F)                                  | P1   | Must match across soft-wrapped lines          |
| Scrolling (wheel, ⌘↑↓, page)                            | P0   | ⌘↑↓ jump between commands once shell integration reports them; ⇧Page/Home/End scroll |
| Bell (audible / visual / mute)                          | P1   | `bell` in the config file |
| Settings page                                           | P1   | Native page in the menu bar next to Edit/Shell, backed by one text file needing no third-party parser — M6.1 |
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
Each row names the record that last verified it by hand; an automated
suite is listed only where one pins the behaviour afterwards. A row
whose record is a roadmap tick has not been re-run since it landed.

| # | Holds when | Last verified by hand | Pinned by |
| --- | --- | --- | --- |
| 1 | Opens to a working shell with correct colour output | 2026-09-17 pass, H31 and G29 ([record](test-results/2026-09-17-interactive.md)) | §4.4's five-point check |
| 2 | `vim` / `less` / `htop` render without artifacts | 2026-09-17 pass: `less` and `git log` clean (G29); `tmux` + `htop` left residue after a window shrink (G25) — ECH was unimplemented, fixed the same day (§4.4.2) | `EditingTests`, golden fixtures |
| 3 | Chinese input works, displays, and never drifts out of alignment | 2026-09-17 pass, A1 on a physical keyboard, both panes of a split | `TerminalViewIMETests`, `WideGlyphRenderTests` |
| 4 | Copy and paste work; pasting multi-line code does not auto-execute | 2026-09-17 pass, G28 (the multi-line warning appeared for a REPL without bracketed paste) and 2026-09-19 (Option-drag selection to the clipboard) | `PasteTests`, `MouseReportingTests` |
| 5 | Scrollback holds a long training run and scrolls smoothly | 2026-09-17 pass, G27: 120 s of continuous output, the other window still responsive; the top of the run was past the 10,000-line default cap, as documented | `corta-bench` write-backpressure |
| 6 | ⌘F searches scrollback | M4.4 roadmap tick ([record](history/ROADMAP-0.1.md)); not re-run by hand since | `SearchTests`, `SearchAndTabUITests` |
| 7 | New tab and split pane | 2026-09-17 pass, C11: a restored two-pane window and a three-tab group | `SplitPaneUITests`, `SearchAndTabUITests` |
| 8 | ⌘+ / ⌘− resize the font | 2026-09-17 pass, C12 and H31 | `FontSizeZoomTests` |
| 9 | Resizing the window resizes the program inside it | 2026-09-17 pass, D16: `vim` through full screen and back, 120×30 → 207×62 → 120×30 | `PTYWindowSizeTests`, `ResizeDebouncerTests` |
| 10 | ⌘-clicking a `localhost:` URL opens the browser | M4.6 roadmap tick ([record](history/ROADMAP-0.1.md)); not re-run by hand since | `LinkDetectionTests` |

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

**How the esctest run is done.** esctest2 (ThomasDickey/esctest2), run
as the child of a live Corta window — it drives the terminal through its
own tty, so it has to be the shell:

```sh
# A wrapper passed only in the environment of the launch you control.
# Never via `launchctl setenv` (§4.5).
cat > /tmp/corta-esctest.sh <<'EOF'
#!/bin/bash
export TERM=xterm-256color
cd /path/to/esctest2/esctest
python3 esctest.py --expected-terminal xterm --max-vt-level 3 \
  --logfile /tmp/esctest-run.log
exec /bin/zsh -l
EOF
chmod +x /tmp/corta-esctest.sh
SHELL=/tmp/corta-esctest.sh Corta.app/Contents/MacOS/Corta
```

**Results, one row per run.** "xterm-compatibility" is passes plus
"known bugs" — the number esctest reports and the one comparable across
terminals; it is **not** a pass rate, and every row states all three
counts. The failing names of each run are kept in [`esctest/`](esctest/)
so the next run is a diff rather than a re-reading.

| Run | Build | Passed | Known bugs | Failed | Total | xterm-compat. | Against the previous row |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| M2 (2026-09-02) | M2 closeout | 50 | 334 | 184 | 568 | 67.6% | Baseline |
| M6 (2026-09-03) | M6 closeout | 106 | 335 | 127 | 568 | 77.6% | 57 failures fixed, none introduced: programmable tabs, CNL/CPL/CHT/CBT, IND/NEL/RI, RIS and DECSTR, including the soft-reset isolation esctest itself relies on |
| 0.1.1 (2026-09-08) | v0.1.1 | 112 | 335 | 121 | 568 | 78.7% | Six more passing, none regressed; classified by application impact in [the quality plan](history/V0.1.1-QUALITY-PLAN.md) Q01; names in [`esctest/0.1.1-results.txt`](esctest/0.1.1-results.txt). 45 of the 121 were OSC 4/5 palette set and query, then unimplemented |
| 2026-09-17 | `main`, esctest2 `2798f12` | 126 | 334 | 107 | 567 | 81.1% | 14 tests moved to pass — B06's OSC 4/104 and 5/105 set/query/reset, SCORC, and the multi-column reverse-wraparound case — none regressed; the suite itself lost one test and one known bug, so the totals are not identical columns. Names in [`esctest/2026-09-17-results.txt`](esctest/2026-09-17-results.txt); XtermWinops (28) is still the largest class and still deliberate |

### 4.3 Fuzzing

The parser consumes untrusted bytes and must never crash, hang, or
allocate without bound. The harness is the `corta-fuzz` target in the
`CortaTerminal` package (M6.11); it asserts the `SECURITY.md` §3 caps on
every input rather than waiting for a sanitizer to notice — grid
dimensions, the scrollback ring, cursor bounds, row width, the interned
grapheme and hyperlink tables, and the size of the response one input can
queue.

**libFuzzer is not available on macOS with the current toolchain.**
Xcode 26 ships no `libclang_rt.fuzzer_osx.a`, and
`swiftc -sanitize=fuzzer` is rejected outright for
`arm64-apple-macosx` — verified, not assumed. The
`LLVMFuzzerTestOneInput` entry point is present and correct for a
toolchain that has one; what runs today is a deterministic mutation
driver over a checked-in corpus:

```sh
swift build --package-path CortaTerminal -c release --product corta-fuzz
CortaTerminal/.build/release/corta-fuzz --fuzz 500000 --seed 1 \
  CortaTerminal/Tests/Fuzz/corpus
```

It has no coverage feedback, so it explores far less per iteration than
libFuzzer would. What it does have is a fixed seed, so a failure is
reproducible from the command line that found it. **Recorded at M6:**
2.5M mutated inputs across seeds 1–5, clean. A separate 100,000-input
run under AddressSanitizer (seed `3735928559`) was also clean.

The corpus itself replays inside the test suite (`FuzzCorpusTests`), so a
crash found by a long run is fixed by adding its input to
`CortaTerminal/Tests/Fuzz/corpus` — from then on it is a regression
test.

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
4. output longer than the screen scrolls and uses every row,
5. gestures and menu actions reach the pane — the terminal view is first
   responder, so `keyDown` fires and First-Responder menu items (⌘V, ⌘=)
   are not dead,
6. a *restored* tabbed window (three tabs, `kill -9`, relaunch) comes
   back in saved order with the saved tab selected and its first row
   below the tab bar — the one arrangement whose layout nothing but
   `regroupRestoredTabs` drives, and where 2026-09-17 found both the
   order and the inset wrong,
7. in a non-English locale (`-AppleLanguages '(zh-Hans)'` on the launch),
   the *menu bar* is translated, not only the menus beneath it.

The app that gets launched is the development build — the `Corta (Dev)`
scheme, `CortaDev.app`, bundle identifier `dev.noahqin.Corta.dev` (D22).
It can run beside an installed Corta, so identify the one under test by
bundle identifier or by PID; "the frontmost Corta" is ambiguous by
design, and a check that reads the wrong window is a check that proves
nothing. To run these against a *Release* build instead, stage it with
`CORTA_STAGE_DIR`.

**System entry points (B16) are checked by hand, and the record says
what was and was not.** A hotkey and a floating panel are properties of
the window server, not of the view hierarchy, so the check is: with
`quick-terminal = true` in a staged config (`CORTA_STAGE_DIR`), the key
summons the panel over another application and dismisses it again;
dismissing returns focus to that application; the panel appears beside a
full-screen app without leaving its Space; ⌘T from it opens a normal
window; Shell ▸ Secure Keyboard Entry shows the titlebar lock only while
a terminal window is key, and the lock clears when another app comes
forward. Multi-display placement (`quick-terminal-screen`) needs two
displays and is recorded as *not judged* when the machine has one — and
so does **display reconfiguration while the panel is open**: summon it,
then unplug the external display, change its resolution, and change which
display is the main one. The panel must end up inside a screen that
exists each time, keeping the screen it was on when that screen survives.
`QuickTerminalController.frameAfterScreenChange` is the rule, and
`QuickTerminalGeometryTests` pins it against synthetic arrangements, but
the notification reaching it and the window accepting the frame are only
established by doing this by hand. A
simulated keypress (`osascript` `key code`) does reach a Carbon hotkey,
which is how the summon/dismiss half and the titlebar lock were
exercised when B16 landed — over a single display, with the panel
opening as a top band and hiding when another app came forward.
The 2026-09-18 run of these four checks, one failure and its fix, are in
[`test-results/2026-09-18-release-checks.md`](test-results/2026-09-18-release-checks.md).

**Remote workflows (B13/B14) have a launched-app check of their own**,
`CortaUITests/RemoteWorkflowUITests`, which is the shape every
remote-path change is verified in. `CORTA_STAGE_DIR` (`AppPaths`) moves
the config file and Application Support under a throwaway directory —
`$HOME` moves neither on macOS — `SHELL` names a script called `ssh`
standing in for the remote shell (banner, a remote `OSC 7`, then
`/bin/sh -i`), and `CORTA_SFTP_SSH` points the SFTP channel at a script
that `exec`s the real `/usr/libexec/sftp-server`. The UI-test runner is
sandboxed (it reads all of `/`, writes only its container, which the app
cannot read), so the app builds the stage itself: the test's first
launch types `stage-remote-ui.sh` into an ordinary terminal. The walk:
`⟂` badge → keystrokes reach the pane → Browse Remote Files… (asked
first, host prefilled, nothing spawned before Connect) → a listing
answered by OpenSSH's own server → Edit → the "editor" rewrites the
managed copy → the upload prompt → the remote file changed with no
partial left → the fake shell exiting → badge gone → Reconnect → badge
back, keyboard live → the stage removed through the same terminal.
Nothing on the machine is changed and no network is used. Its first run
found six defects the unit suites had passed over (a spawn that never
returned, a write size the server rejected, a SIGPIPE that killed the
app, a consent step that auto-connected, an untitled window, a badge
that outlived its connection) — which is the argument for running it.
What it cannot cover, and a human still judges against a real host:
authentication and host keys (there is no `ssh` in the loop), and how
the panes look — they are Metal surfaces the accessibility tree cannot
read. `SFTPRealServerTests` in the core package drives the same server
without the app. The test selects the ABC keyboard layout for its own
duration and restores the previous input source afterwards — a CJK
input method would otherwise compose every typed line into candidates
instead of delivering it to the terminal.

### 4.4.2 Real-program verification (P0, M8.20)

Render tests and golden-file grid tests both assert that a byte stream
produces a grid. Neither can tell you that `vim` is usable. The five P0
areas below are *behavioural*, and every one of them has a failure mode
that a passing grid test is compatible with:

| Area                          | Verified with                                | What to look for | Result |
| ----------------------------- | -------------------------------------------- | ---------------- | ------ |
| Cursor movement, shape, blink, mode switches | `vim`, `nvim`, `htop`, `less`  | The cursor sits where the program thinks it does after a mode change; `DECSCUSR` shapes take effect; no ghost cursor in an unfocused pane | Pass |
| Scroll regions and the viewport | `tmux` with several panes, `less` on a long file | A region scroll does not disturb rows outside it; scrollback follows the bottom; scrolling back and returning lands where it started | Pass; see the note below |
| Left/right margins and wide characters | `vim` with a CJK file, `tmux` split narrow | A wide glyph never straddles the right margin; a resize rewraps without stranding rows | Pass |
| Insert and delete (ICH/IL/DCH/DL) | `vim` editing mid-line, `readline` with IRM | The redraw range matches the edit; nothing is left behind to the right of an insert | Pass |
| Erase (ED/EL/ECH) | `clear`, `htop` redraw, `tmux` window switch, **`tmux` window shrink** | No residue from the previous screen, and the cursor ends where the sequence says | Pass for ED/EL. **ECH was not implemented at all** until 2026-09-17 — this row said Pass on the strength of `clear`/`htop`, which never send it; tmux's status line (left part, `CSI n X`, right part) kept the previous screen's cells in the gap after a window shrink. Now implemented and covered by `EditingTests`. |

Run interactively on the release build (`vim ~/.zshrc`; `tmux` split
`%`/`"` and window switch `n`/`p`; `htop` refresh; `less` on
`/var/log/system.log` with `/search`, `n`, `g`/`G`; a CJK file in `vim`
and in a narrow `tmux` split; a mid-line edit in `vim`; `clear`), judged
by eye — not something a test target can assert. `esctest` (§4.2) covers
the sequences; this covers the programs.

An earlier run of this table recorded `less`'s search-match highlight
(reverse video on a `/` hit) as never rendering, with the fault not
isolated. The 2026-09-17 pass (G29) could not reproduce it: the highlight
was visible on the same command. It is not tracked as open; a fresh
reproduction with a grid dump of what `less` sends would reopen it.

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

### 4.5 Test fixtures must not outlive the test

A fixture shell was wired in with `launchctl setenv SHELL`, which applies
to every GUI application the user launches afterwards. Corta then started
under `zsh -f` — no rc files, so no PATH — and a demo banner printed on
every launch. Both looked like defects in the terminal.

Pass fixtures in the environment of a launch you control:

```sh
SHELL=/path/to/fixture.zsh Corta.app/Contents/MacOS/Corta
```

Never `launchctl setenv`, never the user's rc files, never `defaults
write`. Delete the fixture when finished.

### 4.6 Manual scenario pass

Run at every milestone, because these are the actual workload:

1. `tmux` with a split running `htop`, resize the window
2. Neovim editing a UTF-8 file with mixed CJK and emoji
3. `ssh` to a remote host, run `vim`, resize the window
4. A long training run producing continuous output for minutes
5. A Python REPL, paste a multi-line function
6. `git log --graph --color` through a pager

**B01 additions — the real-workflow matrix.** The issue asked for zsh, fish,
ssh, tmux, Neovim, fzf, CJK input, long output, sleep/wake, restoration and
AI CLI applications. zsh/tmux/Neovim/ssh/long-output are items 1–4 above;
fzf and fish are covered by `scripts/u10-real-workflows.py`'s scenario table
(it spawns real zsh/fish/tmux/nvim/fzf/ssh processes on real PTYs and
replays their output through the core — see the script's own docstring for
exactly what it can and cannot prove). The remainder, added here rather than
to the scriptable harness because none of them are drivable through a PTY
alone:

7. **CJK input** — an actual input source composing (not just CJK *text*,
   which item 2 already covers) through a live candidate window. Manual only
   — `DESIGN.md` §7.1's verification caveat: synthetic key events carry
   baked characters, so composition never opens for them.
8. **Sleep/wake** — the machine actually sleeping and waking with Corta
   running. Manual only, deliberately not scripted:
   `scripts/measure-app-baseline.sh`'s own comment is explicit that sleep/wake and
   low-power mode change machine-wide state other processes depend on, and
   need a dedicated session on an idle machine, not a CI-style script.
9. **Restoration** — force-quit or crash Corta with a multi-pane layout and
   scrollback, relaunch, confirm the arrangement and content return (U07).
   Partly scriptable: `scripts/measure-app-baseline.sh`'s `SessionRestore`
   config-flip pattern drives this without touching global machine state
   (it flips `restore-windows` in the config file, writes a `state.json`,
   launches, then restores the original config on every exit path) — but it
   drives the *mechanism*, and a human still has to judge whether what came
   back looks right.
10. **An AI CLI application** — Claude Code (or a similar TUI-driven AI CLI)
    run as the child, covering ordinary interactive use including
    tab-completion and its own keyboard handling. Manual only, and the
    origin of B02's reported regression — see that issue's entry under §2.1
    above; cross-referenced rather than duplicated here.

Items 7, 8 and 10 above have no automated substitute and are recorded with
an explicit **not judged** state when a pass has not actually run one
(precedent: `docs/history/V0.1.1-MANUAL-VERIFICATION.md`'s VoiceOver read-through, marked
"not judged" rather than silently skipped when the tester could not follow
spoken English closely enough to have an opinion). "Not judged" means
exactly that — no automated check stands in for it, and no claim of success
is made in its place.

### 4.7 The records

Every pass of §4.4, §4.4.2 and §4.6 is written up under
[`test-results/`](test-results/) as a dated file — what was checked, what
passed, what failed and what was *not judged* — and the findings are worked
off in the CHANGELOG. The record stays as written.

| Record | What it covers |
| --- | --- |
| [2026-09-02 — M2 closeout](test-results/2026-09-02-m2-closeout.md) | §4.6 items 1 and 3: `tmux` + `htop` under resize; no reachable ssh host |
| [2026-09-03 — M6 closeout](test-results/2026-09-03-m6-closeout.md) | Tabs, the settings page and theme switching live; focus reporting end to end; the esctest re-run; the gesture items left to a human |
| [2026-09-12 — B10 pass](test-results/2026-09-12-b10-pass.md) | The text-selection API decision, the accessibility tree audit, the translation audit, and what stayed *not judged* |
| [2026-09-16/17 — interactive pass](test-results/2026-09-17-interactive.md) | The first full sweep of §4.6 since 0.1.1, by tool and then by hand |
| [2026-09-18 — release checks](test-results/2026-09-18-release-checks.md) | What the 09-17 pass changed; the six human and hardware items for 1.0.0, including the Quick Terminal probe |
| [2026-09-18/19 — issues #88–#90](test-results/2026-09-19-issues-88-90.md) | Mouse tracking, shared coordinates and the toolchain decision |
| [2026-09-21 — 1.0.1 release checks](test-results/2026-09-21-1.0.1-checks.md) | §4.4 points 1–5 for the patch release, the themed cursor on screen, what was not re-run and why |
