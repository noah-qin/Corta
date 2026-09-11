# Changelog

All notable changes to Corta are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

While the major version is `0`, a minor bump may contain a breaking change
to the config file format; those are always listed under **Changed** with
what to edit.

## [Unreleased]

### Added

- **B03 — session lifecycle and input backpressure made explicit.**
  `TerminalSession.write` now returns a `WriteOutcome`
  (`.accepted`/`.backpressured`/`.stopped`) instead of silently dropping a
  chunk the child was not reading for; a paste is split into bounded
  chunks (`Paste.chunked`) rather than enqueued as one arbitrarily large
  write, so a keystroke typed mid-paste waits behind one chunk instead of
  the whole paste, and a paste that hits backpressure stops instead of
  queuing chunks that can only be dropped. `TerminalSession.onChildExit`
  — built since M2 but never installed by the app — is now wired: a child
  that exits on its own (`exit`, a crash, `kill`) shows a toast, and a
  `sessionGeneration` counter on `ViewController`, carried through every
  reader-thread callback's `@MainActor` hop, keeps a stale session's
  callback from touching a pane that has since started a different one
  (`docs/DESIGN.md` §7, "Ownership and synchronization audit," has the
  full map).
- **B01 — the v1 validation and performance baseline.** User-visible
  targets for input, sustained output, scrolling, startup, memory, energy,
  compatibility and recovery (`docs/PERFORMANCE.md` §1.1); the exact
  toolchain (Xcode, Swift compiler and language mode, macOS, deployment
  target) recorded distinctly rather than conflated (§5.2); a fresh
  headless `corta-bench` p50/p95/p99 sample under that toolchain (§5.1); the
  real-workflow test matrix extended with CJK input, sleep/wake,
  restoration and an AI CLI application row, each marked automated,
  partly-automated or manual/"not judged" (`docs/CONFORMANCE.md` §4.6); and
  Swift Testing `Attachment` output for the offscreen render-correctness
  tests, so a pixel-mismatch failure carries the rendered PNG instead of
  only the failed comparison.

- **B04 — the scrolled-away viewport now stays anchored to what it was
  showing.** `scrollOffset` was a raw distance from the live bottom, so it
  silently pointed at different text every time output arrived while the
  user was scrolled up — the same number of lines above a bottom that had
  just moved. `scrollAnchorTotalPushed` shifts it by the scrollback's growth
  on every output batch instead, keeping the document position fixed.
  Typing and pasting while scrolled away now return the viewport to the
  bottom (`ViewController.returnToBottomOnInput`), matching every comparable
  terminal — the anchor above is deliberately *not* applied to those, since
  input is the user's own request to talk to the live screen. `docs/DESIGN.md`
  §7 has the full account, including what is still open (a unified
  viewport/selection/search coordinate mapping, and a discoverable
  selection/mouse-reporting override blocked on `?1002`/`?1003` support).

- **B06 — indexed palette query, set and reset (OSC 4/104).** A program
  naming a colour by number (`\e]4;137;?\e\\`) got silence, and setting or
  resetting one (`\e]4;1;#ff0000\e\\`, `\e]104\e\\`) was a no-op. Added
  `IndexedPalette` — a 256-entry `defaults` array plus a sparse
  `overrides` dictionary, the same shape `DynamicColors` already uses —
  wired through `PerformerState`/`Terminal`/`TerminalSession`, with
  `defaults` seeded from the active theme's ANSI colours (0–15) and
  xterm's fixed 6×6×6 cube and greyscale ramp (16–255) so a query answers
  with what is actually drawn, matching how OSC 10/11/12 already work
  (`docs/DESIGN.md` §7). Render-path integration (making an override
  actually repaint) and OSC 5 are explicitly out of scope for this change
  — see the same `DESIGN.md` entry for why.

### Fixed

- **B04 — a selection drag kept running after the window lost focus.**
  `handleSelectionMouseDown`'s blocking local event loop already exited if
  the pane closed mid-drag, but not if the window simply lost key status
  (Cmd-Tab, a new window from a global shortcut, Mission Control) — it kept
  blocking on drag and auto-scroll events for a window the user was no
  longer looking at. The loop now ends the same way the pane-closed case
  already does, leaving whatever was selected up to that point standing.
