# Corta

A native macOS terminal emulator in pure Swift. Metal rendering, Core
Text shaping, AppKit shell, a hand-written VT parser.

**Status (2026-10-07): 1.1.5 is the current release; the next
version's GitHub milestone is the working list.** A release is a
single manual `Release` run on `main` that versions, signs, notarises,
publishes and signs `appcast.xml` (D20, amended) — `docs/RELEASING.md` has
the steps. The `release` environment admits only `main` and has no
required reviewer: requesting the run is the approval.
`CHANGELOG.md`'s `[Unreleased]` section is the record of what lands
after it. Compatibility with AI command-line tools
is terminal correctness; built-in AI is a non-goal. A roadmap issue is
planned work, not a shipped capability, and never relaxes correctness,
resource limits or the explicit execution boundaries in `docs/SECURITY.md`.

## How work is scoped

New work is opened as a GitHub issue in the shape the `B`-series used:
outcome, scope, acceptance, dependencies. Work one issue as a coherent
batch — inspect its dependencies, implement the related changes, run
proportional automated *and* app-level verification, and report each
unchecked or human-only result honestly in the pull request. A pull
request closes its issue; the issue is not closed by hand.

## Documentation

Read the relevant document before making a design decision. They are the
source of truth; this file is an index. `docs/README.md` is the fuller one.

| Document                   | Covers                                                     |
| -------------------------- | ---------------------------------------------------------- |
| `docs/USER-GUIDE.md`       | Every feature, where it lives and how to use it, for a user |
| `docs/FEATURES.md`         | What the development tree does and its known limits, for a user |
| `docs/CONFIGURATION.md`    | Every config-file key: settings, themes, keybindings, presets, and when each applies — `DocumentationDriftTests` pins it to the code |
| `docs/DECISIONS.md`        | The settled decisions, one record each — read before proposing an architecture change |
| `docs/DESIGN.md`           | Goals, architecture, modules, non-goals                     |
| `docs/CONFORMANCE.md`      | Feature priorities (P0/P1/P2), the daily-driver checklist, test strategy, the five-point manual check |
| `docs/PERFORMANCE.md`      | Targets, the hot-path rules, how each number is measured, the numbers |
| `docs/SECURITY.md`         | Threat model, escape-sequence injection, resource caps, process safety, the three trust boundaries |
| `docs/TROUBLESHOOTING.md`  | What a user sees when something fails, and the fix          |
| `docs/TESTING.md`          | Which check each kind of change needs, and how to run it   |
| `docs/RELEASING.md`        | The release checklist, from `[Unreleased]` to a signed feed |
| `docs/LICENSING.md`        | The license header, which files carry it, `corta-license check`/`fix` |
| `docs/history/`            | The M1–M10 roadmap and the 0.1.1 audit notes — the record, never edited except to fix a link |
| `CONTRIBUTING.md`          | Commit convention, branches, pull requests                 |

## Decisions That Are Settled

`docs/DECISIONS.md` holds each with its reason and its cost to reopen. Do
not reopen one without a concrete new reason, and reopen it there. In one
line each:

- **D01** macOS only. **D02** Pure Swift, no FFI. **D03** Lines carry a
  `wrapped` flag. **D04** The terminal core is not `@MainActor`. **D05**
  Cells are 16 bytes and full; anything else is a side table. **D06**
  Selection lives in the core, document-anchored. **D07** Multi-viewport
  from day one; no singletons in the core. **D08** `$TERM` is
  `xterm-256color`.
- **D09** No multiplexer, no cross-platform, no tmux control mode, no AI
  features, no automation that runs commands. **D10** The config file is
  the only settings store and `docs/CONFIGURATION.md` is its reference —
  a key without a row is a key nobody can find; no `UserDefaults` for
  anything the file could carry. **D11** Curated themes and one system monospaced primary font;
  additional themes resolved from config. **D12** A font family is verified, never trusted.
- **D13** Never change the machine to test. **D14** App-layer changes
  are verified by launching the app. **D15**, **D16** *superseded* by the
  window built in code (see "A window is born sized"). **D17**
  Re-measure the frame-CPU baseline, under Release, after touching the
  render loop. **D18** No tool or session identifier in a commit message. **D19** Selection is hand-rolled;
  TextKit is not adopted. **D20** The update feed is signed from CI; the
  key lives in the reviewed `release` environment.
- **D21** Apple silicon only; Intel Macs stay on 1.0.1. **D22** The Debug
  build is a separate application — `dev.noahqin.Corta.dev`, its own stage
  directory, no updater, no move-to-Applications prompt. **D23** Sparkle is
  the one accepted third-party runtime dependency; the Mac App Store is
  closed to an unsandboxed terminal.
- **D24** The canvas stays below an opaque titlebar; no background
  extension. **D25** Metal frames present on their own, not with the
  Core Animation transaction.

## Working Rules

