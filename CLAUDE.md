# Corta

A native macOS terminal emulator in pure Swift. Metal rendering, Core
Text shaping, AppKit shell, a hand-written VT parser.

**Status: 0.1.0. M7 and M8 done, M6 has one open step.** M1–M5 are complete.
M6.12 was measured with Typometer at 45.5 ms average keypress-to-pixel
latency; the sole open step is M6.16 (signed, notarized direct-download
packaging, pending signing credentials). M7 closed the places the
terminal was still guessing — font behaviour, command boundaries (OSC
133), and window lifecycle. `docs/ROADMAP.md` is the tracking record.

## Documentation

Read the relevant document before making a design decision. They are the
source of truth; this file is an index.

| Document                | Covers                                                     |
| ----------------------- | ---------------------------------------------------------- |
| `docs/CONFIGURATION.md` | Every config-file key: settings, themes, keybindings, and when each applies |
| `docs/DESIGN.md`        | Goals, locked decisions, architecture, modules, milestones, non-goals |
| `docs/ROADMAP.md`       | The ordered step-by-step plan — start here when implementing |
| `docs/CONFORMANCE.md`   | Feature priorities (P0/P1/P2), the daily-driver checklist, test strategy |
| `docs/PERFORMANCE.md`   | Targets, the two decisions that matter, hot-path rules, benchmarks |
| `docs/SECURITY.md`      | Threat model, escape-sequence injection, resource caps, process safety |
| `CONTRIBUTING.md`       | Commit convention, branches, pull requests                 |

## Decisions That Are Settled

Do not reopen these without a concrete new reason. Each is explained in
`docs/DESIGN.md` §2.

- **macOS only.** Metal and Core Text directly, no abstraction layer.
- **Pure Swift, no FFI.** The VT parser is written here, not bound.
- **Lines carry a `wrapped` flag from M1** — reflow, selection and search
  all depend on it. Adding it later means rewriting the grid.
- **The terminal core is not `@MainActor`.** It lives in a local SwiftPM
  package (`CortaTerminal`) with default actor isolation disabled; the
  Xcode project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` applies to
  the AppKit shell only.
- **Cells are fixed-size; complex graphemes spill to a side table.** Rows
  are variable-length.
- **Selection lives in the core and is document-anchored.** Selection
  coordinates are document rows (scrollback counts backwards from the
  screen boundary), never viewport rows, and the rules that consult the
  `wrapped` flag live in `CortaTerminal/Selection.swift` — the app stores
  only the range. See `docs/DESIGN.md` §2.7.
- **Multi-viewport from day one.** Render into a given rect, never into
  "the window". No singletons in the core.
- **`$TERM` is `xterm-256color`.** A deliberate lie until conformance is
  proven.
- **No multiplexer, no cross-platform, no tmux control mode, no AI
  features.** See `docs/DESIGN.md` §6. Settings are one native page in
  the menu bar next to Edit/Shell, backed by a single text config file
  (M6.1) — the page edits the file, which remains the source of truth.
- **The config file at `~/.config/corta/config` is the only settings
  store, and `docs/CONFIGURATION.md` is its reference.** A key added to
  `Configuration` without a row in that document is a key nobody can
  find. `ConfigurationStore` reads it, writes it and watches it; the
  settings page is a front over that and holds no state of its own. Do
  not add a `UserDefaults` key for something the config file could
  carry — two stores drift, and the file has to win because a user can
  edit it. This is not hypothetical: `BellMode` kept reading a
  `UserDefaults` key after the settings page started writing `bell` to
  the file, so the Bell setting silently did nothing until M7.13.
- **Corta offers one theme and one font; it resolves several.** The
  settings page and the View menu list `Theme.builtIn` (just `corta`) and
  no font family picker at all — the system monospaced face is the one
  Corta stands behind. `Theme.known` still resolves `solarized` and
  `mono`, and `font-family` still accepts any family
  `MonospacedFontCatalog` vouches for, so a config file naming either
  keeps working. Offering a palette or a face means having read text in it
  for a working day; passing a mechanical check is not the same claim. Add
  to the offered list only after that, not because the code supports it.
- **A font family is verified, never trusted.** `isFixedPitch` on one
  face does not mean the family's bold, italic and bold-italic faces
  advance the same; `MonospacedFontCatalog` measures every ASCII
  printable across all four, and the renderer scales an overwide glyph
  into its cell as a structural backstop. Do not reintroduce a
  first-face check, and do not let a glyph paint outside its cell.
- **A cell is 16 bytes and now full.** `Cell.scalar` is 21 bits and the
  OSC 8 hyperlink id (M6.8) is the other 11. Anything else that wants
  per-cell identity needs a side table keyed by position, not a new
  field: `CellLayoutTests` asserts the size, and `PERFORMANCE.md` §4
  measures what a byte per cell costs over a 100k-line scrollback.

## Working Rules

**Where to start.** `docs/ROADMAP.md` is the working checklist. Steps
are ordered deliberately; do not start one before the previous is done.

**Scope.** M2 (`vim`/`tmux`/`htop` render correctly) is the checkpoint.
Before M2, do not add features, change scope, or refactor architecture.
Ligatures, transparency and the config system are the classic scope
creep here.

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
tests assert pixel coverage and cannot see view-hierarchy, orientation or
startup-ordering defects — four such bugs shipped a blank window while
those tests stayed green. See `docs/CONFORMANCE.md` §4.4 for the
four-point check.

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

**Testing.** Golden-file grid tests are built during M1, not later:
feed a byte stream, serialise the grid to text, diff against a checked-in
expectation. Record `esctest` pass rate and benchmark numbers at each
milestone — `CONFORMANCE.md` §4.2 has the exact esctest invocation, and
§4.3 the fuzz harness (`corta-fuzz`; libFuzzer does not link on macOS
with the current Xcode, so a seeded mutation driver runs instead).

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

Fuzzing and the core benchmark are SwiftPM products:

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
