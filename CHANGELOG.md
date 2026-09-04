# Changelog

All notable changes to Corta are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

While the major version is `0`, a minor bump may contain a breaking change
to the config file format; those are always listed under **Changed** with
what to edit.

## [Unreleased]

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
2. Update `MARKETING_VERSION` in `Corta.xcodeproj/project.pbxproj` to
   match.
3. Re-record the tracking table in `docs/ROADMAP.md` if any number moved.
4. Commit as `chore: release x.y.z`, then tag `vx.y.z` and push the tag.
   The release workflow builds from the tag and opens a **draft** release
   for review — it is never published automatically.
5. Once the draft's archive is reviewed, run `scripts/release.sh` against
   the downloaded archive to sign it into `appcast.xml`, then commit and
   push that file — that is what makes the update visible to every
   already-installed Corta.

[Unreleased]: https://github.com/noah-qin/Corta/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/noah-qin/Corta/releases/tag/v0.1.0
