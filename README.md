<div align="center">

<img src="docs/brand/corta-pangolin-mascot.png" width="160" alt="Corta's pangolin mascot, curled into a C with a cyan cursor on its tail">

# Corta

**A native macOS terminal, built in Swift.**

Metal rendering · AppKit input · A dependency-free terminal core

> Built for people who live in the terminal on Mac — real CJK / IME, Metal-smooth text, and a VT engine with **zero** third-party dependencies.

[![CI](https://github.com/noah-qin/Corta/actions/workflows/ci.yml/badge.svg)](https://github.com/noah-qin/Corta/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/noah-qin/Corta?style=flat-square)](https://github.com/noah-qin/Corta/releases/latest)
![Platform](https://img.shields.io/badge/macOS-26.0%2B-4d4d4d?style=flat-square)
![Swift](https://img.shields.io/badge/Swift-6-f05138?style=flat-square)
[![License](https://img.shields.io/badge/license-Apache--2.0-2f81f7?style=flat-square)](LICENSE)

**[↓ Download](https://github.com/noah-qin/Corta/releases/latest)** ·
[Documentation](docs/README.md) ·
[Contribute](CONTRIBUTING.md) ·
[Report a bug](https://github.com/noah-qin/Corta/issues/new?template=bug_report.yml)

<img src="docs/brand/screenshot.png" width="960" alt="Corta displaying a coloured git graph, CJK and emoji column alignment, and terminal colour ramps">

</div>

## Made for macOS

Corta brings together a hand-written VT engine, Metal rendering, Core Text
shaping and native AppKit input. The terminal core is a separate Swift package
with no third-party dependencies. The app uses [Sparkle](https://sparkle-project.org)
for updates.

| Native interaction | Terminal fundamentals | Everyday workflow |
| :--- | :--- | :--- |
| CJK input and IME composition | True colour and Unicode text | Split panes and restored layouts |
| Core Text font fallback | Reflow and scrollback search | Command palette and custom shortcuts |
| Quick Terminal and Shortcuts | Bracketed paste and OSC 8 links | Shell integration and command history |
| Secure Keyboard Entry | Kitty keyboard and direct graphics protocols | OpenSSH, SFTP and remote editing |

The table describes `main`; a release may trail it by a row or two. The
[feature reference](docs/FEATURES.md) has the details, requirements and
limitations, and the [design decisions](docs/DECISIONS.md) explain what
Corta deliberately leaves out.

## How is Corta different?

iTerm2 and Ghostty are both excellent terminals, and Corta borrows the
standards they helped set. It makes a different set of bets.

| | Corta | iTerm2 | Ghostty |
| :--- | :--- | :--- | :--- |
| Written in | Swift, end to end | Objective-C and Swift | Zig core, Swift and GTK front ends |
| Platforms | macOS only, by decision | macOS | macOS and Linux |
| Terminal core | A separate Swift package with **zero** third-party dependencies | In the app | `libghostty`, shared across platforms |
| Rendering | Metal, with Core Text shaping and font fallback | Metal | Metal on macOS, OpenGL on Linux |
| Settings | One text file, edited by a native Settings window too | Preferences UI and profiles | One text file |
| Scope | Terminal correctness; no multiplexer, no AI, no scripting engine | Everything, including tmux integration and a Python API | Terminal plus a cross-platform library |

**Why pick Corta.**

- **It is a Mac app first, not a port.** CJK input and IME composition,
  Secure Keyboard Entry, VoiceOver, Shortcuts, the Quick Terminal and the
  Services menu are built on the native AppKit paths, so they behave the
  way the rest of your Mac does — not the way a cross-platform toolkit
  approximates it.
- **Every byte from the PTY is treated as hostile.** The VT engine is
  hand-written in Swift with resource caps on every unbounded input, and
  the capabilities that let a program read your clipboard or window title
  back are deliberately absent. The [security model](docs/SECURITY.md)
  spells out the three trust boundaries.
- **One config file is the whole settings store.** `~/.config/corta/config`
  is what the Settings window edits, what a preset loads and what
  [the reference](docs/CONFIGURATION.md) documents key by key; a test fails
  when the documentation drifts from the code.
- **Remote work stays in the terminal.** SSH sessions use the system
  OpenSSH and carry their host and directory context, an SFTP browser sits
  beside the shell, and a remote file opens in your local editor as a
  managed copy that uploads only when you say so — with a conflict check
  against the remote first.
- **The numbers are published, including the bad ones.** Frame CPU, idle
  CPU, throughput, keypress-to-glass latency and the esctest2 result are
  measured, dated and recorded [below](#quality-with-evidence), with the
  method for each — the latency figure is above target and the README says
  so rather than leaving the row out.

If you need tmux control mode, a Linux build or a scripting API, iTerm2 or
Ghostty is the better choice today; those are
[settled decisions](docs/DECISIONS.md), not gaps waiting to be filled.

## Install

Requires **macOS 26.0 or later**. Download the archive and matching SHA-256
file from [GitHub Releases](https://github.com/noah-qin/Corta/releases/latest).
Follow the signing and installation notes attached to that release, verify the
checksum, unzip the archive and move `Corta.app` to `/Applications`.

```sh
# Run in the directory containing both downloaded files.
shasum -a 256 -c Corta-1.0.1.zip.sha256
unzip Corta-1.0.1.zip
```

> [!NOTE]
> **Release status:** [1.0.0](https://github.com/noah-qin/Corta/releases/tag/v1.0.0)
> was published on 2026-09-19 and is what the feature table above
> describes; the archive is signed with a Developer ID and notarised.
> Later changes on `main` are recorded under `[Unreleased]` in the
> [changelog](CHANGELOG.md) until the next release.

For updates, use **Corta ▸ Check for Updates…** or download a newer release.
Installation help and uninstall instructions are in
[Troubleshooting](docs/TROUBLESHOOTING.md).

## Make it yours

Settings are stored in `~/.config/corta/config`. The native Settings window
and the text file edit the same configuration.

```ini
theme = midnight
theme.midnight.inherit = solarized
theme.midnight.dark.background = #101018

bind.split-right = ctrl+s
bind.command-palette = cmd+shift+p
```

The [configuration reference](docs/CONFIGURATION.md) lists every key, default
and when changes take effect. Shell integration for zsh can be installed from
**Settings ▸ Terminal**.

## Build and test

Use macOS 26.0 or later and Xcode with Swift 6.2 or later. CI's exact Xcode
pin is recorded in [the workflow](.github/workflows/ci.yml). The app resolves
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
| Frame CPU, 120 × 40 full rebuild, Debug | 2.26 ms, three-run mean | [Performance](docs/PERFORMANCE.md) |
| Idle CPU, Release, 20 seconds | 0.05% | [Performance](docs/PERFORMANCE.md) |
| Scrollback memory, 100k × 120 lines | 185.0 MB | [Performance](docs/PERFORMANCE.md) |
| Core feed throughput | 144.2 MiB/s, five-run mean | [Performance](docs/PERFORMANCE.md) |
| Keypress to glass | 66.3 ms average, p95 78.7 ms; above target | [Method and limitations](docs/PERFORMANCE.md) |
| esctest2 | 126 passed, 334 known bugs, 107 failed; 567 total | [Raw results](docs/esctest/2026-09-17-results.txt) |

Performance was measured on Apple M5, macOS 27.0, on 2026-09-18; the cited
report records power conditions by measurement. The esctest2 snapshot is
from 2026-09-17. Its historical 81.1% figure counts passes **plus known bugs**;
it is not a pass rate. See [conformance](docs/CONFORMANCE.md) for interpretation.

Known limitations include above-target input latency, incomplete VT
conformance, zsh-only shell integration and direct-transmission-only Kitty
graphics. Accessibility and input reports still need follow-up. The
[limitations reference](docs/FEATURES.md#known-limits) and
[interactive test records](docs/test-results/) preserve the details.

## Find your way around

| I want to… | Start here |
| :--- | :--- |
| Configure Corta | [Configuration](docs/CONFIGURATION.md) |
| Understand a feature or limitation | [Features](docs/FEATURES.md) |
| Diagnose a problem | [Troubleshooting](docs/TROUBLESHOOTING.md) |
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
For other problems, [open an issue](https://github.com/noah-qin/Corta/issues/new/choose).
If you would like to support maintenance, [sponsor the project](https://github.com/sponsors/noah-qin).

## License and identity

Source code is licensed under [Apache 2.0](LICENSE). The Corta name,
pangolin mascot and app icon have separate terms in [NOTICE](NOTICE).
The pangolin's curled body forms a C; its cyan tail is a terminal cursor.
[Brand assets](docs/brand/README.md) include the mascot and social preview.
