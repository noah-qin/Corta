# Corta

A native macOS terminal emulator in pure Swift. Metal rendering, Core
Text shaping, AppKit shell, a hand-written VT parser.

**Status: 0.1.1 is the shipped release; every batch of the v1.0.0
roadmap (`B01`–`B16`) has landed on `main`.** `CHANGELOG.md`'s
`[Unreleased]` section is the record of what has landed since 0.1.1, and
the next release is cut from it. Compatibility with AI command-line tools
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
| `docs/CONFIGURATION.md`    | Every config-file key: settings, themes, keybindings, presets, and when each applies |
| `docs/DECISIONS.md`        | The settled decisions, one record each — read before proposing an architecture change |
| `docs/DESIGN.md`           | Goals, architecture, modules, non-goals                     |
| `docs/CONFORMANCE.md`      | Feature priorities (P0/P1/P2), the daily-driver checklist, test strategy, the five-point manual check |
| `docs/PERFORMANCE.md`      | Targets, the hot-path rules, how each number is measured, the numbers |
| `docs/SECURITY.md`         | Threat model, escape-sequence injection, resource caps, process safety, the three trust boundaries |
| `docs/TROUBLESHOOTING.md`  | What a user sees when something fails, and the fix          |
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
  anything the file could carry. **D11** One theme and one font offered;
  several resolved. **D12** A font family is verified, never trusted.
- **D13** Never change the machine to test. **D14** App-layer changes
  are verified by launching the app. **D15** Never size the session from
  a transient layout. **D16** Window setup is staged before the
  storyboard runs. **D17** Re-measure the frame-CPU baseline after
  touching the render loop. **D18** No tool or session identifier in a
  commit message.

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

**Never size the session from a transient layout.** With
`.fullSizeContentView`, the first layout after window setup runs at the
content-rect height (frame minus titlebar). Delivering that winsize
shrinks the grid and strands content (D.1). `resizeSessionToFitView`
waits for `SplitViewController.sizeSettled` — the content view filling
its window's frame *and* the one-time frame correction having run —
because a pane in a split tree legitimately never fills it — do not
bypass the gate.

**`setContentSize` sizes the frame once `.fullSizeContentView` is in the
mask.** On macOS 26, inserting that style flag changes what
`setContentSize` means mid-flight: the value lands as the *frame* size,
and the first call mismeasures the chrome by a full titlebar height.
`SplitViewController` corrects the frame once in `viewDidAppear`
(`correctInitialWindowSize`), after AppKit's final adjustment; do not
"fix" the size earlier in `viewWillAppear` or `viewWillLayout`, where the
measurement is stale.

**Testing.** Golden-file grid tests: feed a byte stream, serialise the
grid to text, diff against a checked-in expectation. Record the `esctest`
pass rate and benchmark numbers at each release — `CONFORMANCE.md` §4.2
has the exact esctest invocation, and §4.3 the fuzz harness (`corta-fuzz`;
libFuzzer does not link on macOS with the current Xcode, so a seeded
mutation driver runs instead). A test never registers a real global
hotkey or flips the machine's secure-input mode; `GlobalHotKey` is tested
at its key-code mapping and `SecureInput` through an injected `System`.

**Window setup is staged, not assigned.** `instantiateInitialController`
loads the content view and spawns the root pane before it returns. A
restore, a preset or a working directory for the root pane goes through
`AppDelegate.instantiateWindowController(setup:)`, never onto the
controller afterwards (D16).

**Packaging has one check.** `scripts/check-release.sh` is the only
implementation of the release rules; `package-release.sh`, `release.sh`
and `.github/workflows/release.yml` call it. A new rule goes there and
nowhere else.

**Measure the frame-CPU baseline after touching the render loop.**
The M6 render work took it from 2.40 ms to 4.19 ms — a per-cell read of
a global that retained an array, plus three unelided `OptionSet.contains`
calls — and back to 2.32 ms once both were folded away. The regression
was invisible in every test that passed; only the number caught it.

**Never put a tool or session identifier in a commit message.** No
`Claude-Session:`, no assistant URLs, no "generated with" footer. The
repository is public and a commit message is the one place a private URL
can never be deleted from. `CONTRIBUTING.md` rule 6.

## Build and Test

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
- `CortaTests/`, `CortaUITests/` — test targets
- `Corta.xcodeproj/` — build settings live in `project.pbxproj`
- `docs/` — design documentation

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