- **B06 — `BS`/`CUB` did not reverse-wrap at a wrap boundary.** Backspacing
  or moving the cursor left off column 0 always stopped there, even when
  the row above had auto-wrapped into the current one — line editing at a
  wrap boundary (`readline`'s among them) could not walk back across it.
  Added `?45` (reverse-wraparound mode — not DECBKM, which is the
  separate `?67` backarrow-key mode; off by default, matching xterm):
  while set, `BS`/`CUB` continue onto the row above's last column when
  that row's own `wrapped` flag says the two are one logical line, never
  across a hard newline. The mode also now survives an alternate-screen
  round trip (`?1049`), the same way `cursorStyle` already does — it is
  terminal-wide state, not part of either screen's own content.
- **B06 — `CSI s` / `CSI u` cursor save/restore did nothing.** Corta has
  no DECLRMM, so — matching xterm without left/right margins — these are
  now unconditional aliases for `DECSC`/`DECRC` (`ESC 7`/`ESC 8`). The
  kitty keyboard protocol's own `CSI u` forms are intercepted earlier in
  dispatch and are unaffected.
- **B05 — search case-sensitivity and regex mode leaked across panes.**
  Both were read live from `ConfigurationStore` on every sweep; toggling
  either in one pane silently changed what a second, already-open pane's
  next sweep matched, without that pane's button ever updating. Each pane
  now keeps its own local copy, seeded from the config default when its
  bar opens.
- **B05 — Esc could close the wrong pane's search bar in a split.** B02
  scoped the Esc handler to the event's window, but two panes in one
  split share a window; Esc now also checks that this pane's search field
  is the one actually being edited.
- **B05 — output at the tail of a burst could leave search results
  stale.** `scheduleBackgroundSearchRefresh` dropped an output-triggered
  refresh outright whenever a sweep was already running, on the
  assumption more output would trigger another one — true only while
  output kept arriving. A dropped request is now remembered and run once
  the in-flight sweep lands.
- **B05 — closing search after output arrived could restore the wrong
  scroll position.** The pre-search offset was restored verbatim; output
  that arrived while the bar was open shifts what that raw number points
  at, the same drift `docs/DESIGN.md` §2.7 documents for a selection. The
  restore now shifts by the scrollback growth since the bar opened.
- **B05 — large copy/export could stall input.** `⌘C`/`⌘A` and `⇧⌘S`
  built their text — up to the whole scrollback — synchronously on the
  main actor, which is the interaction path in this app. Both now build
  on a detached task, with an empty document or selection still skipping
  the save panel entirely, and export's save panel itself now cancellable
  (dismissed and its wait released) if the pane closes or a second export
  supersedes it while the panel is open.
- **B04 — selection highlight and copied text could disagree once the
  scrollback ring saturated.** `TerminalRenderer.selectionQuads` and
  `KittyImageRenderer` shifted a selection/image placement's document row by
  `scrollback.count`, which saturates at the ring's limit; `⌘C` already used
  the monotonic `scrollback.totalPushed`, so once the ring was full the two
  drifted apart — the highlighted line and the text actually copied were no
  longer the same line. Both now use `totalPushed`, including the render
  cache's own damage-invalidation key, which had the identical bug (a
  `.count`-based comparison stops noticing scrollback changed once the ring
  is full, so a stale frame could stay on screen).
- **B04 — a column-resize reflow left a stale selection and scroll
  position.** `Grid.resize` rebuilds `Scrollback` from scratch on a column
  change, but nothing cleared `ViewController.selection`/`scrollOffset`
  across that, so both could keep pointing at rows a reflow had already
  rewritten. Both now clear when the column count actually changes (a
  row-only resize is ordinary scrollback growth and needs no clearing).
- **B04 — a selection drag left running past its pane closing.** The
  drag-tracking loop's blocking `window.nextEvent(matching:)` kept touching
  the pane's `session`/`terminalRenderer` for the rest of the gesture if the
  pane (or its window or tab) closed mid-drag. It now exits as soon as the
  terminal view is no longer part of a window.
- **B02 — Tab dropped by a candidate UI (e.g. Claude Code's slash-command
  menu).** `doCommand(by:)` had no case for `insertTab(_:)` /
  `insertBacktab(_:)`, so a Tab press a candidate window resolved as a
  command rather than committed text was silently dropped instead of
  reaching the child as `0x09` / `CSI Z`.
- **B02 — search-bar Escape leaked across windows.** The Esc key monitor
  installed while the search bar is open fired for every window in the app,
  so Escape in one pane could close a search bar open in a different pane
  or window. Scoped to the window the event actually belongs to.

## [0.1.1] - 2026-09-09

The quality release. Nothing here changes what Corta is; all of it is
work on what was already there — the places it could be made to
misbehave, the places it was slower than it had to be, and the places it
was guessing at what the user meant.

**Upgrading.** No configuration change is required and no config key
changed meaning. Everything below is additive or a fix; a `~/.config/corta/config`
written for 0.1.0 keeps working unchanged.

Two things worth knowing before you read the list. `option-as-meta`
existed in 0.1.0 and **did not work** — if you tried it and gave up, try
it again. And the terminal answered `XTVERSION` with `Corta(0.1.0)`
regardless of the build; it now answers with the version it actually is,
which matters to anything doing capability detection.

### Added

- **Every string translated into all nine shipped languages.** The
  commands, settings and toasts added in this release had shipped in
  English only — 41 keys against 156 that were complete. A test now
  checks the whole catalog rather than a sample, including that each
  translation carries the same format specifiers as its source.

- **U11 (2026-09-08)** — Clear Screen (⌘K), Clear History and Reset
  Terminal, as three separate commands with a table in
  `docs/CONFIGURATION.md` §5 saying what each one discards. They act on
  Corta's grid, not on the child's input, so a running job is undisturbed.
  Clear History and Reset ship unbound and ask before discarding history,
  honouring `confirm-close`.