**Where to start.** The open GitHub issues are the working list; an
issue's dependencies say what has to be done first. `CHANGELOG.md`'s
`[Unreleased]` section gets an entry for every user-visible change in the
same pull request that makes it.

**Scope.** The issue's scope is the deliverable. Ligatures, transparency
and a second settings store are the classic scope creep here; each is a
decision (`docs/DECISIONS.md`) before it is a feature.

**Performance.** The hot path is PTY read → parse → grid write →
instance buffer build. There: `struct` and `ContiguousArray`, raw
`UInt8`/`UInt32` buffers, no per-cell `class`, no `String`, no ObjC
bridging, no per-frame allocation. Outside the hot path, write ordinary
idiomatic Swift — these rules are a targeted exception, not a house
style.

**Security.** Every byte from the PTY is hostile. Never write
attacker-supplied text back to the child's stdin. Some capabilities are
deliberately absent (title query, OSC 52 read) — do not add them as
"missing features". See `docs/SECURITY.md` §6 for the eight-rule summary.

**Never change the machine to test.** A verification fixture reached the
app by way of `launchctl setenv SHELL /tmp/corta-font-demo.zsh`, which
sets the variable for *every GUI application the user launches after it*,
not just this one — so Corta started under a bare `zsh -f` with no PATH
and a demo banner, for days, and `claude: command not found` looked like
a Corta bug. Pass a test shell in the environment of the launch you
control (`SHELL=/path ... Corta.app/Contents/MacOS/Corta`), never through
`launchctl setenv`, `defaults write`, the user's shell rc files, or
anything else that outlives the test. Clean up what you create.

**App-layer changes are verified by launching the app.** Offscreen render
tests assert pixel coverage and cannot see view-hierarchy, orientation,
startup-ordering or gesture defects — six such bugs shipped a blank or
unusable window while those tests stayed green. `docs/CONFORMANCE.md`
§4.4 has the five-point check.

**First responder is not free.** Nothing makes the terminal view first
responder by default; `SplitViewController.viewWillAppear` calls
`makeFirstResponder`. Without it `keyDown` never fires and menu actions
targeting First Responder (⌘V, ⌘=, …) silently dead-end — keep that
call intact.

**A window is born sized.** `TerminalWindowController(setup:asPanel:)`
creates the window with its final style mask and passes the root pane's
setup — a restore, a preset, a working directory — to
`SplitViewController(setup:)` by initializer, because the root pane spawns
as the view loads. `SplitViewController.prepareWindow` sizes the window
from the pane's cell metrics before anything shows it, then sets
`didSizeWindow`; `resizeSessionToFitView` sends nothing before that. A new
window's child receives exactly one winsize; a restored window, a new tab
and the Quick Terminal still spawn at the configured grid and resize once
to their frame. Size a window there, not in a
later layout pass, and do not insert style-mask flags after creation —
that one act was the source of every transient size D15 and D16 worked
around.

**Testing.** Golden-file grid tests: feed a byte stream, serialise the
grid to text, diff against a checked-in expectation. Record the `esctest`
pass rate and benchmark numbers at each release — `CONFORMANCE.md` §4.2
has the exact esctest invocation, and §4.3 the fuzz harness (`corta-fuzz`;
libFuzzer does not link on macOS with the current Xcode, so a seeded
mutation driver runs instead). A test never registers a real global
hotkey or flips the machine's secure-input mode; `GlobalHotKey` is tested
at its key-code mapping and `SecureInput` through an injected `System`.
The unit-test host gets a throwaway stage of its own
(`$TMPDIR/Corta-Tests-<pid>`, D22 amended), so the suite never reads or
writes the `Corta Dev/config` a developer runs with; a test that seems to
see odd settings is reading its own stage, not yours.

**SwiftUI where AppKit decides.** Settings' sidebar is an AppKit
`NSSplitViewItem(sidebarWithViewController:)` with SwiftUI pages beside it:
SwiftUI's split view in a hosting controller drew a flat sidebar, and
`Label` icons there flickered as the window became key — tiles with
explicit colours do not. A field in a toolbar item takes focus through
AppKit (`makeFirstResponder`), not `@FocusState`. In UI tests, a toolbar
`Menu` is a menu button whose *title*, not label, is its name.

**Screenshots follow the UI.** A change to what a window looks like
updates `docs/brand/` — `screenshot.png`, `sftp-browser.png`,
`settings.png` — by the recipe in `docs/brand/README.md`: the development
build, a scratch `CORTA_STAGE_DIR` and `ZDOTDIR`, public content only.

**Packaging has one check.** `corta-release-check` (a SwiftPM executable
in `CortaTerminal`, its judgements in the `ReleaseCheck` library) is the
only implementation of the release rules; its `package` subcommand,
`.github/workflows/release.yml` and `appcast.yml` all run it. A new rule
goes there and nowhere else. The feed's own invariant — the appcast, its
signature and the archive it names being the same bytes, verified under
the app's `SUPublicEDKey` — is `scripts/verify-appcast.swift`, which that
check calls at release time, `ci.yml` runs offline on every run and
`nightly.yml` runs against the published archives.

