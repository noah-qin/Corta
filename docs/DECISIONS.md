# Decisions

[Documentation index](README.md) · [Project overview](../README.md)

The decisions that are settled, one per entry, in the shape of an
architecture decision record: what was decided, why, and what it costs
to reopen. This is the one place a decision is argued; `DESIGN.md`
points here rather than repeating it. D01 and D02 are the project's
premise; D03–D08 constrain the data structures and were made before the
first line of the grid; the rest were learned in the field and recorded
where they were learned. Do not reopen one without a concrete new reason — and when a
reason exists, reopen it *here*, in a pull request that edits the entry,
so the record stays the record.

Status of every entry below is **accepted** unless it says otherwise.

---

## D01 — macOS only

**Decision.** Metal and Core Text directly, no abstraction layer, no
second platform.

**Why.** The premise of the project is that a terminal written *for* one
platform can be smaller, faster and more correct than one written *across*
several. Every portability layer is a place where the platform's own
answer is replaced by a compromise.

**Consequence.** Cross-platform is a non-goal (`DESIGN.md` §6). Forks are
welcome to change this; this repository will not.

## D02 — Pure Swift, no FFI

**Decision.** The VT parser, the grid, the renderer and the shell are
written here. No C libraries are bound for the terminal core.

**Why.** A parser bound from C is a parser whose bugs are somebody else's
release cycle, and whose memory model is not Swift's. Writing it also made
the fuzz harness and the golden-file tests possible on day one.

**Consequence.** `CortaTerminal` has zero third-party dependencies. The
app links one (Sparkle, for updates), and only the app.

## D03 — Lines carry a `wrapped` flag from the first commit

**Decision.** Every grid row records whether it is a soft continuation of
the row above.

**Why.** Reflow on resize, selection across a wrapped line, search that
spans a wrap and export that re-joins logical lines all consult the same
bit. Without it, narrowing a window corrupts the scrollback permanently
and copying a long command inserts a spurious newline. Retrofitting it
means rewriting the grid and every consumer.

**Consequence.** Any new feature that touches rows has to say what it does
with the flag. `CortaTerminal/Selection.swift` is the reference consumer.
Reflow of a large scrollback has to stay cheap enough for a live window
drag, which fires resize continuously.

## D04 — The terminal core is not `@MainActor`