- **U12 (2026-09-08)** — A **Match Case** toggle in the Find bar, backed by
  `search-case-sensitive`; and a pill in the corner of a scrolled pane
  saying how far back the viewport is, changing its wording when new output
  has arrived, and returning to the live screen when clicked.
- **U13 (2026-09-08)** — Zoom Pane (⇧⌘⏎): fills the window with the focused
  pane and puts the split back. Temporary — no pane is closed, no child
  disturbed, and the saved arrangement still describes the splits.
- **U14 (2026-09-08)** — Copy Last Command Output, and Previous/Next Failed
  Command (⇧⌘↑ / ⇧⌘↓), on the OSC 133 marks Corta already records.
- **U15 (2026-09-08)** — Reopen Closed Pane (⇧⌘T), which restores the
  arrangement a closed pane had and never claims to restore its process;
  and Export Text… (⇧⌘S), which writes the selection — or the whole
  scrollback — to a file.
- **U16 (2026-09-08)** — Regular-expression search behind a `*` toggle
  (`search-regex`), budgeted and cancellable, with a per-line length bound
  and a distinct "bad pattern" state; and named shell/directory/environment
  presets (`preset.<name>.*`) under Shell ▸ New Pane with Preset; holding ⌥
  opens one in a window of its own.
- **U17 (2026-09-08)** — ⌘-click on `path:line:column` in program output
  opens the file, optionally through `open-file-command`. Local only: a
  pane inside `ssh` resolves nothing. The URL scheme allowlist is unchanged.
- **U05 (2026-09-08)** — `option-as-meta` is now readable from the config
  file and has a switch in Settings; it was previously written but never
  parsed, so setting it did nothing.
- **U04 (2026-09-08)** — Application keypad mode (DECKPAM / DECKPNM). The
  keypad sends its SS3 forms to programs that asked for them via `smkx`.

### Fixed

- **U01 (2026-09-08)** — The accessibility rectangle for a range ending on a
  wide character clipped half of it: three CJK characters were outlined as
  five cells instead of six. Found by probing the running app through the
  accessibility API, not by a test — the unit test's stub made the wrong
  answer look right.
- **U14 (2026-09-08)** — `OSC 133 ; C` is now recorded, so the last
  command's output is read rather than guessed at one row past the prompt; a
  two-line prompt no longer leaks its second line into the copy. Scrolled
  back, the command copied is the one on screen.
- **U16 (2026-09-08)** — A regular expression whose shape makes a
  backtracking engine take exponential time is refused before it runs and
  reported as too slow, rather than pinning a thread for the life of the
  app: neither `NSRegularExpression` nor Swift's `Regex` exposes ICU's time
  limit, and measurement showed no input length small enough to bound one.
  A sweep that merely runs long stops on a time budget and says its count is
  a floor.
- **U17 (2026-09-08)** — `open-file-command` is validated when it is set, not
  only when it is run, and has a Settings field.
- **U01 (2026-09-08)** — Accessibility hit-testing converted a *screen*
  point as if it were a window point, and both directions of the
  UTF-16-offset-to-column conversion assumed the two counts were equal —
  wrong for any CJK, emoji or combining text. The exposed text also ignored
  the scroll position, so a screen reader scrolled into the history read
  the live screen.
- **U02 (2026-09-08)** — The preedit overlay carried a copy of the cell
  metrics that nothing read; sizing came from the cursor rect all along.
- **U07 (2026-09-08)** — The window arrangement was written only at quit —
  the one moment a crash never reaches — and the state file was deleted at
  launch, so a crash lost it entirely. It is now written debounced as the
  layout changes, with a marker file separating "crashed during a restore"
  from "crashed at any other time". Restored geometry and split trees are
  validated: non-finite or impossibly small frames, divider fractions
  outside a usable range, and trees nested past 12 levels are repaired.
- **U08 (2026-09-07)** — Three shortcuts were hard-coded and so outlived
  their bindings: ⌘V pasted even after Paste was rebound or unbound, ⌘↑
  scrolled to the top of the scrollback once Previous Command was unbound,
  and ⌘F opened the Find bar after Find was rebound.
- **U09 (2026-09-08)** — A pane that failed to start was silent to a screen
  reader and left nothing focused for the keyboard.

**Found while publishing.**

- **An update for 0.1.0 users would never have arrived.** Sparkle compares
  `CFBundleVersion` — the build number — and `CURRENT_PROJECT_VERSION` had
  been 1 since 0.1.0 and was still 1 here, so 0.1.1 looked to every
  installed copy like the version it was already running.
  `generate_appcast` showed it plainly: it overwrote 0.1.0's feed entry
  instead of adding one. The build number is 2 now, a test refuses a build
  number a 0.1.0 install could not be offered, and the release checklist
  names all three version numbers instead of two.

**Found by the Stage 4 audits.**

- The terminal answered `XTVERSION` with `Corta(0.1.0)` whatever version it
  was built as, because that string is written by hand in two places and
  only one of them had moved. A test pins `CortaVersion.string` to the
  bundle's version now, so they cannot drift apart silently again.
