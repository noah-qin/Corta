# Decisions

The decisions that are settled, one per entry, in the shape of an
architecture decision record: what was decided, why, and what it costs
to reopen. `DESIGN.md` §2 carries the longer argument for the first
seven; the rest were learned in the field and recorded where they were
learned. Do not reopen one without a concrete new reason — and when a
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
bit. Retrofitting it means rewriting the grid and every consumer.

**Consequence.** Any new feature that touches rows has to say what it does
with the flag. `CortaTerminal/Selection.swift` is the reference consumer.

## D04 — The terminal core is not `@MainActor`

**Decision.** `CortaTerminal` is a local SwiftPM package with default actor
isolation disabled. The Xcode project's `SWIFT_DEFAULT_ACTOR_ISOLATION =
MainActor` applies to the AppKit shell only.

**Why.** The PTY reader, the parser and the grid run off the main thread;
the hot path (`PERFORMANCE.md` §3) cannot hop actors per byte.

**Consequence.** Types in the core are `Sendable` by construction or
explicitly not shared. The app owns every main-thread hand-off.

## D05 — Cells are fixed-size; complex graphemes spill to a side table

**Decision.** A `Cell` is 16 bytes and is now full: `Cell.scalar` is 21
bits and the OSC 8 hyperlink id is the other 11. Rows are variable-length.

**Why.** A fixed cell is what makes the instance-buffer build a linear
walk and the scrollback's memory predictable (`PERFORMANCE.md` §4 measures
what one byte per cell costs over 100k lines).

**Consequence.** Anything that wants per-cell identity needs a side table
keyed by position, not a new field. `CellLayoutTests` asserts the size.

## D06 — Selection lives in the core and is document-anchored

**Decision.** Selection coordinates are document rows — scrollback counts
backwards from the screen boundary — never viewport rows. The rules that
consult the `wrapped` flag live in `CortaTerminal/Selection.swift`; the
app stores only the range.

**Why.** A selection anchored to the viewport moves when output scrolls.
One that lives in the core follows its text, and can be tested without a
window (`DESIGN.md` §2.7).

## D07 — Multi-viewport from day one

**Decision.** The renderer draws into a given rect, never into "the
window". No singletons in the core.

**Why.** Splits, tabs and the Quick Terminal are all "another viewport";
a renderer that assumed one window would have had to be rewritten for
the first of them.

## D08 — `$TERM` is `xterm-256color`

**Decision.** Corta announces itself as xterm rather than shipping its own
terminfo entry.

**Why.** A deliberate lie until conformance is proven: a `corta` terminfo
that programs have never heard of degrades to `dumb` on every host the
user ssh's into. `CONFORMANCE.md` records the esctest pass rate that
would justify changing this.

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
setting silently did nothing until M7.13.

**Consequence.** Do not add a `UserDefaults` key for something the config
file could carry. A key added to `Configuration` without a row in
`CONFIGURATION.md` is a key nobody can find. App-owned *state* (window
arrangement, directory history) lives in its own files and is not a
setting — `CONFIGURATION.md` §8 draws the line.

## D11 — Corta offers one theme and one font; it resolves several

**Decision.** The Settings page and the View menu list `Theme.builtIn`
(just `corta`) and no font family picker. `Theme.known` still resolves
`solarized` and `mono`, and `font-family` accepts any family
`MonospacedFontCatalog` vouches for, so a config file naming either keeps
working.

**Why.** Offering a palette or a face means having read text in it for a
working day; passing a mechanical check is not the same claim.

**Consequence.** Add to the offered list only after that, not because the
code supports it.

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

**Decision.** `resizeSessionToFitView` waits for
`SplitViewController.sizeSettled` — the content view filling its window's
frame *and* the one-time frame correction having run. On macOS 26,
inserting `.fullSizeContentView` mid-flight changes what `setContentSize`
means, and the first call mismeasures the chrome by a titlebar height;
`correctInitialWindowSize` runs once in `viewDidAppear`, after AppKit's
final adjustment.

**Why.** Delivering the transient winsize shrinks the grid and strands
content in the child (D.1 in the 0.1 roadmap).

**Consequence.** Do not bypass the gate, and do not "fix" the size earlier
in `viewWillAppear` or `viewWillLayout`, where the measurement is stale.

## D16 — Window setup is staged before the storyboard runs

**Decision.** Anything the root pane needs at spawn time — a restored
layout, a preset, an intent's working directory — is placed in
`SplitViewController.pendingSetup` before `instantiateInitialController`,
which loads the content view and spawns the pane before returning.

**Why.** A value assigned to the controller afterwards reached only the
splits. The first pane of every restored window came up in the home
directory under the default shell until B16 found it.

## D17 — The frame-CPU baseline is re-measured after touching the render loop

**Decision.** `PERFORMANCE.md` §5 records the number; a change to the
render loop records a new one.

**Why.** The M6 render work took it from 2.40 ms to 4.19 ms — a per-cell
read of a global that retained an array, plus three unelided
`OptionSet.contains` calls — and back to 2.32 ms once both were folded
away. The regression was invisible in every test that passed.

## D18 — No tool or session identifier in a commit message

**Decision.** No `Claude-Session:` trailer, no assistant URLs, no
"generated with" footer. `CONTRIBUTING.md` rule 6.

**Why.** The repository is public and a commit message is the one place a
private URL can never be deleted from.