**Release secrets live in the release environment, and signing needs the
certificate.** The Developer ID `.p12` and its password, the App Store
Connect key that notarises, and the Sparkle key are secrets of the
`release` environment (`main` only, no required reviewer — D20 amended), never
repository secrets. An API key cannot sign with a cloud-managed Developer
ID certificate — the export fails with *Cloud signing permission error*
whatever the key's role — so do not propose key-only signing. A signing
change is proven with `release.yml`'s `dry_run` before it merges, and a
dry run that did not sign is a failure, not a pass: `release.yml` refuses
to fall back to ad hoc when only some of the secrets are set. Storing the
`.p12`: `base64` of a file the terminal cannot read (a TCC-protected
`~/Documents`) prints nothing, and `gh secret set` stores that nothing.

**Measure the frame-CPU baseline, under Release, after touching the
render loop.** The M6 render work took it from 2.40 ms to 4.19 ms — a
per-cell read of a global that retained an array, plus three unelided
`OptionSet.contains` calls — and back to 2.32 ms once both were folded
away. The regression was invisible in every test that passed; only the
number caught it. Those were Debug figures, and the `contains` calls cost
nothing once optimised: the baseline is now the Release one, from
`xcodebuild test -scheme Corta -testPlan Release -configuration
Benchmark -only-testing:CortaPerformanceTests` (`docs/PERFORMANCE.md`
§5.8). Write the render loop as
ordinary Swift, not shaped for `-Onone`.

**Never put a tool or session identifier in a commit message.** No
`Claude-Session:`, no assistant URLs, no "generated with" footer. The
repository is public and a commit message is the one place a private URL
can never be deleted from. `CONTRIBUTING.md` rule 6.

## Build and Test

Only stable, released Xcode toolchains are supported. `XCODE_PIN` is set
in four workflows — `ci.yml`, `nightly.yml`, `release.yml` and
`render.yml` — and they move together or not at all.

**The pin governs the artifact; it does not govern the numbers.** The pin
is what compiles the binary users run. Every measurement in
`docs/PERFORMANCE.md` comes from the maintainer's machine and whatever
toolchain that machine has, which is deliberately a different one — CI's
runner is a virtual machine whose GPU cannot even report Metal 4, so it
was never going to be where a performance number came from. The rule that
makes both usable: **a number and the number it is compared against must
come from the same machine and the same toolchain**, and every quoted
figure says which. `PERFORMANCE.md` §5.2 carries the detail.

```sh
xcodebuild -project Corta.xcodeproj -scheme Corta build
xcodebuild -project Corta.xcodeproj -scheme Corta test
```

Documentation for the core builds with
`xcodebuild docbuild -project Corta.xcodeproj -scheme Corta`. Fuzzing and
the core benchmark are SwiftPM products:

```sh
swift build --package-path CortaTerminal -c release --product corta-fuzz
CortaTerminal/.build/release/corta-fuzz --fuzz 500000 --seed 1 \
  CortaTerminal/Tests/Fuzz/corpus
CortaTerminal/.build/release/corta-bench
```

Layout:

- `Corta/` — AppKit shell, Metal renderer, font stack
- `CortaTerminal/` — the terminal core as a local SwiftPM package, with
  its own tests, golden fixtures, fuzz corpus and DocC catalog
- `CortaTests/`, `CortaUITests/` — app-hosted test targets;
  `CortaPerformanceTests/` — the Release measurements, without `@testable`
- `Corta.xcodeproj/` — build settings live in `project.pbxproj`
- `scripts/` — the two Swift scripts CI runs (Metal 4 probe, feed check)
  and the release workflow's `prepare-release` helpers with their tests;
  `script/` — local helpers (`build_and_run.sh`) and the isolated-sshd
  fixture CI runs for the real SSH/SFTP suite;
  packaging is `corta-release-check`, measurement is `TestPlans/Release`
- `TestPlans/` — `Unit` (the default), `UI` (interactive sessions only)
  and `Release` (`-configuration Benchmark`: the D17 measurement, and
  `MeasurementUITests` for the app-level numbers)
- `docs/` — user and design documentation, plus the dated records

Deployment target is macOS 26.0, Swift 6, app sandbox disabled
(intentionally — `docs/SECURITY.md` §4.1).

## Commit Messages

Full rules in `CONTRIBUTING.md`. In short —
[Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/),
English:

```
<type>(<optional scope>): <description>
```

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`,
`build`, `ci`, `chore`, `revert`.
Scopes: `app`, `ui`, `tests`, `assets`, `project`, `docs`.

Subject imperative, lowercase, no trailing period, ≤ 72 characters. Body
wrapped at 72, explains *why*. One logical change per commit. No emoji,
no advertising footers.