- **DECID (`ESC Z`)** went unanswered. A query that is silent leaves a
  client waiting for a reply that never arrives; it answers exactly what
  `CSI c` answers.
- **DECALN (`ESC # 8`)** was not implemented at all — every escape sequence
  carrying an intermediate byte was discarded with the charset designators.
  It fills the screen with `E`, resets the margins and homes the cursor,
  which is how a program asks for a completely known screen.

**Found by using the app, in the manual verification pass (2026-09-09).**
Four defects that no test in this repository would have caught, listed in
the order they were met:

- **Option as Meta had never worked.** With `option-as-meta = true`, ⌥F
  typed `ƒ` instead of sending `ESC f`. The encoder handled the setting
  from the day it shipped and the key event never reached it: an ⌥-only
  press carries neither ⌘ nor ⌃, so it went to the input context first,
  macOS composed the layout's alternate character, and it came back as
  text. On a US layout that is most letters — the setting was inert for
  exactly the keys people enable it for. ⌥ now bypasses the input method
  when, and only when, ⌥ is Meta; with the setting off it still reaches
  the input method, which dead keys and international layouts depend on.
- **Marked text was unreadable in a light appearance.** The IME preedit
  overlay drew in a fixed near-white, from a stored copy of "the colour
  the renderer uses" that stopped being true when the palette started
  following the theme and the system appearance. It reads the live
  palette now.
- **Text grew and shrank through a window zoom.** For a layer-hosting
  view AppKit owns the layer's `contentsGravity` and derives it from
  `layerContentsPlacement`, whose default is "stretch what you are
  holding to whatever size you have just been given" — so the last
  presented frame was scaled up for the length of the animation. The
  placement is set through AppKit now, and the canvas no longer animates
  its own geometry.
- **`commandOutputRows(before:)` could answer with the wrong command.**
  Scrolled above the first prompt, "copy the command in view" copied the
  *newest* command's output, because the lookup fell back to the last
  prompt when the bound was above every prompt.

### Verification

- **Keypress → pixel (2026-09-09)** — Typometer 1.0.1 at M6.12's settings
  against the Release build: **57.8 ms average, 45.3 ms min, 78.9 ms max,
  5.6 ms SD** over 200 samples, with `PERFORMANCE.md` §5.2's environment
  table held and recorded in full for the first time — machine and chip,
  OS, build, panel and refresh rate, scale, font, window, power source, and
  the test program (`cat > /dev/null`). That is 12.3 ms above M6.12's
  45.5 ms, and §5 records why the comparison is softer than it looks:
  M6.12 recorded its Typometer settings and not its test program, and no
  run has recorded the machine beyond "MacBook Air, Apple silicon". The
  same run is the re-measurement M9 has owed since it landed.
- **Manual verification (2026-09-09)** — the six checks in
  `docs/V0.1.1-MANUAL-VERIFICATION.md`, run by the maintainer. VoiceOver
  reads the grid with correct row and column, and its cursor box covers a
  wide character whole. The IME candidate window follows the preedit across
  font-size changes, both panes of a split, and fullscreen. A German layout
  composes dead keys and its option characters with `option-as-meta` off,
  and sends Meta with it on. `copy-on-select` keeps its default. Composing
  Chinese is indistinguishable from Terminal.app and Ghostty. What was not
  judged is recorded as not judged.
- **esctest (2026-09-08)** — 112 passed, 335 known bugs, 121 failed of
  568, against M6's 106 / 335 / 127. xterm-compatibility is 78.7%, up
  from 77.6%. The failures are classified by real application impact in
  `docs/V0.1.1-QUALITY-PLAN.md` Q01, and every failing test name is kept
  in `docs/esctest/0.1.1-results.txt` so the next run is a diff. The
  largest single cause is one absence: OSC 4/5 indexed palette set and
  query are not implemented.
- **Nightly CI (2026-09-08)** — a lane for the checks a pull request
  cannot carry: the core suite under thread and address sanitizers, and
  a twenty-million-iteration fuzz run on a rotating seed. Both are clean;
  the sanitizer lane found a test that had been asserting a property it
  never established, and it is fixed. Pull-request checks gain job
  timeouts, `contents: read`, and the `.xcresult` bundle and fuzz corpus
  uploaded on failure.
- **Real-workflow harness (2026-09-08)** — 12 passed, 1 skipped, 0
  failed against zsh, fish, tmux, Neovim, vim, less, fzf, mouse
  reporting and 20k lines of sustained output, each driven on a real PTY
  and replayed through the core. `corta-dump --serve` answers a client's
  terminal queries from that same core, which is what lets fish — which
  waits for Primary DA before it prints a prompt — run under it at all.
- **Same-machine comparison (2026-09-08)** — 19.1 MB through the tty:
  Corta 0.204 s, Ghostty 0.164 s, Terminal.app 0.305 s, with Corta the
  smallest resident set of the three at idle. Input latency was measured
  separately (above); IME across terminals has no measurement and was
  compared by eye.

### Changed

