<div align="center">

<img src="docs/brand/corta-pangolin-mascot.png" width="160" alt="Corta's pangolin mascot, curled into a C with a cyan cursor on its tail">

# Corta

**A fast, focused terminal. Made for Mac. Built in Swift.**

Metal 4 rendering · Native CJK / IME · SSH, SFTP and remote editing

> For people who live in the terminal: crisp text, native input, powerful remote workflows, and a Swift terminal core with **zero** third-party dependencies. Fast enough for demanding output. Thoughtful enough for everyday work.

[![CI](https://github.com/noah-qin/Corta/actions/workflows/ci.yml/badge.svg)](https://github.com/noah-qin/Corta/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/noah-qin/Corta?style=flat-square)](https://github.com/noah-qin/Corta/releases/latest)
![Platform](https://img.shields.io/badge/macOS_26.0%2B-Apple_silicon-4d4d4d?style=flat-square)
![Swift](https://img.shields.io/badge/Swift-6-f05138?style=flat-square)
[![License](https://img.shields.io/badge/license-Apache--2.0-2f81f7?style=flat-square)](LICENSE)

**[↓ Download](https://github.com/noah-qin/Corta/releases/latest)** ·
**[User guide](docs/USER-GUIDE.md)** ·
[Documentation](docs/README.md) ·
[Contribute](CONTRIBUTING.md) ·
[Report a bug](https://github.com/noah-qin/Corta/issues/new?template=bug_report.yml)

<img src="docs/brand/screenshot.png" width="960" alt="Corta with three split panes: a git log and a Chinese, Japanese, Korean and emoji alignment table; the pangolin mascot shown as an image in the terminal; and 24-bit colour ramps">

</div>

## Install

Requires **macOS 26.0 or later**, **Apple silicon** (M1 or later), and a
**Metal 4-capable GPU**. Virtual machines with a paravirtual GPU are not
supported. Intel Macs can use the older
[1.0.1 release](https://github.com/noah-qin/Corta/releases/tag/v1.0.1).

Download the `.dmg` and matching `.dmg.sha256` file from
[GitHub Releases](https://github.com/noah-qin/Corta/releases/latest).
Keep both files in the same folder and verify the checksum there:

```sh
# Replace x.y.z with the version you downloaded.
shasum -a 256 -c Corta-x.y.z.dmg.sha256
```

Open the disk image, drag **Corta** into **Applications**, then eject the
image. Releases are Developer ID-signed and notarised. For later updates,
use **Corta ▸ Check for Updates…** or download a newer release.
Installation help and uninstall instructions are in
[Troubleshooting](docs/TROUBLESHOOTING.md).

## First steps

| To… | Use |
| :--- | :--- |
| Split right / down | ⌘D / ⇧⌘D |
| Search terminal output | ⌘F |
| Open the command palette | ⇧⌘P |
| Open Settings | ⌘, |

Standard local zsh sessions load the bundled shell-integration hooks
automatically with Directory suggestions enabled (the default). For
startup-file installation in zsh, bash or fish, use
**Settings ▸ Terminal ▸ Shell Integration**; this edits your shell's startup
files only when you choose Install. If an installed integration is outdated,
choose Update and open a new shell. See the
[shell-integration guide](docs/USER-GUIDE.md#shell-integration) for details.

## Built for speed

Corta 1.2 made a big leap in speed and efficiency: more than double the
core throughput, a frame less of full-screen input latency, and a fraction
of the memory for long histories. Measured on one Apple M5 MacBook Air,
before and after, with the same toolchain:

- **2.3× the core throughput.** The parser and grid take **356 MiB/s**,
  up from 158; the terminal core with scrollback takes **317 MiB/s**, up
  from 137. These feed benchmarks exclude PTY I/O, rendering and display.
- **A frame less while you type in full screen.** With a full-screen
  window and exactly one pane, frames can be presented directly to the
  display. On the measured 60 Hz panel, median keypress-to-glass latency
  drops from 64–68 ms to **49–51 ms**, and p99 drops from 154–180 ms to
  **83–84 ms**. Windowed and split panes keep the regular presentation path.
- **Long histories. Small footprint.** A one-line region
  scroll takes **5×** less CPU per frame; output arriving while you read
  history takes **10×** less. Compressing cold history reduces the measured
  memory increment for 100,000 lines of 120 columns from 185 to **11 MiB**.
- **Responsive input and quieter idle sessions.** Typing, paste and input
  methods request the panel's maximum frame rate — 120 Hz on ProMotion.
  An idle blinking cursor is animated by the system, and an idle shell no
  longer wakes its reader four times a second.

Every figure is in [Performance](docs/PERFORMANCE.md), with its method and
what it does not show. The [changelog](CHANGELOG.md) has the full list.

## Made for macOS

Corta puts serious terminal engineering behind a familiar Mac experience:
a hand-written Swift VT engine, Metal 4 rendering, Core Text shaping and
native AppKit input. Split your workspace, search long histories, compose
Chinese, Japanese or Korean text, and edit remote files from the same app.
The terminal core is a separate Swift package with no third-party
dependencies. The app uses [Sparkle](https://sparkle-project.org) for updates.

| Native interaction | Terminal fundamentals | Everyday workflow |
| :--- | :--- | :--- |
| CJK input and IME composition | True colour and Unicode text | Split panes and restored layouts |
| Core Text font fallback | Reflow and scrollback search | Command palette and custom shortcuts |
| Quick Terminal and Shortcuts | Bracketed paste and OSC 8 links | Shell integration and command history |
| Secure Keyboard Entry | Kitty keyboard and direct graphics protocols | OpenSSH, SFTP and remote editing |
| A System Settings–style Settings window | Kitty images in the scrollback | A Finder-like SFTP browser with drag and drop |

Restoration keeps layouts and directory metadata, starts fresh processes,
and does not restore terminal text.

The table describes `main`; published releases may not include every feature.
The [feature reference](docs/FEATURES.md) has the details, requirements and
limitations, and the [design decisions](docs/DECISIONS.md) explain what
Corta deliberately leaves out.

## How is Corta different?

All three offer native macOS interfaces and GPU rendering. Corta combines
a Swift terminal core, one shared configuration for text and GUI editing,
and an integrated SSH, SFTP and remote-editing workflow. Here is how their
implementation and integration choices compare.

| | Corta | iTerm2 | Ghostty |
| :--- | :--- | :--- | :--- |
| Main implementation | Swift | Objective-C and Swift | Zig core; Swift on macOS, GTK on Linux |
| App platforms | macOS | macOS | macOS and Linux |
| Native UI | AppKit, with SwiftUI settings | Native macOS app | SwiftUI on macOS; GTK on Linux |
| Rendering | Metal 4, with Core Text shaping and font fallback | Metal GPU renderer, configurable | Metal on macOS; OpenGL on Linux |
| Settings | One text file, also edited by the native Settings window | Settings UI and profiles; dynamic profiles | Text configuration, with support for multiple files |
| Integration examples | Shortcuts, OpenSSH, SFTP browser and managed remote editing | tmux control-mode integration, Python API and triggers | macOS Shortcuts and AppleScript; embeddable `libghostty` libraries |

Competitor information checked on **2026-10-13** against the official
[iTerm2 repository](https://github.com/gnachman/iTerm2),
[settings documentation](https://iterm2.com/documentation-preferences-general.html),
[dynamic profiles](https://iterm2.com/documentation-dynamic-profiles.html),
[tmux integration](https://iterm2.com/documentation-tmux-integration.html),
[Python API](https://iterm2.com/python-api/) and
[features](https://iterm2.com/features.html), and the official
[Ghostty repository](https://github.com/ghostty-org/ghostty),
[features](https://ghostty.org/docs/features),
[configuration](https://ghostty.org/docs/config) and
[AppleScript guide](https://ghostty.org/docs/features/applescript).

**Why pick Corta.**

- **A Mac workspace built around your hands.** Compose CJK text through
  native IME input, summon the Quick Terminal, move between split panes,
  and find commands from the palette. AppKit powers input, VoiceOver,
  Secure Keyboard Entry and Services; App Intents connects your workspace
  to Shortcuts.
- **Small core, serious safeguards.** An independent Swift terminal core
  has zero third-party dependencies and resource limits for untrusted
  terminal output. Inline image decoding runs in a sandboxed helper;
  clipboard-read and window-title queries are deliberately absent. The
  [security model](docs/SECURITY.md) documents the trust boundaries.
- **Point-and-click comfort. Text-file control.** Change themes and
  shortcuts in the native Settings window or edit `~/.config/corta/config`
  directly: both use the same settings store. Presets load from it too,
  and automated checks keep documented keys and shortcut defaults aligned
  with the code. See the [configuration reference](docs/CONFIGURATION.md).
- **From SSH to a local editor, in one workflow.** Connect with system
  OpenSSH using recent hosts or your `~/.ssh/config` aliases. Browse remote
  files with breadcrumbs, sortable columns and drag and drop; track
  transfers with speed and time remaining. Open a remote file in your local
  editor, then approve its upload with a check for remote conflicts first.
- **Performance you can inspect.** More than double the measured core
  throughput, about 94% less memory for the measured 100,000-line history,
  and lower full-screen input latency. The [evidence below](#quality-with-evidence)
  publishes hardware, methods and results alongside the remaining gaps,
  including windowed latency and incomplete VT conformance.

For native `tmux -CC` integration or a Python scripting API, consider
[iTerm2](https://iterm2.com/documentation-tmux-integration.html). For a
terminal app that also runs on Linux, consider
[Ghostty](https://ghostty.org/docs/features); its macOS app also offers
[AppleScript automation](https://ghostty.org/docs/features/applescript)
from 1.3.0. Corta's macOS-only scope and exclusion of tmux control mode,
built-in AI and a scripting engine are
[settled decisions](docs/DECISIONS.md). Ordinary tmux sessions run inside
Corta as terminal programs.

## Make it yours

Settings are stored in `~/.config/corta/config`. The native Settings window
and the text file edit the same configuration.

```ini
theme = midnight
theme.midnight.inherit = solarized
theme.midnight.dark.background = #101018

bind.equalize-panes = ctrl+cmd+e
bind.command-palette = cmd+shift+p
```

**View ▸ Theme editor…** opens
color pickers and separate light/dark previews. **Settings ▸ Appearance ▸
Cursor** selects block, bar or underline and an independent blink switch; the
default is a nonblinking block. System Monospaced is the only supported
primary font, with adjustable size and system fallback for missing characters.
**Settings ▸ Terminal ▸ Bottom status bar** enables selectable local metrics
(default off); click it for host details, or use **View ▸ Local host details…**.
See the [personalization tutorial](docs/USER-GUIDE.md#personalizing-the-terminal)
for the steps, network-interface selection and thermal-state limitations.

The [configuration reference](docs/CONFIGURATION.md) lists every key, default
and when changes take effect. The [user guide](docs/USER-GUIDE.md) walks
through every feature and where to find it.

## Build and test

Use macOS 26.0 or later on Apple silicon and Xcode with Swift 6.2 or later. The exact
Xcode CI and releases build with is in [`.xcode-version`](.xcode-version). The app resolves
Sparkle on its first build; the terminal core has no external packages.

```sh
git clone https://github.com/noah-qin/Corta.git
cd Corta

# Build and test the terminal core without launching the app.
swift test --package-path CortaTerminal

# Build the macOS app.
xcodebuild -project Corta.xcodeproj -scheme Corta build

# Or build the development app — a separate application, with its own
# configuration and state, that runs beside an installed Corta.
xcodebuild -project Corta.xcodeproj -scheme 'Corta (Dev)' build
```

Start with the [contributor guide](CONTRIBUTING.md) for local signing and
repository orientation, and the [testing guide](docs/TESTING.md) for app
tests, golden fixtures, fuzzing and manual verification.

## Quality, with evidence

Corta is under active development and has known issues. These measurements
are snapshots, not guarantees for every machine or workload.

| Check | Recorded result | Evidence |
| :--- | :--- | :--- |
| Core feed throughput | **317.3 MiB/s** (137.2 before 1.2) | [Performance §5.14](docs/PERFORMANCE.md#514-scrolling-without-per-line-screen-allocation-281-283) |
| Parser + grid throughput | **355.9 MiB/s** (158.0 before 1.2) | same |
| Scrollback memory, 100k × 120 lines | **11.4 MiB** (185 MiB before 1.2) | [Performance §5.6](docs/PERFORMANCE.md#56-numbers-by-release) |
| Region scroll, CPU a frame, p50 | **0.026 ms** (0.130 ms before 1.2) | [Performance §5.14](docs/PERFORMANCE.md#514-scrolling-without-per-line-screen-allocation-281-283) |
| Frame CPU, 120 × 40 full rebuild, Release | **0.37–0.39 ms** | [Performance §5.17](docs/PERFORMANCE.md#517-full-screen-without-the-compositor-285-2026-10-13) |
| Keypress to glass, full screen, one pane, 60 Hz, a person typing | **49.1–50.8 ms** p50, 82.9–84.2 ms p99 | [Performance §5.17](docs/PERFORMANCE.md#517-full-screen-without-the-compositor-285-2026-10-13) |
| Idle CPU, Release, 20 seconds | 0.05% | [Performance](docs/PERFORMANCE.md) |
| esctest2 | 131 passed, 334 known bugs, 102 failed; 567 total | [Raw results](https://github.com/noah-qin/Corta/blob/f632d5918653cc2feee28fe1baa0c0fd01e93c0e/docs/esctest/2026-10-07-results.txt) |

Measured on an Apple M5 MacBook Air (macOS 27.0.1) between 2026-10-09 and
2026-10-13, each before/after pair on the same machine and toolchain; the
dated sections of [Performance](docs/PERFORMANCE.md) hold the conditions, every run and
what a figure does not establish. Idle CPU is the 1.0.0 run's (2026-09-18),
and esctest2 1.1.5's; its 82.0% figure counts passes **plus known bugs** and
is not a pass rate. See [conformance](docs/CONFORMANCE.md) for interpretation.

Known limitations include keypress-to-glass latency above the one-frame
target in a window (full screen with one pane comes closest), incomplete VT
conformance, bundled shell integration for zsh, bash and fish only, and
direct-transmission-only Kitty graphics. The
[limitations reference](docs/FEATURES.md#known-limits) has the details.

## Find your way around

| I want to… | Start here |
| :--- | :--- |
| Learn every feature and where it lives | [User guide](docs/USER-GUIDE.md) |
| Configure Corta | [Configuration](docs/CONFIGURATION.md) |
| Understand a feature or limitation | [Features](docs/FEATURES.md) |
| Diagnose a problem | [Troubleshooting](docs/TROUBLESHOOTING.md) |
| See what is planned, or suggest something | [Milestones](https://github.com/noah-qin/Corta/milestones) · [Discussions → Ideas](https://github.com/noah-qin/Corta/discussions/categories/ideas) |
| Make a first contribution | [Contributing](CONTRIBUTING.md) |
| Run or add tests | [Testing](docs/TESTING.md) |
| Understand the code | [Architecture](docs/DESIGN.md) · [Core API](CortaTerminal/Sources/CortaTerminal/CortaTerminal.docc/CortaTerminal.md) |
| Read the full documentation | [Documentation index](docs/README.md) |

## Contribute

Bug reproductions, documentation, translations, accessibility testing and
code contributions are welcome. Pick a focused change and read
[CONTRIBUTING.md](CONTRIBUTING.md) for setup and review expectations.
Community participation follows the [Code of Conduct](CODE_OF_CONDUCT.md).

Report vulnerabilities through the [private security channel](SECURITY.md).
For usage questions, go to [Discussions → Q&A](https://github.com/noah-qin/Corta/discussions/categories/q-a).
For other problems, [open an issue](https://github.com/noah-qin/Corta/issues/new/choose).
If you would like to support maintenance, [sponsor the project](https://github.com/sponsors/noah-qin).

## License and identity

Source code is licensed under [Apache 2.0](LICENSE). The Corta name,
pangolin mascot and app icon have separate terms in [NOTICE](NOTICE).
The pangolin's curled body forms a C; its cyan tail is a terminal cursor.
[Brand assets](docs/brand/README.md) include the mascot and social preview.
