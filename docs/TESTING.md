# Testing Corta

[Documentation index](README.md) · [Contributor guide](../CONTRIBUTING.md)

Run commands from the repository root. Use macOS 26.0 or later and an Xcode
toolchain with Swift 6.2 or later. Only released Xcode toolchains are supported.
[CI](../.github/workflows/ci.yml) and [nightly](../.github/workflows/nightly.yml)
pin the same stable release; update both `XCODE_PIN` values together. A failed build is not a failed test run.

## Choose a check

| Change | Automated verification | Additional evidence |
| :--- | :--- | :--- |
| Documentation or GitHub templates | `DocumentationDriftTests` (local links, and `CONFIGURATION.md` against the code) | Review rendered Markdown and examples |
| Parser, grid, search or session | Core suite, focused regression test, fuzz replay for PTY input changes | Specification or minimal reproducer |
| AppKit, input, settings or windows | Relevant `CortaTests`, then app suite | Launch the app; record the five-point manual check |
| Rendering or hot path | Relevant rendering tests and app suite | Before/after frame CPU under Release (`-testPlan Release`), same machine |
| Localization or accessibility | Relevant app tests | In-context language or VoiceOver review |
| Packaging or release | `corta-release-check` against the artifact ([below](#packaging)) | Signing and notarization evidence |

The [conformance guide](CONFORMANCE.md) defines manual checks and protocol
coverage. [Performance](PERFORMANCE.md) defines benchmark workloads. Record
what you could not verify; an unchecked item is not a passing result.

## Terminal core

```sh
swift test --package-path CortaTerminal

# Narrow a failure before rerunning the whole suite.
swift test --package-path CortaTerminal --filter ParserTests
swift test --package-path CortaTerminal --filter GoldenTests
```

Tests use Swift Testing in
[`CortaTerminal/Tests/CortaTerminalTests`](../CortaTerminal/Tests/CortaTerminalTests/);
the SFTP client's, with their in-memory server (`SFTPTestSupport`), are in
[`CortaTerminal/Tests/CortaSFTPTests`](../CortaTerminal/Tests/CortaSFTPTests/).
`swift test` runs both.
Keep regressions beside the subsystem they exercise. Name a test after the
observable behaviour, derive expected results from the specification or a
reproducer, and keep inputs as small as possible. Preserve the original
failing bytes when reducing a parser case.

### Golden fixtures

[`GoldenTests.swift`](../CortaTerminal/Tests/CortaTerminalTests/GoldenTests.swift)
registers each fixture and its grid dimensions. Each case has an escape-encoded
`.in` file and a hand-reviewed `.txt` grid dump in `Golden/`.

1. Add the smallest input that demonstrates the behaviour; cite the rule in
   a leading `#` comment.
2. Write the expected grid independently, then register the case.
3. Run `GoldenTests` and inspect the row-level difference.

Literal newlines format the fixture and are ignored. Write `\n` for a line
feed, `\r` for carriage return, `\e` for ESC, `\xNN` for a byte, and `\\`
for a backslash. Only lines beginning with `#` are comments.

`CORTA_UPDATE_GOLDEN=1` rewrites expected files from the current implementation.
Use it only for an intentional dump-format migration, inspect every diff,
and rerun with the variable unset. It must not be used to make a regression
pass by replacing the expected behaviour.

### Fuzzing and sanitizers

```sh
swift build --package-path CortaTerminal -c release --product corta-fuzz
CortaTerminal/.build/release/corta-fuzz CortaTerminal/Tests/Fuzz/corpus/*
CortaTerminal/.build/release/corta-fuzz --fuzz 200000 --seed 1 \
  CortaTerminal/Tests/Fuzz/corpus

CORTA_TEST_TIMEOUT_SCALE=10 swift test --package-path CortaTerminal --sanitize=thread
CORTA_TEST_TIMEOUT_SCALE=10 swift test --package-path CortaTerminal --sanitize=address
```

CI uses a fixed mutation seed for reproducibility. Nightly runs rotate it and
retain failing inputs. Include the seed, command, toolchain and crashing input
when reporting a failure. The timeout scale accommodates instrumented runs;
it does not change assertions. Every ceiling a test waits on goes through
`testTimeout` / `testTimeoutInterval` (`PTYTestSupport.swift`) so the scale
reaches it — the SFTP rig's idle-read deadline included. See
[conformance §4.3](CONFORMANCE.md#43-fuzzing) for invariants and harness
details.

A test that passes on a fast machine and fails on the CI runner is a timing
bug until proven otherwise, and the runner's conditions can be reproduced:
a few cores, all busy. Pin the CPU with `yes` and loop the suite under the
thread sanitizer:

```sh
for i in $(seq 1 14); do (yes > /dev/null &); done
swift build --package-path CortaTerminal --build-tests --sanitize=thread
for i in $(seq 1 30); do
  CORTA_TEST_TIMEOUT_SCALE=10 swift test --package-path CortaTerminal \
    --skip-build --sanitize=thread --filter SFTP 2>&1 | grep '✘ Test'
done | sort | uniq -c
pkill -x yes
```

This is how the two `SFTPSession` bugs behind the 2026-09-15 → 09-21
nightly failures were found: both were real races (window admission
counted from registration rather than from acquisition; a cancelled id
recycled before its marker was consumed), not slow-runner noise.

## App tests

The tests are hosted inside the app. A local ad-hoc signature lets a contributor
run them without the maintainer's signing identity:

```sh
xcodebuild test \
  -project Corta.xcodeproj -scheme Corta \
  -testPlan Unit \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM="" \
  -resultBundlePath /tmp/CortaTests.xcresult
```

Use a fresh result-bundle path for each run. Add
`-only-testing:CortaTests/ConfigurationTests` to focus a suite.

Three test plans under `TestPlans/` say what runs where:

| Plan | Contains | Run it with |
| ---- | -------- | ----------- |
| `Unit` | `CortaTests`; `CortaUITests` and `CortaPerformanceTests` listed but disabled | `-scheme Corta -testPlan Unit` — the default, and what CI runs |
| `UI` | `CortaUITests`, except `MeasurementUITests` | `-scheme Corta -testPlan UI` — an interactive desktop session only |
| `Release` | `CortaPerformanceTests`: the frame-CPU baseline, the instance-upload benchmark, renderer construction cost; `CortaUITests/MeasurementUITests`: the app-level numbers | `-scheme Corta -testPlan Release -configuration Benchmark`, with `-only-testing:` one of the two — the measurement D17 records, or the app's (below) |

`UI` is deliberately not part of the default run: a UI test drives the
keyboard and the frontmost window, so running it takes the machine away
from whatever else is happening on it. It stays *listed* in `Unit` with
`enabled: false` so the target is still built — a compile error in the UI
tests is caught on every run — without anything being driven. Neither CI
nor an offscreen rendering test replaces launching the app.
`CortaPerformanceTests` is listed the same way, for the same reason.

### Stages for the UI plan

The UI runner is sandboxed: it reads anywhere but writes only its own
container, which the app cannot read, so a UI test cannot write the
config it launches the app with. `CursorAndWindowUITests` and
`SystemStatusAndThemeEditorUITests` read theirs from a root prepared
outside the sandbox, and skip with this instruction without it:

```sh
UI_FIXTURES=$(CortaUITests/stage-ui-fixtures.sh)
FEEDBACK_STAGE=$(CortaUITests/stage-feedback-ui.sh)
TEST_RUNNER_CORTA_UI_FIXTURES="$UI_FIXTURES" \
TEST_RUNNER_CORTA_FEEDBACK_STAGE="$FEEDBACK_STAGE" xcodebuild test \
  -project Corta.xcodeproj -scheme Corta -testPlan UI
```

Remove both printed directories once the development app has exited.

### Terminal feedback regression (#213)

The UI runner is sandboxed; Corta and its spawn helper cannot reliably use
fixtures inside that runner's container. Prepare a disposable shared stage
before running the tab, font and appearance regression:

```sh
TASK_STAGE=$(CortaUITests/stage-feedback-ui.sh)
TEST_RUNNER_CORTA_FEEDBACK_STAGE="$TASK_STAGE" xcodebuild test \
  -project Corta.xcodeproj -scheme Corta -testPlan UI \
  -only-testing:CortaUITests/SearchAndTabUITests/testFeedbackAppearanceTabsAndFontSize
```

The test checks the actual configuration write and dark/light pixels, not
only whether clicking a menu succeeded. It also verifies in-place tab
rename, Escape cancellation, tab shortcuts, right-click New Tab and theme
preview. Without the shared stage it reports a skip with the setup reason.
Remove the printed stage after the development app has exited.

### Measuring the render loop

A render-loop change records a new frame-CPU baseline (`DECISIONS.md`
D17), and the baseline is a Release number:

```sh
xcodebuild test -project Corta.xcodeproj -scheme Corta \
  -testPlan Release -configuration Benchmark -destination 'platform=macOS' \
  -only-testing:CortaPerformanceTests
cat /tmp/corta-frame-cpu-baseline.txt /tmp/corta-instance-upload.txt
```

Take three runs before the change and three after, on the same machine
and toolchain. `-configuration Benchmark` is not optional: without it the
scheme's Debug configuration builds the same plan, and the report's first
line says `Debug, -Onone`. `Benchmark` is Release's compiler settings with
the development identity (D22), so the test host is `CortaDev.app`.

The measuring suites live in their own bundle, `CortaPerformanceTests`,
which imports the app without `@testable`: `-enable-testing` inhibits the
optimisation a Release figure exists to see, and every file in
`CortaTests` needs it. A suite added there can reach only what `Corta`
declares `public`. `PERFORMANCE.md` §5.8 has the recorded numbers and what
the figure does and does not include.

### Measuring the app

The numbers `PERFORMANCE.md` §5.6 quotes from a live window come from
four commands, run from the repository root on the machine the numbers
are for (§5.2). None of them reads or writes your configuration: the
Benchmark build is `CortaDev.app` (D22).

```sh
# 1. Launch time, idle and occluded CPU, 1/2/4-pane floods, window
#    memory, scripted keypress → glass. About five minutes; it drives the
#    keyboard and the front window, so leave the machine alone.
xcodebuild test -project Corta.xcodeproj -scheme Corta \
  -testPlan Release -configuration Benchmark -destination 'platform=macOS' \
  -only-testing:CortaUITests/MeasurementUITests

# 2. Energy: per-process CPU, idle wakeups and App Nap, recorded while
#    command 1 runs in another terminal. Filter the trace on CortaDev.
xcrun xctrace record --template 'Activity Monitor' --all-processes \
  --time-limit 6m --output .build/traces/energy.trace

# 3. Where the latency goes: the os_signpost chain (§5.3), recorded while
#    command 1's keypress test — or a person — types.
xcrun xctrace record --instrument os_signpost --all-processes \
  --time-limit 90s --output .build/traces/signposts.trace

# 4. A person typing (the --manual kind, §5.7) or scrolling: launch the
#    Benchmark build with the rings on, type ~300 digits, read the lines.
xcodebuild build -project Corta.xcodeproj -scheme Corta \
  -configuration Benchmark -derivedDataPath .build/measure -quiet &&
  CORTA_RESTORE_WINDOWS=0 CORTA_RENDER_METRICS=1 SHELL=/bin/sh \
  .build/measure/Build/Products/Benchmark/CortaDev.app/Contents/MacOS/CortaDev &
  log stream --style compact \
  --predicate 'subsystem == "dev.noahqin.Corta" AND category == "render-metrics"'
```

Command 1 prints every figure on a line starting `measurement:` and
attaches the raw summary lines to the result bundle. The distributions —
`keypressToPresent`, `cpuFrame`, `gpu`, `drawableWait` — are what gets
quoted; XCTest's launch, CPU and memory metrics are averages and are
regression baselines only (§5.1). It types with a Latin keyboard layout
selected and puts yours back afterwards. For an A/B, put
`TEST_RUNNER_CORTA_MAX_DRAWABLES=2` or `TEST_RUNNER_CORTA_FRAME_LATENCY=1`
in front of it; the test passes the variable to the app.

Machine-wide power in watts needs `powermetrics`, which needs root: `sudo
powermetrics --samplers cpu_power,gpu_power -i 1000` beside command 1, when
the person running it chooses to. Nothing here asks for it.

### Which environments can run the render tests

Measured 2026-09-25 (issue #107). `scripts/metal-capability.swift` is the
one implementation of the question — `ci.yml` prints it on every run,
`render.yml` requires it, and you can ask it yourself:

```sh
swift scripts/metal-capability.swift                  # print the families
swift scripts/metal-capability.swift --require-metal4  # exit 1 without Metal 4
```


| Environment | Device | `MTLGPUFamily.metal4` | Families |
| ----------- | ------ | --------------------- | -------- |
| GitHub hosted `macos-26` | `Apple Paravirtual device` | **no** | `apple5` |
| Apple silicon hardware (M1 or later) | e.g. `Apple M5` | yes | `metal4`, `apple9`, … |

Metal 4 is the only renderer (#109), so the hosted runner cannot build
one at all, and a pane there shows the "does not support Metal 4" failure
and starts no shell — the same thing a user in a virtual machine sees.
Every suite that renders, or that needs a working pane (a live session, a
font size the renderer applied), carries
`.enabled(if: MetalRenderTarget.supportsMetal4, …)`, so a run without the
family reports it as *skipped, with the reason*. That is not done to keep
CI green: those tests have nothing to test on that GPU, and running them
there would test the failure pane instead. `Metal4UnavailablePaneTests`
is the reverse — enabled only *without* Metal 4 — and holds the failure
pane to its message, to starting no shell, and to surviving a font-size
and a focus change. Until #107 measured this, the Metal 4 tests returned
early instead, which is indistinguishable from passing: every one went
unexecuted on CI for the whole of 1.0 while the job stayed green.

`ci.yml` prints both halves of that on every run: the capability line
before the build, and `tests: total=… passed=… skipped=…` after it. The
test command uses `-quiet`, which hides every per-test line, so without
the counts a green run would still not say what it had skipped.

Metal 4 hardware is therefore the only place those tests mean anything,
and there are two ways to get there:

- `.github/workflows/render.yml` — the same test plan on a **self-hosted**
  Apple silicon runner. It is `workflow_dispatch` only, on purpose: this
  repository is public, and a `pull_request` trigger would let a stranger's
  fork run code on the maintainer's machine. It fails before the tests if
  the machine does not report `metal4`, and records which Xcode produced
  the result.
- Locally, on any Apple silicon Mac:
  `xcodebuild test -scheme Corta -testPlan Unit`, with the result recorded
  under `docs/test-results/` before a release. The five-point
  launched-app check (`CONFORMANCE.md` §4.4) is done on the same machine
  and carries the rest of the guarantee.

That is the trade #107 measured and #109 accepted; it is not a reason to
keep a second backend alive.

**Whole frames against a reference.** `RenderReferenceTests` compares
complete frames — the synthetic quad scene, an empty frame's clear, and a
terminal frame with a Kitty image, a selection, current and other search
matches, a hovered link and each cursor shape — with the PNGs in
`CortaTests/RenderReferences/`. They were recorded from the classic Metal
path before #109 removed it, so they are the before/after comparison that
replaced comparing two live backends: one code value per channel is
blend rounding, anything more fails with both images attached.
`TEST_RUNNER_CORTA_RECORD_RENDER_REFERENCES=1` rewrites them; use it only
for an intended visual change, and inspect every PNG it writes. They were
recorded with Menlo 14 on macOS 27; a macOS release that changes glyph
rasterisation fails them, which is the signal to look, then re-record.

### Waits are ceilings, and CI gets a bigger one

The app suite waits on real child processes printing, a reader loop
observing an exit, a debounced sweep settling — latencies that belong to
the machine rather than to the code. Those figures are written so that
reaching one means something is genuinely wrong, which stops being true on
a saturated runner: `childExitOnItsOwnShowsAToast` waited ten seconds for a
toast and did not get one on a run where nothing was broken.

`CortaTests/TestTimeout.swift`'s `testTimeoutScale` multiplies every such
ceiling. CI sets `TEST_RUNNER_CORTA_TEST_TIMEOUT_SCALE=3`, which
`xcodebuild` delivers to the test host as `CORTA_TEST_TIMEOUT_SCALE`;
nothing else sets it, so a local run keeps the written number and a genuine
hang still fails quickly.

The core package has the same knob under the same name (#129) and CI sets
it there too — as `CORTA_TEST_TIMEOUT_SCALE` directly, because `swift test`
runs the tests in-process rather than inside a host. It was introduced for
the nightly sanitizer lane and for a while *only* that lane set it, so on
ordinary CI the deadlines it was meant to relax were still their original
length; that is why #128 recurred there.

It scales a *ceiling*, never a sleep: a wait finishes as soon as its
condition holds, so a larger ceiling costs nothing on a healthy run.

**It is not a substitute for a test that races.** An assertion that
something has *not* happened yet, or one that compares against a value
sampled before the event it is about, gets rarer under a bigger ceiling and
no more correct. Three of the four flakes fixed alongside this were of that
kind and were rewritten instead.

### The test host cannot reach your own configuration

The Debug configuration builds a separate application — `CortaDev.app`,
bundle identifier `dev.noahqin.Corta.dev` (D22) — and `AppPaths` gives any
bundle whose identifier ends in `.dev` a stage directory. A *unit-test
host* goes one step further: XCTest sets `XCTestConfigurationFilePath` in
it, and with no explicit stage `AppPaths` gives it a throwaway one,
`$TMPDIR/Corta-Tests-<pid>`. So the suite reads and writes nothing of
yours — not `~/.config/corta/config`, not
`~/Library/Application Support/Corta/`, not the development build's own
`Corta Dev/` (the one you run day to day), not `~/.zshrc`. Nothing has to
be set on the command line for that to hold, and the next test host
removes the stages of earlier runs whose process has gone.

That last step is new on 2026-10-02. Before it the test host used the
development build's stage, and a sanitizer abort between
`commandHistoryBounds`' write and its `defer` left
`command-history-limit = 0` in the developer's `Corta Dev/config`; every
later run that expected a command record then failed, and the
development build silently stopped recording command history.

`CORTA_STAGE_DIR` still overrides the choice, which is what stages a
*Release* build for a launched-app check. UI tests launch the app as a
separate process, which XCTest does not mark, so they keep the
development stage unless they set `CORTA_STAGE_DIR` themselves.

### Downloads to a volume without ACLs

exFAT, FAT and some SMB shares answer `ENOTSUP` when a download clears its
inherited ACL. The real-server test for it is opt-in, because it needs such
a volume mounted; a scratch disk image, mounted out of sight and removed
afterwards, is enough:

```sh
dir=$(mktemp -d)
hdiutil create -size 64m -fs ExFAT -volname CortaNoACL -o "$dir/noacl.dmg" -quiet
hdiutil attach "$dir/noacl.dmg" -nobrowse -mountpoint "$dir/mnt" -quiet
CORTA_NOACL_VOLUME="$dir/mnt" swift test --package-path CortaTerminal \
  --filter downloadToVolumeWithoutACLs
hdiutil detach "$dir/mnt" -quiet && rm -rf "$dir"
```

On 2026-10-02 it passed with the fix and failed with `errno 45` without it.

### The application under the thread sanitizer

```sh
TEST_RUNNER_CORTA_TEST_TIMEOUT_SCALE=3 TEST_RUNNER_TSAN_OPTIONS=halt_on_error=0 \
  xcodebuild test -project Corta.xcodeproj -scheme Corta -testPlan Unit \
  -enableThreadSanitizer YES -only-testing:CortaTests
grep -c 'WARNING: ThreadSanitizer' <log>
```

`halt_on_error=0` collects every report in one run instead of stopping at
the first; the scale gives the sanitizer's slowdown the same headroom CI
gets. A test that indexes into a result after a wait must `#require` the
wait, or a slow run crashes the whole host instead of failing one test.

### Launching the app in isolation

App-layer changes are verified by launching the app (`DECISIONS.md` D14).
The `Corta (Dev)` scheme is that launch: ⌘R in Xcode, or

```sh
xcodebuild -project Corta.xcodeproj -scheme 'Corta (Dev)' \
  -configuration Debug -derivedDataPath .build/run build
open -n .build/run/Build/Products/Debug/CortaDev.app
```

It runs beside an installed Corta rather than over it — a different
identity, a different icon, its own configuration — so it can be rebuilt,
crashed or killed while you keep working in the installed one. The
development build also never offers to move itself into `/Applications`
and carries no updater.

Logs and telemetry come from the ordinary tools, since both builds log
under the same subsystem:

```sh
log stream --info --predicate 'process == "CortaDev"'
log stream --info --predicate 'subsystem == "dev.noahqin.Corta"'
```

`CORTA_RESTORE_WINDOWS=0` (set by the `Corta (Dev)` scheme) skips the
restore, and `SHELL` names the shell to spawn — pass it in the environment
of the launch you control, never through `launchctl setenv`. Then run the
five-point check in
[conformance §4.4](CONFORMANCE.md#44-app-layer-verification-requires-a-launched-app).

**Glass under the accessibility settings.** Reduce Transparency and
Increase Contrast are system settings, so they are not switched to check
the find bar and the command palette. The development build's
`--glass-preview` launch argument opens one window with both in all four
combinations over a terminal background; light or dark follows the
`appearance` in the stage's `config`. Capture it with a throwaway XCUITest's
`window.screenshot()` rather than the whole screen.

Never change global hotkeys, secure-input state, shell startup files or
`launchctl` environment variables just to test (D13). Prefer injected
dependencies and per-process environments. Use temporary directories for
fixtures and clean up the resources you create.

### Environment switches

The app reads these from its own launch environment, and only through
`DiagnosticsEnvironment` (`Corta/DiagnosticsEnvironment.swift`). They are
measurement and staging seams, deliberately not config keys (D10): a
launch that sets none behaves as shipped. Set one on the launch you
control — or as `TEST_RUNNER_<name>` in front of `xcodebuild test`, which
hands it to the test host — never through `launchctl setenv` (D13). None
reaches a shell: `ChildEnvironment` strips every `CORTA_` name, and
`DiagnosticsEnvironmentTests` holds this table, that stripping and the
single reader to the code.

| Variable | Values | Builds | Effect |
| --- | --- | --- | --- |
| `CORTA_FRAME_LATENCY` | number ≥ 1 | all | The display link's `preferredFrameLatency` (default 2; `PERFORMANCE.md` §5.7) |
| `CORTA_MAX_DRAWABLES` | `2` or `3` | all | The Metal layer's drawable count (default 3), for a double-buffering A/B |
| `CORTA_RENDER_METRICS` | any; an absolute path also writes there | all | Frame-timing percentiles to the `render-metrics` log category, and to the file |
| `CORTA_RENDER_METRICS_KEYSTROKES` | integer > 0 | all | Keystrokes per keypress-to-present summary (default 200) |
| `CORTA_RESTORE_WINDOWS` | `0` | all | Skips reopening last run's windows |
| `CORTA_STAGE_DIR` | absolute path | all | Config, Application Support and rc files move into it (`AppPaths`) |
| `CORTA_SFTP_SSH` | absolute path to an executable | Debug only | Runs in place of `ssh` for the SFTP browser, with the same argv; logged (`SECURITY.md` §4.3) |

The test suites read their own `CORTA_*` knobs — `CORTA_TEST_TIMEOUT_SCALE`,
`CORTA_RECORD_RENDER_REFERENCES`, `CORTA_STRESS_SECONDS`,
`CORTA_UPDATE_GOLDEN` and the benchmark output paths — described where
each is used above; the app never reads them.

## The update feed

`appcast.xml` on `main` *is* the live feed — `Sparkle-Info.plist`'s `SUFeedURL`
points straight at it, so merging a change to that file publishes it to
every running Corta. It is held to one invariant: **the feed, the
signature in it and the archive it points at describe the same bytes, and
that signature verifies under the `SUPublicEDKey` the shipped app
carries.**

`scripts/verify-appcast.swift` is that check, in three layers:

```sh
swift scripts/verify-appcast.swift                       # offline: structure, URLs, builds, key
swift scripts/verify-appcast.swift --archive dist/Corta-1.0.1.zip --version 1.0.1
swift scripts/verify-appcast.swift --download            # every item, against the published archives
```

- The **offline** layer runs on every CI run: well-formed XML, every item
  carrying a version, an integer build, an enclosure, a length and a
  base64 64-byte signature; each enclosure URL being exactly the GitHub
  release URL for its own version; build numbers unique and newest-first,
  since Sparkle offers whichever item has the highest one.
- The **archive** layer is what `corta-release-check check --archive`
  adds, offline, against the archive it already holds, with or without
  `--appcast` — `appcast.yml` runs it once the feed is signed. `corta-release-check
  package` cannot: it runs in `release.yml` before the release is
  published, and the feed is signed only after that (D20), so there is no
  signature yet. It verifies the feed alone and checks that the feed does
  not already publish the version, whose signed bytes a rebuild would
  never match; `--rehearsal` skips only that rule, for a dry run.
- The **`--download`** layer runs nightly and covers *every* item, not
  only the newest — an update nobody can install is equally broken
  whichever release it belongs to, and the older entries are the ones no
  release ever re-checks.

Presence of a signature was never the question. A signature made with a
private key whose public half is not the app's `SUPublicEDKey` is
well-formed, and every installed Corta rejects it: an update nobody can
install, with every other check green. The SHA-256 sidecar does not catch
that — it proves the bytes are the published bytes, not that the key pairs
with the app.

Exit status is the number of failed checks, as `corta-release-check` reports.

## Packaging

```sh
swift run --package-path CortaTerminal -c release corta-release-check \
  package path/to/Corta.app 1.1.1 dist          # archive, sidecar, then the check
swift run --package-path CortaTerminal -c release corta-release-check \
  check path/to/Corta.app --version 1.1.1 --archive dist/Corta-1.1.1.zip \
  --appcast --require-notarized
```

`corta-release-check` is the one implementation of the release rules
(`RELEASING.md`): versions and build number against `project.pbxproj`,
license headers, the CHANGELOG and README naming the version, arm64-only
executables (D21), the code signature, and — with the flags — the archive
and its sidecar, the feed item, Developer ID, the staple and Gatekeeper.
Every rule prints `ok` or `FAIL`; the exit status is the number that
failed. The judgements over text live in the `ReleaseCheck` library and
are unit-tested by `swift test --package-path CortaTerminal`; the checks
that need a signed, notarised app only run against one.

## Documentation

```sh
xcodebuild test -project Corta.xcodeproj -scheme Corta \
  -only-testing:CortaTests/DocumentationDriftTests
```

`DocumentationDriftTests` checks every local link and image in the
repository's Markdown, including files not yet staged. It does not follow remote URLs or fragments — review
those, and the rendered result, on GitHub or in a Markdown preview.
The same suite, part of the app suite, pins `docs/CONFIGURATION.md` to
the code: every key the config file is written with, and every `bind.`
command with its default, must have a matching row.

## Report a result

Include the commit, macOS and Xcode versions, exact command, test result and
any skipped checks. Separate build failures, assertion failures, crashes,
timing failures and fixture/setup problems. Attach an `.xcresult` for app
failures or the smallest byte stream for parser failures, after removing
private data. Dated manual records belong in [test-results/](test-results/).

The historical esctest2 number that includes “known bugs” is a compatibility
classification, not an automated-test pass rate. Always report all three
counts: passed, known bugs and failed.

## Security follow-up fixtures

`script/verify_ssh_integration.py` runs `SFTPSSHIntegrationTests` through
real OpenSSH on encrypted localhost TCP. It creates temporary host/client
keys, known_hosts and client/server configs, disables agent use and
forwarding, and reaps the test sshd and deletes credentials afterwards.
Run it from the repository root with `python3 script/verify_ssh_integration.py`.
It does not alter the installed SSH service or the user's SSH configuration.
The suite is explicitly skipped without the fixture environment. A failed
fixture setup must not be counted as a successful authentication rejection.

The SFTP protocol fake and real `sftp-server` tests complement that fixture:
they cover hostile replies, silent-peer cancellation, request admission,
list/tree budgets, atomic transfer and local destination symlinks. They do
not reproduce every external server, proxy, authentication method or network.

Run both full core sanitizers and the full application Unit plan for lifecycle
changes. The October 2 TSAN investigation found an unsynchronized mutable
interceptor in the test server; its storage is now a Mutex. New tests pin stale
search status, a blocked directory probe, private copy modes, approval snapshots,
same-metadata remote replacement and rejected glyphs without atlas thrashing.
See the [dated results](test-results/2026-10-02-follow-up.md) for actual evidence.

Development builds isolate Corta-owned storage only. A stage path does not
isolate HOME, SSH_AUTH_SOCK, credentials or external editors. Use the fixture
configuration or an independent account for credential-sensitive checks.

For extended GPU lifetime checks set `TEST_RUNNER_CORTA_STRESS_SECONDS=300`
and run the entire `CortaTests/ImageMemoryAndTextureTests` suite. Verify the
printed cycle count; a method-only filter can select zero Swift Testing cases.
For stable mixed-history/reflow comparisons, use `corta-bench --history`
without simultaneous builds or sanitizer workloads.

## System status, cursor and theme follow-up

The feature suites are CursorAndWindowSettingsTests, SystemStatusAndThemeEditorTests,
InputSourceIndicatorTests, SettingsModelTests, ConfigurationTests and
ShellIntegrationSessionTests. Their UI counterparts use disposable CORTA_STAGE_DIR
and ZDOTDIR directories and process-only AppleLanguages overrides. They must not
edit production preferences, global language settings or user startup files.

SystemStatusAndThemeEditorUITests exercises status selection, independent menu
entrances, theme save/cancel and immediate appearance preview. Its localization
case launches all nine shipped languages and opens the translated theme and
host-detail interfaces. CursorAndWindowUITests checks actual idle blinking and
window constraints. The catalog tests check coverage and format arguments;
coverage alone does not establish native-speaker quality or VoiceOver usability.

See the [dated feature record](test-results/2026-10-04-system-status-theme-editor.md)
for focused suites, screenshots, benchmark scope and unverified environments.
macOS 26+ Apple silicon is the target; a newer local test host does not by itself
prove runtime behavior on every supported macOS release or physical display setup.

On Xcode 27, the generated UI runner is sandboxed. The new feature UI fixtures
use `/private/tmp/corta-ui-stages/` so the app and runner can share disposable
configuration files without accessing each other’s protected containers. Create
that directory before the run. For local ad-hoc `build-for-testing`, preserve
the generated runner entitlements and add only a temporary absolute-path
read/write exception for this directory when signing the runner; then run
`test-without-building`. This changes the local runner artifact only, not Corta’s
shipping entitlements. An inaccessible fixture is a setup failure, not evidence
that settings or translations work.

The input-source indicator UI fixtures use the runner’s
`FileManager.default.temporaryDirectory` and pass that isolated stage to the
app. They do not require the temporary `/private/tmp/corta-ui-stages/` signing
exception described above. Toolbar and optional prompt placement are covered
in [the input-source placement record](test-results/2026-10-04-input-source-toolbar.md).