- **UI02 (2026-09-06)** — The Find bar's glass is now tinted with the
  window background (fully opaque only under Reduce Transparency), and its
  match-count label uses the secondary label colour instead of tertiary, so
  the query and "n/m" stay readable over bright terminal output in both
  light and dark themes.
- **UI03 (2026-09-06)** — The active-pane focus ring is drawn at half
  accent-colour strength instead of full-strength blue, so it marks the
  pane without outshouting the text it frames; full colour returns under
  Increase Contrast.
- **UI06 (2026-09-06, extended 2026-09-08)** — The Shell menu is regrouped
  as presets, create (splits), move (focus moves, then the command jumps),
  terminal state (U11), resize (zoom, grow/shrink pairs, then Equalize
  Panes); command jumping no longer sits behind the geometry group.
- **UI07 (2026-09-06)** — View's separate Theme and Appearance submenus are
  merged into one Theme submenu: the appearance choice (Follow System /
  Light / Dark) heads the list, the themes follow below a separator, each a
  plain checkmarked single choice.
- **C03 (2026-09-06)** — Removed the assertion-less `testExample` template
  test from `CortaUITests`.

## [0.1.0] - 2026-09-05

The first release. Everything below is what `main` accumulated through
M1–M10.

### Added

**Terminal engine**
- A hand-written VT parser covering VT100/VT220 through `xterm-256color`,
  with 256-colour and true-colour SGR.
- Query responses — DA1/DA2, DSR, DECRQM, DECRPM — answered in fixed
  format and never echoing stream-supplied bytes. DECSCL gates DECRQM: a
  program that announced VT200 is answered as VT200.
- IRM (insert mode) and LNM (newline mode) are implemented, not just
  parsed; DECRQM reports their live state honestly, and KAM/SRM report
  permanently reset rather than staying silent. DSR operating status
  (`CSI 5 n`) and DECXCPR (`CSI ? 6 n`) are answered — both were silent,
  which reads as a dead terminal to a program that polls them.
- Unsupported colour spaces (`rgbi:`, `CIELab:` and kin) are refused with
  a documented policy rather than silently ignored.
- The kitty keyboard protocol, so editors can bind `Ctrl+I` and `Tab`
  apart.
- OSC 8 hyperlinks, bracketed paste, focus reporting, alternate screen,
  scroll regions, tab stops, and the mouse reporting modes.
- Lines carry a `wrapped` flag, so reflow, selection and search agree on
  where a logical line begins and ends.
- Cells are a fixed 16 bytes; grapheme clusters and hyperlink ids spill to
  interned side tables. `CellLayoutTests` asserts the size.
- Scrollback with eviction, and incremental reflow on resize.

**Rendering**
- Metal renderer: a GPU glyph atlas, instanced quads, one draw call per
  screen, and a triple-buffered instance buffer.
- Damage tracking at line granularity — a static screen rebuilds nothing,
  and idle CPU measures 0.0%. The check itself compares a per-row
  revision stamp (`Grid.lineRevision`, bumped centrally by `ScreenLines`)
  rather than full row contents, and a whole-screen scroll shift
  repositions surviving rows by a Y-coordinate offset instead of
  rebuilding them through Core Text/atlas lookups.
- `CAMetalDisplayLink` in place of `CADisplayLink` +
  `metalLayer.nextDrawable()`, gated on window occlusion without ever
  pausing the PTY reader thread.
- Compiled render pipelines are cached to disk (`MTLBinaryArchive`) and
  read back on a later launch instead of recompiled.
- The glyph atlas is split into independently packed, independently
  evicted pages (ASCII, shaped/CJK, colour), so a CJK-heavy screen no
  longer evicts the ASCII cache and vice versa.
- The frame-rate range adapts to window focus, Low Power Mode, thermal
  pressure and an active trackpad scroll gesture.
- `RenderMetrics`: ring-buffer percentiles for drawable-wait, frame-CPU
  and GPU time, dumped to the unified log behind `CORTA_RENDER_METRICS`
  — a before/after number without opening Instruments each time.
- Cursor styles (block, bar, underline) with blink; bold, italic,
  underline and strikethrough; selection drawn as document-anchored quads
  that follow their text as output scrolls.

**Graphics**
- The Kitty graphics protocol: images placed and displayed inline via
  the APC-based control/payload sequences, verified against a real
  client (`kitten icat`), which found and fixed four protocol bugs no
  hand-written test had caught.

**Text and input**
- Full `NSTextInputClient` conformance: marked text, a candidate window
  positioned under the cursor in any split, and preedit rendered as an
  overlay that is never committed to the grid.
- Correct East Asian character widths, combining marks and emoji
  presentation, with Core Text font fallback.
- Mouse and keyboard selection — drag, double-click word, triple-click
  logical line, shift-click extend — anchored to document rows.
- Copy joins soft-wrapped lines into one and trims trailing blanks.
- ⌘-click to open a URL, behind a scheme allowlist.
- Pinch-to-zoom, and file drops that insert a correctly quoted path.

**Window and application**
- Splits as a binary layout tree, with geometric focus movement and input
  routed to the focused pane only.
