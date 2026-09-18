<div align="center">

<img src="docs/brand/corta-pangolin-mascot.png" width="200" alt="The Corta pangolin mascot, curled into a C with a cyan cursor at the tip of its tail">

# Corta

**An uncompromisingly native macOS terminal emulator.**

Built from scratch in pure Swift — a hand-written VT engine, Metal rendering,<br>
first-class CJK input, and a terminal core with zero third-party dependencies.

<br>

[![License](https://img.shields.io/badge/license-Apache--2.0-2f81f7?style=flat-square)](LICENSE)
![Platform](https://img.shields.io/badge/macOS-26.0%2B-4d4d4d?style=flat-square)
![Swift](https://img.shields.io/badge/Swift-6-f05138?style=flat-square)
![Core dependencies](https://img.shields.io/badge/core%20dependencies-0-00c2c7?style=flat-square)
[![Release](https://img.shields.io/github/v/release/noah-qin/Corta?style=flat-square&label=release)](https://github.com/noah-qin/Corta/releases/latest)
[![Contributors](https://img.shields.io/github/contributors/noah-qin/Corta?style=flat-square)](https://github.com/noah-qin/Corta/graphs/contributors)
[![Sponsors](https://img.shields.io/github/sponsors/noah-qin?style=flat-square)](https://github.com/sponsors/noah-qin)

[**Download Corta 1.0.0**](https://github.com/noah-qin/Corta/releases/latest) ·
[Roadmap](https://github.com/noah-qin/Corta/milestone/1) ·
[Report a bug](https://github.com/noah-qin/Corta/issues/new?template=bug_report.yml)

<br>

*Small but resilient. Close to the system. Every character in its place.*

</div>

<div align="center">
  <img src="docs/brand/screenshot.png" width="860" alt="A Corta window: a coloured git log graph, a column ruler showing CJK, kana, combining marks and emoji each landing on the column they claim, and 16-colour, 256-colour and true-colour ramps">
</div>

---

## Why

<table>
<tr>
<td width="33%" valign="top">

### One platform

Metal for rendering, Core Text for shaping, AppKit for input. Used directly,
with no portability layer in between. Corta is made for macOS, so it can feel
at home there.

</td>
<td width="33%" valign="top">

### One language

The VT parser is written in Swift in this repository, not bound from C. No FFI, no bridging header — the terminal core (`CortaTerminal`) has zero dependencies and is readable end to end. The app shell has exactly one: [Sparkle](https://sparkle-project.org), for updates.

</td>
<td width="33%" valign="top">

### One job

Render a PTY correctly and quickly. No multiplexer, no cloud sync, no AI. Anything the operating system or `tmux` already does well, Corta does not reimplement.

</td>
</tr>
</table>

Every trade-off follows from those three lines. The decisions are written
down in [`docs/DESIGN.md`](docs/DESIGN.md) — including, at equal length, the
things Corta deliberately does **not** do.

## Status

**Version 1.0.0.** Corta renders `vim`, `tmux` and `htop` correctly and
is used daily by its author. Between 0.1.1 and 1.0.0 the sixteen ordered
roadmap batches (`B01`–`B16`) landed:
keyboard, IME and focus routing; explicit session lifecycle and input
backpressure; anchored scrollback and selection; responsive search and
export; terminal-conformance gaps; shell integration and command-level
navigation; smart directory navigation; unified configuration, fonts, zoom
and restoration; native UI and accessibility; CPU, locking and memory
work; a real Metal 4 backend; OpenSSH configuration and remote context;
SFTP and remote editing; the documentation and packaging you are reading;
and system entry points — App Intents, a Quick Terminal and Secure
Keyboard Entry. [`CHANGELOG.md`](CHANGELOG.md) has each one in detail.

Conformance, measured against esctest2 on 2026-09-17: 126 passed, 334
known bugs, 107 failed of 567 — 81.1% xterm-compatibility, up from 78.7%
at 0.1.1 with no test regressed. The classification of what still fails
is in [`docs/history/V0.1.1-QUALITY-PLAN.md`](docs/history/V0.1.1-QUALITY-PLAN.md);
the failing test names are in
[`docs/esctest/2026-09-17-results.txt`](docs/esctest/2026-09-17-results.txt).

Measured for 1.0.0 on 2026-09-18 (Apple M5, macOS 27.0, on battery —
the one deviation from the fixed environment, stated in
[`docs/PERFORMANCE.md`](docs/PERFORMANCE.md) §5.6 with every other row):

| Metric | Target | Measured | |
| :--- | :--- | :--- | :--- |
| Frame CPU (120×40 full rebuild, Debug) | < 4 ms | **2.26 ms** (3-run mean) | ✅ |
| Idle CPU (Release, 20 s) | ~0% | **0.05%** | ✅ |
| Memory, 100k × 120 lines | ~200 MB | **185.0 MB** | ✅ |
| Core feed throughput | > 100 MB/s | **144.2 MiB/s** (5-run mean) | ✓ |
| Keypress → glass | < 1 frame + input | **66.3 ms avg**, p95 78.7 (200 samples, a person typing, measured in-app at the glass); 61.9 avg scripted | ⚠️ above target |
| `esctest` xterm conformance | — | **81.1%** — 107 of 567 failing | |

The number that misses its target is printed here rather than omitted.
Numbers that have not been measured are left blank rather than estimated.

## Features

**The engine**
- A hand-written VT parser: VT100/VT220 through `xterm-256color`, true colour,
  and query responses — DA, DSR, DECRQM — gated on the conformance level the
  program announced.
- Lines carry a `wrapped` flag from the first commit, so reflow, selection
  and search all agree about where a logical line begins and ends.
- Cells are 16 bytes; complex graphemes spill to an interned side table.

**The rendering**
- A GPU glyph atlas and instanced quads: one draw call per screen, a
  triple-buffered instance buffer, and damage tracked per line.
- Nothing is redrawn when nothing changed — idle CPU is 0.0%, not "low".

**The text**
- Full `NSTextInputClient` IME: composition, a candidate window that lands
  under the cursor in any split, and preedit drawn as an overlay that never
  touches the grid.
- Correct East Asian widths, combining marks and emoji presentation, with
  Core Text font fallback.

**The window**
- Splits, search across the scrollback, incremental reflow on resize,
  document-anchored selection that follows its text as output scrolls.
- OSC 8 hyperlinks, bracketed paste, the kitty keyboard protocol, focus
  reporting, pinch-to-zoom, file drops, colour themes.
- Windows, splits and per-pane working directories are restored at launch,
  and closing something that still has a job running asks first.
- A command palette (⇧⌘P) over every command, which is also the list the
  menus and the keybindings are generated from.
- Zoom Pane (⇧⌘⏎) to fill the window with one pane and put the split
  back; Reopen Closed Pane (⇧⌘T), which restores the arrangement and
  never claims to restore the process; Export Text… (⇧⌘S).
- Clear Screen (⌘K), Clear History and Reset Terminal as three separate
  commands, with a table saying what each one discards.
- Search with a Match Case toggle and an optional regular-expression
  mode, budgeted so a pattern that would never finish is refused rather
  than run; and a pill saying how far back a scrolled viewport is.
- Check for Updates… over a signed feed (Sparkle) — a manual check, or a
  daily background one you can turn off in `~/.config/corta/config`.

**The shell**
- OSC 133 shell integration: a status mark beside each prompt showing
  which commands failed, ⌘↑/⌘↓ to jump between them, ⇧⌘↑/⇧⌘↓ to jump
  between the *failed* ones, Copy Last Command Output, Export Command
  Output, a searchable command history, and a long-task notification that
  fires on the real boundary rather than a guess. Settings ▸ Terminal
  installs the zsh hooks into one marked block of `~/.zshrc`, and removes
  exactly that block.
- Directory navigation from the pane's own reported directory: reveal or
  copy it, change to the parent or the project root, open either in a new
  pane, and a switcher ranked by where you have actually been.
- Named shell, directory and environment presets under Shell ▸ New Pane
  with Preset; hold ⌥ to open one in its own window.
- ⌘-click a `path:line:column` reference in program output to open the
  file, optionally through your own `open-file-command`. Local only: a
  path reported by a remote host over OSC 7 is never opened.
- OSC 52 clipboard *write* — how `tmux` and a remote `ssh` reach this
  Mac's clipboard. Off by default; the read direction does not exist.

**Remote**
- A pane that is `ssh`'d somewhere knows it — and says so, with a host
  badge in the title, a host filter in the command history, and Shell ▸
  Reconnect to Host when the connection dies. A remote path never reaches
  a local spawn. Corta adds no SSH library and parses no SSH config: the
  child is the system's own OpenSSH, so `~/.ssh/config`, agent keys and
  `ProxyJump` all apply untouched.
- Shell ▸ Browse Remote Files… opens an SFTP browser for that host over
  `ssh -s sftp`: list, rename, delete, upload and download files and
  folders, and open a remote file in your editor with the copy written
  back on save. The first connection to a host in a run asks first, with
  the name shown and editable — a remote's own report never connects on
  its say-so.

**The system**
- Three Shortcuts actions — *Open Corta Window* (optionally in a folder),
  *Focus Corta Window* and *Toggle Quick Terminal* — usable from the
  Shortcuts app and, through a Shortcut built there, `shortcuts run`. Windows are addressed by a
  stable identity, never by title, and no action carries text toward a
  shell ([`docs/SECURITY.md`](docs/SECURITY.md) §4.6).
- A Quick Terminal: one terminal summoned over any application by a
  system-wide hotkey, on every Space and beside full-screen apps, that
  hands focus back where it came from. Off by default — `quick-terminal =
  true` claims the key; View ▸ Quick Terminal opens it regardless.
- Secure Keyboard Entry under Shell, with a titlebar lock that shows when
  it is actually engaged.
- Kitty graphics: direct (in-band) transmission in RGB, RGBA and PNG,
  verified against `kitten icat`. File-based transmission is deliberately
  not implemented.
- Check for Updates… over a signed feed (Sparkle) — a manual check, or a
  daily background one you can turn off in `~/.config/corta/config`.

**The configuration**
- One text file at `~/.config/corta/config`. The native settings page is a
  front over that file, which stays the single source of truth — hand-edit
  it and the page follows.
- Colour themes and keyboard shortcuts are defined there too:

  ```
  theme = midnight
  theme.midnight.inherit = solarized
  theme.midnight.dark.background = #101018

  bind.split-right = ctrl+s
  bind.command-palette = cmd+shift+p
  bind.close =              # an empty value unbinds
  ```

- Every key, its values, its default and when it takes effect:
  [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md).

<details>
<summary><strong>What Corta deliberately does not do</strong></summary>

<br>

A built-in multiplexer, cross-platform support, tmux control mode, AI
features, automation that *runs commands*, RTL text, and terminal title
*query* responses — the last being a command injection vector,
[`docs/SECURITY.md`](docs/SECURITY.md) §2.2. Compatibility with AI
command-line tools is part of terminal correctness, not a feature.

Each was considered and rejected for a stated reason in
[`docs/DESIGN.md`](docs/DESIGN.md) §6 and
[`docs/DECISIONS.md`](docs/DECISIONS.md). Please read them before opening
a feature request for one of them.

</details>

## Known limits

- **`TERM` is `xterm-256color`**, deliberately, and 107 of esctest's 567
  cases still fail — the list is in
  [`docs/esctest/2026-09-17-results.txt`](docs/esctest/2026-09-17-results.txt). A
  program that misbehaves in Corta and not in xterm is a bug to report.
- **Shell integration ships for zsh only.** Fish and bash users keep the
  keystroke-and-idle heuristic for the long-task notification and get no
  prompt marks.
- **Keypress-to-glass latency is above its target** (about 60 ms against
  a one-frame-plus-input goal, three frames on a 60 Hz panel); the table
  above says so rather than hiding it, and Corta now measures it from
  the inside (`docs/PERFORMANCE.md` §5.7) so a change that moves it is
  a number, not a feeling.
- **Kitty graphics** implement direct transmission only: no file-based
  transmission (by design), no animation frames, no Unicode-placeholder
  placement.
- **The Quick Terminal's hotkey is matched by key position** on the ANSI
  layout, the way every Carbon hotkey is; `quick-terminal-key = alt+t`
  names the key cap, not what your input source types there.
- **Remote editing** is over `sftp` with a managed local copy; there is no
  in-terminal editor and no sync of anything you did not open.
- **Two reports from the 1.0.0 test pass are open, not blocking:** one
  tester's ⌘, did not open Settings (not reproduced; the menu item
  works), and VoiceOver was once heard reading state the screen had
  moved past (one cause fixed, not re-listened). Both are in
  [`docs/CONFORMANCE.md`](docs/CONFORMANCE.md) and the
  [`CHANGELOG`](CHANGELOG.md) rather than hidden.

## Install

Corta 1.0.0 requires **macOS 26.0 or later**. Download the signed and
notarised `Corta-1.0.0.zip` and its SHA-256 file from the
[latest GitHub release](https://github.com/noah-qin/Corta/releases/latest),
check the archive, unzip it, and move `Corta.app` to `/Applications`:

```sh
shasum -a 256 -c Corta-1.0.0.zip.sha256
unzip Corta-1.0.0.zip && mv Corta.app /Applications/
```

Every release archive is checked before it is published — versions, build
number, deployment target, Developer ID signature, notarization ticket,
archive and checksum, by the same script locally and on CI
(`scripts/check-release.sh`). If Gatekeeper refuses a release download,
[`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) says what to check.

### Upgrade

**Corta ▸ Check for Updates…** offers the next release over a signed
Sparkle feed, or download the new archive and replace `Corta.app`. Your
config file and window arrangement are untouched either way; a config
written by a newer Corta survives a round trip through an older one
(unknown keys are preserved, not dropped).

### Uninstall

```sh
# The app
rm -rf /Applications/Corta.app
# Settings, and app-owned state (window arrangement, directory history)
rm -rf ~/.config/corta ~/Library/Application\ Support/Corta
```

If you installed shell integration from Settings ▸ Terminal, remove it
there first, or delete the block between `# >>> Corta shell integration
>>>` and `# <<< Corta shell integration <<<` in `~/.zshrc` — nothing else
in that file is Corta's. Nothing else is written anywhere.

### Build from source

Corta needs **macOS 26.0 or later** and **Xcode 26** (Swift 6). The one
dependency step is Xcode resolving Sparkle over the network on first
build; the terminal core builds and tests with none at all.

```sh
git clone https://github.com/noah-qin/Corta.git
cd Corta
xcodebuild -project Corta.xcodeproj -scheme Corta build
xcodebuild -project Corta.xcodeproj -scheme Corta test
```

The terminal core is a local SwiftPM package that builds, tests and
benchmarks without an app:

```sh
swift test --package-path CortaTerminal
swift build --package-path CortaTerminal -c release

# Parse throughput and scrollback memory
CortaTerminal/.build/release/corta-bench

# Replay the checked-in fuzz corpus, then mutate against it
CortaTerminal/.build/release/corta-fuzz --fuzz 500000 --seed 1 \
  CortaTerminal/Tests/Fuzz/corpus
```

To package a build the way a release is packaged:

```sh
scripts/package-release.sh path/to/Corta.app 1.0.0 dist
```

## Roadmap

The v1.0.0 plan was sixteen ordered GitHub issues, `B01` through `B16`,
under the [v1.0.0 milestone](https://github.com/noah-qin/Corta/milestone/1),
and all sixteen have landed on `main`. Each issue records its scope,
dependencies, acceptance criteria and what was left honestly unverified;
[`CHANGELOG.md`](CHANGELOG.md) has the shipped result of each. What
comes next is opened as issues in the same shape. Built-in AI is not
planned; compatibility with AI command-line tools is part of terminal
correctness.

The M1–M10 record that produced 0.1.0 is kept at
[`docs/history/ROADMAP-0.1.md`](docs/history/ROADMAP-0.1.md).

## Documentation

[`docs/README.md`](docs/README.md) is the index. The documents are the
source of truth for design decisions; this file is a summary.

| Document | Covers |
| :--- | :--- |
| [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md) | Every config-file key: settings, themes, keybindings, presets, and when each applies |
| [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) | Installing, starting, behaviour that differs from other terminals, and uninstalling cleanly |
| [`docs/DECISIONS.md`](docs/DECISIONS.md) | The settled decisions, one record each |
| [`docs/DESIGN.md`](docs/DESIGN.md) | Goals, architecture, modules, non-goals |
| [`docs/CONFORMANCE.md`](docs/CONFORMANCE.md) | Feature priorities, the daily-driver checklist, test strategy |
| [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md) | Targets, hot-path rules, benchmarks |
| [`docs/SECURITY.md`](docs/SECURITY.md) | Threat model, escape-sequence injection, resource caps, trust boundaries |
| [`docs/history/`](docs/history/) | The M1–M10 roadmap and the 0.1.1 audit notes — the record, not the reference |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Commit convention, branches, pull requests |
| [`CHANGELOG.md`](CHANGELOG.md) | What changed, per release |

## Contributing

Issues and pull requests are welcome. Read
[`CONTRIBUTING.md`](CONTRIBUTING.md) first — it covers the commit convention
(Conventional Commits, English) and the working rules. Two of those catch
newcomers out, and both were learned the expensive way:

Pick an issue, say so on it before starting substantial work so parallel
attempts do not collide, and open the pull request against `main` with the
template filled in — it lists the checks a change of each kind needs.
Reproductions, terminal compatibility results, native-language review of
the nine localizations and VoiceOver verification are useful contributions
even without a code change. Install blockers and "I went back to my old
terminal" reports have their own issue templates, because both tell the
project something a stack trace cannot.

> **App-layer changes are verified by launching the app.** Offscreen render
> tests cannot see view-hierarchy, orientation, startup-ordering or gesture
> defects. Six such bugs shipped a blank window while every test stayed
> green.

> **Re-measure the frame-CPU baseline after touching the render loop.** A
> 0.9 ms regression once passed the entire suite. Only the number caught it.

Contributions are accepted under Apache 2.0 §5. There is no separate CLA.

### Contributors

<a href="https://github.com/noah-qin/Corta/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=noah-qin/Corta" alt="Corta contributors" />
</a>

## Support

If Corta is useful to you, [sponsoring](https://github.com/sponsors/noah-qin)
helps keep it maintained.

## Security

Every byte arriving from the PTY is treated as hostile. If you believe you
have found a vulnerability, **do not open a public issue** —
[`SECURITY.md`](SECURITY.md) has the private channel, and
[`docs/SECURITY.md`](docs/SECURITY.md) is the threat model behind it.

## Licence

Source code is under the [Apache License 2.0](LICENSE).

The **Corta** name, the pangolin mascot and the application icon are *not*
covered by that licence and remain the property of the copyright holder —
see [`NOTICE`](NOTICE). Fork the code freely; re-brand your fork.

---

<div align="center">

<img src="docs/brand/corta-pangolin-mascot.png" width="120" alt="">

### The pangolin

</div>

Corta's mascot stands for a simple engineering philosophy: compact, precise,
resilient, and close to the system.

Its curled body naturally forms the letter **C**, while its overlapping
scales resemble the cells of a terminal grid — small, efficient units
working together as a reliable whole. Its armour reflects Corta's focus on
stability and the secure handling of complex input. As a burrowing animal,
it also stands for going beneath the graphical surface, down to the shell,
the processes and the operating system.

The cyan tip of its tail is an active terminal cursor, always ready for the
next command.