**Decision.** `CortaTerminal` is a local SwiftPM package with default actor
isolation disabled. The Xcode project's `SWIFT_DEFAULT_ACTOR_ISOLATION =
MainActor` applies to the AppKit shell only.

**Why.** The PTY reader, the parser and the grid run off the main thread;
the hot path (`PERFORMANCE.md` §3) cannot hop actors per byte. A package of
its own is also what makes the core unit-testable and benchmarkable
without launching an app.

**Consequence.** Types in the core are `Sendable` by construction or
explicitly not shared. The app owns every main-thread hand-off.

## D05 — Cells are fixed-size; complex graphemes spill to a side table

**Decision.** A `Cell` is 16 bytes — a `UInt32` word, attributes and two
16-bit table keys — and is now full: Unicode's codespace ends at U+10FFFF,
so the scalar takes 21 bits of the word and the OSC 8 hyperlink id the
other 11. A grapheme cluster that does not fit in one scalar (combining
marks, an emoji ZWJ sequence) stores a key into an interned side table.
Rows are variable-length, stored up to the last non-blank cell.

**Why.** A fixed cell is what makes the instance-buffer build a linear
walk and the scrollback's memory predictable: every byte a cell grows
costs 12 MB across the 100k 120-column lines of `PERFORMANCE.md` §1's
scrollback target, which is why `CellTests` asserts the size rather than
a comment promising it. Variable-length
rows are what the log-heavy workloads Corta targets need — a fixed
200-cell row over 100k lines is 200 × 16 bytes × 100k ≈ 320 MB
(`PERFORMANCE.md` §4).

**Consequence.** Anything that wants per-cell identity needs a side table
keyed by position, not a new field. `CellTests` asserts the size.

## D06 — Selection lives in the core and is document-anchored

**Decision.** Selection coordinates are document rows — scrollback counts
backwards from the screen boundary — never viewport rows. The rules that
consult the `wrapped` flag live in `CortaTerminal/Selection.swift`; the
app stores only the range.

**Why.** A selection anchored to the viewport moves when output scrolls.
One that lives in the core follows its text, and can be tested without a
window. `DESIGN.md` §3.1 has the invariants every consumer of document
coordinates keeps, and the tests that pin them.

## D07 — Multi-viewport from day one

**Decision.** The renderer draws into a given rect, never into "the
window". No singletons in the core.

**Why.** Splits, tabs and the Quick Terminal are all "another viewport";
a renderer that assumed one window would have had to be rewritten for
the first of them. Written against a `TerminalSession` and a target
rectangle, a split is "instantiate another session".

## D08 — `$TERM` is `xterm-256color`

**Decision.** Corta announces itself as xterm rather than shipping its own
terminfo entry.

**Why.** A deliberate lie until conformance is proven: a `corta` terminfo
that programs have never heard of degrades to `dumb` on every host the
user ssh's into, unless a terminfo entry is shipped to every one of them.
`CONFORMANCE.md` records the esctest pass rate that would justify
changing this; revisit only once its conformance targets are met.

## D09 — No multiplexer, no cross-platform, no tmux control mode, no AI features

**Decision.** Each is a non-goal with a stated reason in `DESIGN.md` §6.
Compatibility with AI command-line tools is part of terminal correctness,
not a feature. Automation that *runs commands* — a "run this" intent or
URL — is likewise out: open/focus intents ship, execution does not
(`SECURITY.md` §4.6).

## D10 — One config file is the only settings store

**Decision.** `~/.config/corta/config` holds every setting;
`docs/CONFIGURATION.md` is its reference; `ConfigurationStore` reads,
writes and watches it; the Settings page is a front over that file and
holds no state of its own.

**Why.** Two stores drift, and the file has to win because a user can edit
it. This is not hypothetical: `BellMode` kept reading a `UserDefaults` key
after the settings page started writing `bell` to the file, so the Bell
setting silently did nothing.

**Consequence.** Do not add a `UserDefaults` key for something the config
file could carry. A key added to `Configuration` without a row in
`CONFIGURATION.md` is a key nobody can find. App-owned *state* (window
arrangement, directory history) lives in its own files and is not a
setting — `CONFIGURATION.md` §8 draws the line.

## D11 — Curated themes and one primary font

**Decision.** Settings and View offer Corta, Solarized and Mono alongside
user-defined themes, with a color editor. Issue #213 exposed that existing
presets were undiscoverable; all three are now offered with the existing preview. The only supported primary font is macOS System Monospaced;
font size remains adjustable. Legacy `font-family` names migrate to `system`.
PingFang and Apple Color Emoji remain glyph fallbacks for CJK and emoji.
Standardized VS16 emoji sequences occupy two cells: #213 showed that keeping
their scalar width shifted Claude Code table borders. Scalar width rules
remain unchanged; clients must count the complete emoji sequence.

**Why.** User feedback showed inconsistent appearance across installed faces.
A single primary family gives one font stack to validate and keeps the grid
predictable. Settings no longer scans installed fonts.

**Consequence.** Show the resolved font and preview the selected appearance
and cursor immediately. The catalog validation utilities remain available for
font/rendering diagnostics, without exposing additional families in the app.

## D12 — A font family is verified, never trusted

**Decision.** `MonospacedFontCatalog` measures every ASCII printable across
the regular, bold, italic and bold-italic faces before a family is used,
and the renderer scales an overwide glyph into its cell as a structural
backstop.

**Why.** `isFixedPitch` on one face does not mean the family's other faces
advance the same, and a glyph painted outside its cell corrupts its
neighbours.

**Consequence.** Do not reintroduce a first-face check, and do not let a
glyph paint outside its cell.

## D13 — Never change the machine to test

**Decision.** A test shell, a test config or a test environment is passed
in the environment of the launch under test (`SHELL=/path …
Corta.app/Contents/MacOS/Corta`, `CORTA_STAGE_DIR=…`), never through
`launchctl setenv`, `defaults write`, the user's shell rc files, or
anything else that outlives the test.

**Why.** A verification fixture once reached the app by way of
`launchctl setenv SHELL /tmp/corta-font-demo.zsh`, which sets the
variable for *every* GUI application launched afterwards. Corta started
under a bare `zsh -f` with no `PATH` and a demo banner for days, and
`claude: command not found` looked like a Corta bug.

## D14 — App-layer changes are verified by launching the app

**Decision.** Offscreen render tests assert pixel coverage and cannot see
view-hierarchy, orientation, startup-ordering or gesture defects.
`CONFORMANCE.md` §4.4 is the five-point check a person runs.

**Why.** Six such bugs shipped a blank or unusable window while every
test stayed green.

## D15 — Never size the session from a transient layout

**Status: superseded 2026-10-06** (#123). The window is now created in code
with its final style mask, so there is no transient layout to wait out; the
rule that remains is in *What replaced D15 and D16* below.

**Decision (as was).** `resizeSessionToFitView` waited for
`SplitViewController.sizeSettled` — the content view filling its window's
frame *and* a one-time frame correction having run. On macOS 26,
inserting `.fullSizeContentView` mid-flight changed what `setContentSize`
meant, and the first call mismeasured the chrome by a titlebar height;
`correctInitialWindowSize` ran once in `viewDidAppear`, after AppKit's
final adjustment.

**Why it held.** Delivering the transient winsize shrinks the grid and
strands content in the child (D.1 in the 0.1 roadmap).

**Why it went.** Every transient came from one act: the storyboard built a
window without `.fullSizeContentView`, and `viewWillAppear` inserted it.
`frameBeforeStyleChange`, `layoutSettled`, `didCorrectWindowSize`,
`correctInitialWindowSize` and the tab-shrink repair in `viewWillAppear`
all followed from that insert. A window born with the flag has one chrome
measurement from the start, and the gate had nothing left to guard.

## D16 — Window setup is staged before the storyboard runs

**Status: superseded 2026-10-06** (#123). There is no storyboard window to
stage for.

**Decision (as was).** Anything the root pane needs at spawn time — a
restored layout, a preset, an intent's working directory — was placed in
`SplitViewController.pendingSetup` before `instantiateInitialController`,
which loaded the content view and spawned the pane before returning.

**Why it held.** A value assigned to the controller afterwards reached only
the splits. The first pane of every restored window came up in the home
directory under the default shell until B16 found it.

**Why it went.** `TerminalWindowController(setup:)` builds the window and
hands the setup to `SplitViewController(setup:)` by initializer, so the
value is in the controller before its view can load; a static that every
window passed through is no longer needed.

### What replaced D15 and D16

A terminal window is created by `TerminalWindowController(setup:asPanel:)`
with its final style mask (`.fullSizeContentView` included) and its root
pane's setup as an initializer argument. `SplitViewController.prepareWindow`
dresses and sizes it from the root pane's cell metrics *before it is
shown*, and only then sets the pane's `didSizeWindow`: a layout at the
placeholder size before that never reaches the child, and none after it is
transient. A new window's session is born at the grid it keeps — its child
receives exactly one winsize. A restored window, a new tab and the Quick
Terminal know their frame only after the root pane spawns, so their child
starts at the configured grid and is resized once to it, as before. Size a
window in `prepareWindow`, not later, and never deliver a winsize before
`didSizeWindow`.

## D17 — The frame-CPU baseline is re-measured, under Release, after touching the render loop

**Decision.** `PERFORMANCE.md` §5.8 records the number; a change to the
render loop records a new one. The number is taken under Release —
`xcodebuild test -scheme Corta -testPlan Release -configuration
Benchmark -only-testing:CortaPerformanceTests` — never under the Debug
test action.

**Why.** The M6 render work took it from 2.40 ms to 4.19 ms — a per-cell
read of a global that retained an array, plus three unelided
`OptionSet.contains` calls — and back to 2.32 ms once both were folded
away. The regression was invisible in every test that passed.

Those figures were Debug figures, and so was every baseline until 1.1.0
(#110). A Debug number rewards code shaped for `-Onone`: re-measured
under Release, the `OptionSet.contains` calls cost nothing, while the
global read still cost ~5%. A baseline that can be moved by the
optimiser being switched off defends the wrong thing, so the render loop
is written as ordinary Swift and measured as it ships.

**What it costs.** A `Benchmark` build configuration (Release's compiler
settings, the development identity of D22) and a separate test bundle,
`CortaPerformanceTests`, that imports the app without `@testable` —
because `-enable-testing` inhibits the optimisation being measured. What
that bundle drives, the renderer declares `public`.

## D18 — No tool or session identifier in a commit message

**Decision.** No `Claude-Session:` trailer, no assistant URLs, no
"generated with" footer. `CONTRIBUTING.md` rule 6.

**Why.** The repository is public and a commit message is the one place a
private URL can never be deleted from.

## D19 — Selection is hand-rolled; TextKit is not adopted

**Decision.** `Selection.swift` and `TerminalView`'s own hit-testing stay.
`NSTextView`/TextKit was prototyped against the grid (B10, 2026-09-12)
and rejected.

**Why.** Four things make `DESIGN.md` §3.1's invariants what they are, and TextKit
fights each of them: it has no fixed column grid, so agreeing with the
grid means mirroring every write into a parallel `NSTextStorage` — a
second store that can disagree, the exact shape of the B04 bug; it places
glyphs by measured advance, whereas a CJK character occupies exactly two
columns by Corta's rule; `NSLayoutManager`/`NSTextLayoutManager` decide
wrapping from content and container width, whereas `wrapped` is a fact the
VT layer already decided from the columns the child was given; and every
drag has to be dispatched to a TUI's mouse reporting *before* whatever
handles it, so `NSTextView`'s built-in gestures would still have to be
intercepted. What TextKit would buy — system drag inertia, right-click
Services, `NSTextFinder`'s Find Bar — is narrower than it looks, and
accessibility, the other plausible win, is already implemented by hand and
tested end to end (`AccessibilityMappingTests`,
`TerminalViewAccessibilityTests`).

**Consequence.** A proposal to adopt a text system has to answer those
four points with something other than a shadow data structure.

## D20 — The update feed is signed from CI, with the key in a reviewed environment

**Decision.** Publishing a GitHub release is the last step a person
takes. `.github/workflows/appcast.yml` then signs the published archive
into `appcast.xml` with the Sparkle EdDSA key and merges the result
through a pull request. The private key is a secret of the `release`
GitHub environment — until the 2026-10-06 amendment below, one only `v*`
tags could use and that required the maintainer's approval on every run;
the key is piped to
`generate_appcast --ed-key-file -` and never written to disk. The
workflow is the only route: the manual `scripts/release.sh` was removed
in 1.1.0 (#133), because a second path that signs the feed is a second
place for the rules to drift, and a failed run is recovered by fixing
and re-running the workflow, not by going around it.

**Why.** Until 1.0.0 the feed was signed by hand from the maintainer's
login keychain — the one step of a release that depended on one machine.
The Developer ID certificate and the notary key, which can sign and
notarise *any* Mac program, had been repository secrets since
2026-09-03, so GitHub was already the trust anchor for what ships; the
Sparkle key added one more secret, not a new anchor. Since 1.1.0 (#134)
both are secrets of the same `release` environment, behind the same
approval.

**What it costs.** The Sparkle key is the one secret with no revocation:
a leaked Developer ID certificate is revoked and replaced, but a new
Sparkle public key is only known to copies that already updated, so a
rotation strands every install that did not. Hence the environment
rather than a repository secret: a workflow that reaches the key has to
run from a release tag and be approved by a person, so neither a pull
request nor a pushed branch can read it. Third-party actions in that
workflow are pinned by commit SHA, and Sparkle's tools by the tarball's
SHA-256. The maintainer keeps no separate backup of the key by choice;
the login keychain it was exported from is the only readable copy.

**Consequence.** A change to `appcast.yml` is a change to what can sign
updates, and is reviewed as such. Adding the key to any other
environment, a repository secret, or a workflow with a broader trigger
reopens this decision. The workflow's last step opens a pull request
with its own token, which needs the repository setting *Allow GitHub
Actions to create and approve pull requests* (Settings › Actions ›
General › Workflow permissions); 1.0.1's feed had to be merged by hand
because that switch was off, and it is the one thing the dry run cannot
exercise.

**Amended 2026-10-06 — one-click releases.** The maintainer chose a manual
Run workflow request on protected `main` as the release decision. Merges
continue to run CI without publishing. After the request, `Release`
prepares and auto-merges a version PR after CI, builds its exact merge
commit, tests/signs/notarises/checks it, then tags and publishes. There are
no hand-edited versions, tag pushes, draft publication or repeated
approvals. It calls `appcast.yml` in the same pipeline because releases
created with `GITHUB_TOKEN` do not trigger another workflow. The feed still
uses the environment key through stdin, validates the published archive,
and merges through a PR with CI. The release environment admits only
`main` and no longer requires a reviewer; the earlier `v*` tag policy is
removed. This intentionally moves the approval boundary to code admitted
to protected main and the manual workflow request, rather than approval of
each job. Missing signing configuration fails; published archive bytes
are never replaced. A serialized pipeline prevents releases overtaking
each other, and neither merges nor feed updates trigger another release.

*What the boundary is, measured 2026-10-07.* The `release` environment has
a branch policy (`main`) and no required reviewer, and the `main` ruleset
requires status checks but no review, with the admin role allowed to
bypass it. So one maintainer credential able to push to `main` and request
a workflow run reaches the Developer ID certificate, the notary key and the
unrevocable Sparkle key with no second step. That is the accepted cost of
one-click releases; restoring a required reviewer (or removing the
ruleset bypass) is how to buy the second step back, and either reopens
this amendment.

**Amended 2026-10-08 — the feed is signed as well as its archives.**
`Sparkle-Info.plist` sets `SURequireSignedFeed`, so a Corta built from now
on refuses a feed whose trailing `sparkle-signatures` block does not verify
under `SUPublicEDKey`; `SUSignedFeedFailureExpirationInterval = 0` removes
Sparkle's fallback that accepts an unverifiable feed after twenty days of
failures (the fallback exists for key rotation, which D20 already rules
out); and `SUVerifyUpdateBeforeExtraction` checks an archive's EdDSA
signature before anything unzips it. `generate_appcast` signs the whole
feed by itself once the archive it adds carries the key, with the same key
through the same stdin, so `appcast.yml` is unchanged. Before this an edit
to `appcast.xml` on `main` could put release notes, links or flags in front
of every user unsigned; copies older than the first build with the key
(build 11) still read the feed that way, which is what
`verify-appcast.swift`'s field allowlist is for. The cost: a feed edited by
hand after signing, or a signing step that fails, stops updates for every
new copy until the feed is re-signed — `verify-appcast.swift` fails such a
feed on every CI run, so it cannot merge.

## D21 — Corta builds for Apple silicon only

**Decision.** From 1.1.0 the application and `corta-exec` are `arm64`
only (`ARCHS = arm64` in every configuration of `project.pbxproj`, and
on the command line of every release build). Intel Macs stay on 1.0.1,
which remains downloadable. The deployment target does not change:
macOS 26.0.

**Why.** Metal 4 needs an M1 or later, and it is the renderer 1.1.0
keeps (#109). macOS 26 is the last release that runs on an Intel Mac,
and the four models it still supports are all five or more years old. A
universal build existed only to carry the classic Metal path, which
meant two GPU backends to maintain, test and keep pixel-equivalent for a
shrinking audience, with no measured win for either
(`history/2026-09-15-B12-METAL4-BACKEND.md`).

**What it costs.** 1.0.0 and 1.0.1 shipped universal, and an Intel Mac
that has one of them gets no further updates. No second feed and no
transitional build is published for them — accepted, not mitigated.
Every shipped Corta carries Sparkle 2.9.6, which honours an appcast
item's `sparkle:hardwareRequirements`: an item that requires `arm64` is
not offered to a Mac without it, so an Intel Mac on 1.0.1 sees no update
rather than downloading one it cannot open. `generate_appcast` writes the
element for an executable with no Intel slice, and
`corta-release-check --appcast` fails a feed item for an arm64-only
app that lacks it.

Xcode does not apply a project's `ARCHS` to Swift package products, so
`corta-exec` came out universal beside an arm64 app until
`release.yml` passed `ARCHS=arm64` on the command line.
`corta-release-check` holds both executables to `lipo -archs` = `arm64`, so
a build route that forgets fails at packaging rather than shipping.

**Consequence.** Every GPU code path may assume
`MTLGPUFamily.metal4`-class hardware on the machine that runs it; a
device without it is a failure to report, not a second renderer. Adding
an Intel slice back reopens this decision, and with it the second
backend.

## D22 — The development build is a separate application

**Decision.** The Debug configuration builds `CortaDev.app` with the
bundle identifier `dev.noahqin.Corta.dev`, its own icon and the display
name "Corta Dev" (the menu bar shows the product name, `CortaDev`). `AppPaths` gives any bundle whose identifier ends in
`.dev` a stage directory — `~/Library/Application Support/Corta Dev/` —
which holds its config file, its Application Support state and the rc
file the shell-integration installer writes. The development build never
offers to move itself into `/Applications` and carries no updater. The
Release configuration is unchanged: same identifier, same icon, same
product name, same signature.

**Why.** Corta is the terminal its own development happens in. With one
bundle identifier there is one global hotkey registration, one TCC
authorisation record, one Sparkle update target and one LaunchServices
identity, shared between the application being written and the
application being worked in — so a rebuild, a crash, a test run or an
update prompt reaches the session the developer is using. Deriving the
stage from the identifier rather than from `CORTA_STAGE_DIR` is what
makes the isolation unconditional: an environment variable only protects
the launches that remembered to set it, and a double-clicked build,
a test host and an Xcode run are three different launches.

**What it costs.** Two build settings that differ by configuration
(`CORTA_BUNDLE_SUFFIX`, `CORTA_PRODUCT_NAME`) and a Debug artefact whose
file name is not the product name, so anything that hard-codes
`Corta.app` in a Debug path is wrong. `PRODUCT_MODULE_NAME` is pinned to
`Corta` so `@testable import Corta` means the same thing in both
configurations. Two applications can be installed at once, which is the
point, and is worth one line in the troubleshooting guide.

**Consequence.** `CORTA_STAGE_DIR` is no longer how a development build
is isolated; it is how a *Release* build is staged for a launched-app
check (`CONFORMANCE.md` §4.4). A new piece of state Corta owns goes under
`AppPaths`, not under a path derived from the home directory —
`AppPathsTests` and the release check are what catch the exceptions.

**Amended 2026-10-02.** The development stage is also the configuration a
developer runs Corta Dev with every day, so a unit-test host — which XCTest
marks with `XCTestConfigurationFilePath` — gets a per-process throwaway
stage instead (`TESTING.md`, "The test host cannot reach your own
configuration"). A test that wrote a setting and was killed before its
`defer` had left that value in the developer's file.

`AppPaths` is the one type that asks whether it is under test — to choose
the stage and, under a test host only, to prune earlier runs' stages —
and it kept the probe when #122 removed `QuadPipelineCache`'s
(2026-10-06). Everything else a test changes it passes in, a dependency
at construction, because the test runs before that code does. The stage is chosen as the host launches, before any test
code runs, so the only thing a test could set in time is a launch
variable, and a variable only protects the launches that remember it: the
reason this entry derives the stage from the bundle identifier at all.

## D23 — Sparkle is the one accepted third-party runtime dependency

**Decision.** Corta updates itself with Sparkle, and Sparkle is the only
third-party code that ships inside the app. D02 is about the terminal
core; this entry is about the application around it, and a second
runtime dependency is a new decision here, not a package added in passing.

**Why.** macOS has no native in-app update mechanism outside the Mac App
Store, and the Mac App Store is not open to Corta: it requires the App
Sandbox, which `SECURITY.md` §4.1 deliberately does not use, because a
terminal has to spawn the user's shell with the user's reach. Without an
updater a user stays on whatever version they downloaded until they
remember to look. Sparkle is the updater nearly every directly
distributed Mac application uses, verifies every archive against the
EdDSA public key in the app before it installs anything, and is
maintained; writing one would be a second product with the same
security surface and none of its field record.

**What it costs.** The whole update path is kept on purpose, not as
legacy: `.github/workflows/appcast.yml` and the EdDSA key in the reviewed
`release` environment (D20); the Sparkle-shaped rules in the release
check — an integer build number, the enclosure URL naming the GitHub
release archive, the enclosure length matching the archive; the
`SUPublicEDKey` the feed is verified under; and Sparkle's MIT notice, with
the notices of the code it bundles, in About ▸ Acknowledgements (#118,
`LICENSING.md`). Dependabot proposes Sparkle bumps from the committed
`Package.resolved`, and each is reviewed as a change to what installs
code on users' machines.

**Consequence.** A proposal to drop Sparkle, replace it, or move Corta to
the Mac App Store reopens this entry and §4.1 together. The development
build carries no updater (D22), so Sparkle only ever runs in the signed
Release application.

## D24 — The canvas stays below the titlebar; no background extension

**Decision.** The terminal is not wrapped in an `NSBackgroundExtensionView`.
The titlebar stays opaque chrome, and the grid's top inset keeps following
the measured chrome (`ViewController.windowChrome`).

**Why.** Tried in a spike for #124 and captured through XCUITest, on a
dark theme with coloured output in the first row (2026-10-06). Under the
opaque titlebar the extension view changes nothing visible, since the
titlebar covers what it extends. With `titlebarAppearsTransparent`, it
mirrors and blurs the content's top edge into the titlebar — and for a
terminal that edge is the first row of output, so the window title sat
over a smear of the previous command's text. An image extends into
chrome well; a line of text does not.

**Consequence.** Reopen with a design for what the titlebar band should
show (a solid theme colour, say) rather than with the API alone.

## D25 — Metal frames present on their own, not with the transaction

**Decision.** The terminal's `CAMetalLayer` keeps `presentsWithTransaction`
off.

**Why.** Measured for #124 (2026-10-06, `PERFORMANCE.md` §5.12). The
AppKit overlays that track rows — the command-status rules — do run one
to two frames ahead of the Metal text during continuous output, in every
captured frame. But `presentsWithTransaction` left that gap exactly as it
was (also with `preferredFrameLatency` 1), and cost about 1.5 ms of median
keypress-to-glass. The gap comes from the overlay committing with this
run-loop pass while the display link's drawable lands one to two frames
later, which presenting inside the transaction does not change for a
`CAMetalDisplayLink`-driven pipeline.

**Consequence.** An overlay that must stay locked to the text is drawn in
the Metal pass (#238), not synchronised by presentation. Reopen this only
with a measurement in which the property closes the gap.
