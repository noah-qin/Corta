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
[![Discord](https://img.shields.io/badge/Discord-join-5865f2?style=flat-square&logo=discord&logoColor=white)](https://discord.gg/QNdWfdwr7j)

**[↓ Download](https://github.com/noah-qin/Corta/releases/latest)** ·
**[User guide](docs/USER-GUIDE.md)** ·
[Documentation](docs/README.md) ·
[Contribute](CONTRIBUTING.md) ·
[Discord](https://discord.gg/QNdWfdwr7j) ·
[Report a bug](https://github.com/noah-qin/Corta/issues/new?template=bug_report.yml) ·
[简体中文](README.zh-CN.md)

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

## Why Corta

| | |
| :--- | :--- |
| **Native Mac input** | CJK input and IME composition, Core Text font fallback, VoiceOver, Secure Keyboard Entry, Services, the Quick Terminal and Shortcuts actions — through AppKit, not around it. |
| **Fast, with evidence** | 2.3× the core throughput of 1.1, a frame less of full-screen input latency, and 11 MiB instead of 185 MiB for 100,000 lines of history. Every figure is published with its method and its gaps (below). |
| **Remote work built in** | System OpenSSH with your `~/.ssh/config`, a Finder-like SFTP browser with drag and drop, and remote files opened in your local editor with a conflict check before upload. |
| **One settings file** | The native Settings window and `~/.config/corta/config` edit the same store; automated checks keep the documented keys and shortcuts aligned with the code. |
| **Small core, serious safeguards** | A Swift terminal core with no third-party dependencies, resource limits for untrusted output, and a sandboxed image decoder; the app adds only [Sparkle](https://sparkle-project.org) for updates. Clipboard reads and title queries are deliberately absent ([security model](docs/SECURITY.md)). |

Split panes, scrollback search, true colour, OSC 8 links, the Kitty keyboard
and graphics protocols, shell integration and restored layouts are all
there; the [feature reference](docs/FEATURES.md) lists everything, with
requirements and limitations, and describes `main` — a published release
may not have every item yet. How Corta compares with iTerm2 and Ghostty,
and when to pick one of them instead, is in
[Features → How Corta compares](docs/FEATURES.md#how-corta-compares).
Corta's macOS-only scope and its exclusion of tmux control mode, built-in
AI and a scripting engine are [settled decisions](docs/DECISIONS.md);
ordinary tmux sessions run inside Corta as terminal programs.

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

## Build from source

```sh
git clone https://github.com/noah-qin/Corta.git && cd Corta
swift test --package-path CortaTerminal                     # the terminal core, no app
xcodebuild -project Corta.xcodeproj -scheme 'Corta (Dev)' build  # a development app beside your installed Corta
```

The [contributor guide](CONTRIBUTING.md) has the requirements (macOS 26,
Apple silicon, the Xcode in [`.xcode-version`](.xcode-version)), local
signing and a map of the repository; the [testing guide](docs/TESTING.md)
says which check each change needs.

## Quality, with evidence

Corta is under active development and has known issues. These measurements
are snapshots, not guarantees for every machine or workload. Each row says
which release it was measured on.

| Check | Recorded result | Measured on | Evidence |
| :--- | :--- | :--- | :--- |
| Core feed throughput (parser, grid and scrollback; no PTY or rendering) | **317.3 MiB/s**, up from 137.2 | 1.2 vs 1.1 | [Performance §5.14](docs/PERFORMANCE.md#514-scrolling-without-per-line-screen-allocation-281-283) |
| Parser + grid throughput | **355.9 MiB/s**, up from 158.0 | 1.2 vs 1.1 | same |
| Scrollback memory, 100k × 120 lines | **11.4 MiB**, down from 185 | 1.2 vs 1.1 | [Performance §5.6](docs/PERFORMANCE.md#56-numbers-by-release) |
| Region scroll, CPU a frame, p50 | **0.026 ms**, down from 0.130 | 1.2 vs 1.1 | [Performance §5.14](docs/PERFORMANCE.md#514-scrolling-without-per-line-screen-allocation-281-283) |
| Frame CPU, 120 × 40 full rebuild, Release | **0.37–0.39 ms** | 1.2 | [Performance §5.17](docs/PERFORMANCE.md#517-full-screen-without-the-compositor-285-2026-10-13) |
| Keypress to glass, full screen, one pane, 60 Hz, a person typing | **49.1–50.8 ms** p50, 82.9–84.2 ms p99 (was 64–68 ms p50) | 1.2 | [Performance §5.17](docs/PERFORMANCE.md#517-full-screen-without-the-compositor-285-2026-10-13) |
| Idle CPU, Release, 20 seconds | 0.05% | **1.0.0** (2026-09-18); not re-run since the idle-wakeup work in 1.2 | [Performance](docs/PERFORMANCE.md) |
| esctest2 | 131 passed, 334 known bugs, 102 failed; 567 total | **1.1.5** (2026-10-07) | [Raw results](https://github.com/noah-qin/Corta/blob/f632d5918653cc2feee28fe1baa0c0fd01e93c0e/docs/esctest/2026-10-07-results.txt) |

Measured on an Apple M5 MacBook Air (macOS 27.0.1); the 1.2 rows between
2026-10-09 and 2026-10-13, each before/after pair on the same machine and
toolchain. The dated sections of [Performance](docs/PERFORMANCE.md) hold the
conditions, every run and what a figure does not establish. The esctest2
82.0% figure sometimes quoted counts passes **plus known bugs** and is not a
pass rate; see [conformance](docs/CONFORMANCE.md) for interpretation.

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
| Move over from iTerm2, Ghostty or Terminal.app | [Coming from another terminal](docs/USER-GUIDE.md#coming-from-another-terminal) |
| See what is planned, or suggest something | [Open issues](https://github.com/noah-qin/Corta/issues) · [Discussions → Ideas](https://github.com/noah-qin/Corta/discussions/categories/ideas) |
| Find something to work on | [Good first issues](https://github.com/noah-qin/Corta/labels/good%20first%20issue) · [Help wanted](https://github.com/noah-qin/Corta/labels/help%20wanted) |
| Make a first contribution | [Contributing](CONTRIBUTING.md) |
| Run or add tests | [Testing](docs/TESTING.md) |
| Understand the code | [Architecture](docs/DESIGN.md) · [Core API](CortaTerminal/Sources/CortaTerminal/CortaTerminal.docc/CortaTerminal.md) |
| Read the full documentation | [Documentation index](docs/README.md) |

## Contribute

Bug reproductions, documentation, translations, accessibility testing and
code contributions are welcome. Start from a
[good first issue](https://github.com/noah-qin/Corta/labels/good%20first%20issue)
or a [help wanted](https://github.com/noah-qin/Corta/labels/help%20wanted)
one, and read [CONTRIBUTING.md](CONTRIBUTING.md) for setup and review
expectations. Community participation follows the
[Code of Conduct](CODE_OF_CONDUCT.md).

Tried Corta and went back to your old terminal? That is worth hearing too:
the [Went back form](https://github.com/noah-qin/Corta/issues/new?template=went_back.yml)
needs no reproduction, and "it just felt off" is an acceptable answer.

Report vulnerabilities through the [private security channel](SECURITY.md).
To chat with other users and the maintainer, join the [Discord](https://discord.gg/QNdWfdwr7j).
For usage questions whose answers others should be able to find, go to [Discussions → Q&A](https://github.com/noah-qin/Corta/discussions/categories/q-a);
to share a theme or a setup, [Show and tell](https://github.com/noah-qin/Corta/discussions/categories/show-and-tell).
For other problems, [open an issue](https://github.com/noah-qin/Corta/issues/new/choose).
If you would like to support maintenance, [sponsor the project](https://github.com/sponsors/noah-qin).

## License and identity

Source code is licensed under [Apache 2.0](LICENSE). The Corta name,
pangolin mascot and app icon have separate terms in [NOTICE](NOTICE).
The pangolin's curled body forms a C; its cyan tail is a terminal cursor.
[Brand assets](docs/brand/README.md) include the mascot and social preview.