- Search across the scrollback.
- A native settings page and colour themes — Corta, Solarized and Mono,
  each in a light and a dark variant.
- Configuration in one text file at `~/.config/corta/config`, watched for
  external edits. The settings page is a front over that file and holds no
  state of its own.
- `columns` and `rows` in the config file, and a "New window" row in
  Settings: the grid a new window opens with, in cells. It was hardcoded
  at 120×30. The window's pixel size is that grid times the font's cell
  metrics, so two terminals showing the same grid are still different
  sizes on screen when their fonts differ.
- [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md) — every config-file
  key: its values, its default, when it takes effect, the theme and
  keybinding key families, the full command table with default
  shortcuts, and what is deliberately not configurable.
- A long-running-task notification, off by default.
- Shell integration (OSC 133): prompt and exit-status marks in the left
  edge of each prompt row, ⌘↑/⌘↓ to jump command to command, and an exact
  long-task notification when the shell reports boundaries. The
  keystroke-and-idle heuristic remains for shells with no integration
  configured.
- Session restore — windows, split layout, divider proportions and each
  pane's working directory — and a Dock click that reopens a window when
  none is open.
- A confirmation before closing a pane, window or the app while a shell
  still has a foreground job.
- A command palette (⇧⌘P) over every command Corta has, grouped (Recent,
  Window, Panes, View, Edit, App) with recent-use tracking, an empty
  state instead of a blank table, and arrow glyphs for navigation keys
  instead of `LEFT`/`RIGHT`.
- Help > Keyboard Shortcuts (⌘/): every command, grouped, with the key
  that runs it — unbound commands included — read from the same table
  the menus and the palette use.
- A copy confirmation. Copying — from ⌘C or from copy-on-select — shows a
  short-lived label in the corner of the pane, so the clipboard never
  changes with nothing to show for it.
- An About window of Corta's own: icon, version and build, the version the
  terminal reports over XTVERSION when it differs, links to the project,
  the release notes and the licence, and the copyright line the standard
  panel had no value for.
