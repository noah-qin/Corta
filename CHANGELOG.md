# Changelog

All notable changes to Corta are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

While the major version is `0`, a minor bump may contain a breaking change
to the config file format; those are always listed under **Changed** with
what to edit.

## [Unreleased]

Nothing has been released yet. Everything below is on `main` and is
reachable by building from source — see the README.

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
- A long-running-task notification, off by default while it rests on a
  heuristic rather than on shell integration.

**Project**
- Golden-file grid tests, a fuzz harness (`corta-fuzz`) with a checked-in
  corpus, and a parse/memory benchmark (`corta-bench`).
- Apache 2.0 licence, a security policy, a code of conduct and issue and
  pull request templates.

### Fixed

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

- Parser throughput is **75.1 MB/s** against a target of 100 MB/s.
- `esctest` xterm conformance is **73.2%** — 152 of 568 tests failing.
- Keypress-to-pixel latency is measured only as far as the grid
  (0.005 ms); the display half is unmeasured pending Typometer.
- There is no signed or notarised build, and no Homebrew cask.

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

[Unreleased]: https://github.com/noah-qin/Corta/commits/main
