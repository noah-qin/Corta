# Changelog

All notable changes to Corta are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

While the major version is `0`, a minor bump may contain a breaking change
to the config file format; those are always listed under **Changed** with
what to edit.

## [Unreleased]

Nothing yet.

## [0.1.0] - 2026-09-03

The first release. Everything below is what `main` had accumulated
through M1–M7.

### Added

**Terminal engine**
- A hand-written VT parser covering VT100/VT220 through `xterm-256color`,
  with 256-colour and true-colour SGR.
- Query responses — DA1/DA2, DSR, DECRQM, DECRPM — answered in fixed
  format and never echoing stream-supplied bytes. DECSCL gates DECRQM: a
  program that announced VT200 is answered as VT200.
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
  and idle CPU measures 0.0%.
- Cursor styles (block, bar, underline) with blink; bold, italic,
  underline and strikethrough; selection drawn as document-anchored quads
  that follow their text as output scrolls.

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
- A command palette (⇧⌘P) over every command Corta has.
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

**Project**
- Golden-file grid tests, a fuzz harness (`corta-fuzz`) with a checked-in
  corpus, and a parse/memory benchmark (`corta-bench`).
- Apache 2.0 licence, a security policy, a code of conduct and issue and
  pull request templates.

### Fixed

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

### Known gaps

- Core feed throughput is **130.0 MiB/s** (five-run mean), above the
  100 MB/s target; parser-only and parser+grid are measured separately.
- `esctest` xterm conformance is **77.6%** — 127 of 568 tests failing.
- Typometer measures keypress-to-pixel latency at **45.5 ms average**
  (24.8 ms minimum, 56.4 ms maximum, 6.8 ms standard deviation), above the
  one-frame-plus-input target; the in-process path to the grid is 0.005 ms.
- There is no signed or notarised direct-download build yet.
- Frame CPU is **1.879 ms average** / 2.659 ms p95 for a full 120x40
  rebuild, inside the 4 ms budget.
- OSC 133 marks only appear if the user's shell emits them; Corta ships no
  shell snippets yet.

---

## Release checklist

For the maintainer, when the first tag is cut:

1. Move the relevant `[Unreleased]` entries under a new `## [x.y.z]`
   heading with the date, and leave `[Unreleased]` empty above it.
2. Update `MARKETING_VERSION` in `Corta.xcodeproj/project.pbxproj` to
   match.
3. Re-record the tracking table in `docs/ROADMAP.md` if any number moved.
4. Commit as `chore: release x.y.z`, then tag `vx.y.z` and push the tag.
   The release workflow builds from the tag and opens a **draft** release
   for review — it is never published automatically.

[Unreleased]: https://github.com/noah-qin/Corta/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/noah-qin/Corta/releases/tag/v0.1.0