- Check for Updates…, under a signed feed ([Sparkle](https://sparkle-project.org)),
  and a daily background check you can turn off with `update-auto-check`
  in the config file. The one third-party dependency in the app shell;
  the terminal core has none.
- Rebindable keyboard shortcuts, `bind.<command> = cmd+shift+d` in the
  config file; an empty value unbinds.
- Themes defined in the config file, inheriting from a built-in so a
  two-line theme is a legal theme.
- Keyboard pane resizing by whole cells, and Equalize Panes.
- Copy on select, and `link-activation = click` — hovering a link
  underlines it and shows the target, and a click that never moved opens
  it. ⌘-click remains the default.
- OSC 52 clipboard *write*, off by default (`SECURITY.md` §2.6). The read
  form is not implemented and will not be.
- A first-launch offer to move Corta to `/Applications` when it is
  running unzipped somewhere else — direct-download distribution has no
  drag-to-install step, and both Sparkle's update path and Spotlight
  expect an installed location.

**Accessibility**
- VoiceOver and every other assistive technology can now read the
  terminal. `TerminalView` implements the text-area accessibility
  protocol — value, selection, insertion point, per-line ranges, and
  on-screen frames for a character range — from a snapshot gated on
  VoiceOver actually running, so the render path pays nothing otherwise.
- Reduce Motion, Reduce Transparency and Increase Contrast are honoured
  throughout: animations gate on Reduce Motion, the search bar and
  command palette take an opaque fill under Reduce Transparency, and
  status is never carried by colour alone (a symbol and a sentence come
  first, the tint last).

**Project**
- Golden-file grid tests, a fuzz harness (`corta-fuzz`) with a checked-in
  corpus, and a parse/memory benchmark (`corta-bench`) reporting
  p50/p95/p99/max over 2,000 samples rather than an average.
- `os_signpost` across the whole input chain — keyDown → PTY write → grid
  revision → MainActor wake → display-link callback → GPU completion —
  so a latency regression is one interval wide in a trace instead of
  invisible to every passing test. Coverage reaches every keypress path,
  not only the ⌘/⌃ control-sequence bypass: ordinary typing
  (`insertText`) and Return/Delete/Escape/the arrows (`doCommand(by:)`)
  are signposted too — a real-client trace of ordinary typing once
  showed zero `keyDown` events despite real keystrokes reaching the
  child, which is what exposed the gap.
- Apache 2.0 licence, a security policy, a code of conduct and issue and
  pull request templates.

### Changed

- **`copy-on-select` now defaults to `true`.** It was off because copying
  replaced the clipboard silently; the copy is now confirmed on screen,
  which was the whole objection. Set `copy-on-select = false` to restore
  the old behaviour.
- **One theme and one font are offered.** The settings page and the View
  menu list the `corta` theme, and the font family picker is gone: Corta
  uses the system monospaced face. Neither is a removal — `theme =
  solarized`, `theme = mono`, `theme.<name>.inherit = solarized` and
  `font-family = <any verified family>` all keep working from the config
  file. What is gone is Corta recommending faces and palettes it has not
  vouched for.
- The settings page is a tabbed preference window — Appearance, Terminal,
  General — that resizes to the tab it is showing. Every control sits in
  one value column, each explanation is one line under the control it
  belongs to, and the config file's path is pinned under a hairline at the
  bottom instead of scrolling away. It was a single scrolling page 534×819
  points tall for eleven settings.
- ⌘+ / ⌘− / pinch write the new font size to the config file. The size
  used to live only in memory, so the next config change of any kind
  reset the zoom and a relaunch forgot it.
- **Deployment target raised to macOS 26.0**, across every build
  configuration and the `CortaTerminal` package.
- A mouse drag now always selects text past an app-owned mouse
  reporting mode (SGR, etc.) — no modifier held, and no more terminals
  where a program that turned on mouse reporting (Claude Code, `vim`
  with `mouse=a`, `htop`) made its own output unselectable. A click that
  never leaves its starting cell still reports to the child as before.
- The General settings tab is grouped into Window / Closing /
  Notifications sections instead of one flat list.
- The focus ring is thinner (2pt → 1pt), gets a faint accent highlight,
  and only shows while a pane truly holds the keyboard — ⌘-Tabbing away
  now clears it instead of leaving it on the split's last-focused pane.

### Fixed

- `SGR 2` (dim) renders. The attribute was parsed and stored since M1 and
  drawn nowhere, so the secondary text every CLI marks this way — `git
  log`'s hashes, `ls -l`'s metadata, a spinner's hint line — came out at
  full strength.
- The Bell setting survives a rename. The chosen mode was recovered from
  the pop-up's *title*, which worked only while every display name was its
  raw value capitalised.
- Selecting a theme the settings page does not list no longer overwrites
  it. A config file naming an unoffered theme left the pop-up with nothing
  selected, and the next click on any control in the page wrote the first
  item back over the user's choice.
- The notification threshold is disabled while notifications are off, and
  says that it only fires for a background window.
- XTVERSION reports the real version. It was a string literal in the
  query code that a release bump had no reason to visit; it now comes from
  `CortaVersion`, next to the note about keeping it and `MARKETING_VERSION`
  in step.
- The Bell setting did something. The settings page wrote `bell` to the
  config file while the bell itself read a `UserDefaults` key, so changing
  it had no effect at all. There is now one store, as there was always
  supposed to be.
- Only font families that actually render on a grid are offered. The list
  was filtered by `isFixedPitch` on a family's *first* face, which let
  through families whose bold face is wider (bold text painted into the
  next column), families that are monospaced for letters but not digits
  (ragged TUI borders), and bitmap and colour faces (blurred or blank).
  Every ASCII advance is now measured across all four faces Corta draws
  with.
- Italics render. `SGR 3` was parsed and the attribute set, and the
  renderer had no italic path at all, so italic text drew upright.
- A family with no real bold or italic face gets a synthesised one rather
  than silently dropping the rendition.
- A glyph wider than its cell is scaled to fit instead of painting into
  the neighbouring column, and a scalar no font in the cascade covers
  draws a hollow box instead of nothing — output that looked lost.
- One "Settings…" entry in the menu bar instead of two; the theme and
  appearance lists moved to View. The settings page is grouped into
  labelled sections with explanations, and its window resizes and
  scrolls rather than truncating long font names at a fixed 460 points.
- The File and View menus no longer carry inert document and toolbar
  items. They did nothing in a terminal, and Page Setup's ⇧⌘P and Show
  Toolbar's ⌘T silently shadowed real commands.
- A flag emoji is one grapheme cluster again. A pair of regional indicators
  (`🇯🇵` = U+1F1EF U+1F1F5) was stored as two independent wide cells and
  occupied four columns instead of two, so every character after it on the
  line landed two columns late — visible as a broken box-drawn table.
  UAX #29 GB12/GB13.
- Switching the theme, or the appearance between light and dark, no longer
  leaves the terminal apparently blank. Cell colours are resolved into the
  instance buffer when a row is built, but only the clear colour was read
  fresh each frame: forcing a redraw without forcing a rebuild painted the
  new background behind the previous theme's glyph colours.
- No `fatalError` or `try!` on a pane's startup path. Metal absence, an
  atlas that fails to build, a `$SHELL` pointing at an uninstalled shell
  and a restored working directory on an unmounted volume all used to
  crash the app; the recoverable ones now degrade and the rest present a
  failure view with Try Again.
- A failed config write no longer reports success. The settings page now
  rolls the value back, shows the reason, and offers Retry — and "Show
  Config File" no longer reveals a location it failed to write.
- Notification permission is read, not assumed. The switch used to show
  "on" over a denied permission; it now says macOS is not delivering and
  links to System Settings.
- Window restore lands on a display that still exists, and the first
  restored window is a fresh window rather than the storyboard's — whose
  root pane had already spawned a shell in the home directory, which is
  the one thing a restore cannot repair after the fact.
- A `less` search match's reverse-video highlight renders. Reversing a
  cell whose colours were both `.default` — the common case for a plain
  highlight — re-resolved back to the same default colours regardless of
  the swap, so the highlight was computed but never visible.
- OSC 10/11/12 (background/foreground colour queries) answer with the
  live theme instead of a hardcoded dark palette, which had a program
  that queries its background before choosing its own colours (Claude
  Code among them) painting near-white text over a near-white
  background under the light theme.
- The focus ring no longer draws partly under the tab bar on a top
  pane, and no longer shows a false curve at a divider junction on an
  interior or edge pane — both now share the same chrome-overlap
  geometry the grid's own inset already used.
- A settings row whose label wrapped to two lines no longer silently
  loses the second line, and the notification-permission row no longer
  sits visible-but-empty the first time General is opened.
- A crash loading a cached render pipeline traced to the test target's
  own launch path (`CortaTests` `TEST_HOST`-launches directly into
  `Corta`, a more restrictive launch than opening the app) rather than
  real use; the cache now loads back on every real launch and only
  skips the one launch path that crashed.
- Switching settings tabs no longer tears the whole pane subtree down
  and rebuilds it on every click. Xcode's Thread Performance Checker
  flagged the remove-everything loop as a hang risk (the main thread
  waiting on a lower-QoS thread); panes are built once and now stay
  attached, shown and hidden instead of detached and reattached.

### Known gaps

- Core feed throughput is **130.0 MiB/s** (five-run mean), above the
  100 MB/s target; parser-only and parser+grid are measured separately.
- `esctest` xterm conformance is **77.6%** — 127 of 568 tests failing.
- Typometer measures keypress-to-pixel latency at **45.5 ms average**
  (24.8 ms minimum, 56.4 ms maximum, 6.8 ms standard deviation), above the
  one-frame-plus-input target; the in-process path to the grid is 0.005 ms.
  Measured alongside iTerm2 (42.7 ms) and Ghostty (31.9 ms) on the same
  machine, Corta is currently the slowest of the three
  (`docs/PERFORMANCE.md` §5.5); Terminal.app could not be measured with
  the tool used.
- Frame CPU is **1.879 ms average** / 2.659 ms p95 for a full 120x40
  rebuild, inside the 4 ms budget.
- OSC 133 marks only appear if the user's shell emits them; Corta ships no
  shell snippets yet.
- `maximumDrawableCount = 2` measured within noise of the default —
  70.1 ms vs. 70.4 ms average across a real Typometer A/B, so the
  default (3) ships (`docs/PERFORMANCE.md` §5.4). A 12-second real-typing
  `os_signpost` trace found no `output` → `frame` gap exceeding one
  frame period — no evidence, in that sample, of a redraw missing its
  display frame (§5.3). Neither of those two numbers is a controlled
  before/after against the 45.5 ms figure above: `docs/PERFORMANCE.md`
  §5.2's fixed-environment table (in particular, other background load
  on the machine) wasn't held for either run. The render-pipeline
  rewrite (M9) landed and is covered by its own unit tests, but a
  same-conditions Typometer re-measurement against the 45.5 ms baseline
  is still open.

---

## Release checklist

For the maintainer, cutting any release:

1. Move the relevant `[Unreleased]` entries under a new `## [x.y.z]`
   heading with the date, and leave `[Unreleased]` empty above it.
2. Update the three hand-written version numbers, in
   `Corta.xcodeproj/project.pbxproj` (all six build configurations) and
   the core. **Two of them carry the release's semantic version and must
   read exactly the same; the third is a build counter and only has to go
   up:**
   - `MARKETING_VERSION` — the semantic version, e.g. `0.1.1`. What the
     bundle and the About panel show.
   - `CortaVersion.string` in `CortaTerminal/Sources/CortaTerminal/Version.swift`
     — the same string again, and what XTVERSION answers a program with.
   - **`CURRENT_PROJECT_VERSION`** — *not* the semantic version. A plain
     integer that increments once per release (0.1.0 shipped 1, 0.1.1
     ships 2), and the one Sparkle actually compares. Two releases sharing a build number means
     the second is invisible to everyone running the first, and
     `generate_appcast` overwrites the earlier feed entry rather than
     adding one. 0.1.1 hit this: it was built, signed, notarised and
     published carrying build 1, exactly like 0.1.0, and the mistake only
     surfaced at step 5 when the feed came out with one item in it.
   `VersionAgreementTests` fails if the marketing version and the core
   constant disagree, or if the build number is one a 0.1.0 install could
   not be offered.
3. Re-record the tracking table in `docs/ROADMAP.md` if any number moved.
4. Commit as `chore: release x.y.z`, then tag `vx.y.z` and push the tag.
   The release workflow builds from the tag and opens a **draft** release
   for review — it is never published automatically.
5. Once the draft's archive is reviewed, run `scripts/release.sh` against
   the downloaded archive to sign it into `appcast.xml`, then commit and
   push that file — that is what makes the update visible to every
   already-installed Corta.

[Unreleased]: https://github.com/noah-qin/Corta/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/noah-qin/Corta/releases/tag/v0.1.1
[0.1.0]: https://github.com/noah-qin/Corta/releases/tag/v0.1.0
