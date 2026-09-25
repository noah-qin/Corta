# Testing Corta

[Documentation index](README.md) · [Contributor guide](../CONTRIBUTING.md)

Run commands from the repository root. Use macOS 26.0 or later and an Xcode
toolchain with Swift 6.2 or later. Only released Xcode toolchains are supported.
[CI](../.github/workflows/ci.yml) and [nightly](../.github/workflows/nightly.yml)
pin the same stable release; update both `XCODE_PIN` values together. A failed build is not a failed test run.

## Choose a check

| Change | Automated verification | Additional evidence |
| :--- | :--- | :--- |
| Documentation or GitHub templates | `python3 scripts/check-docs.py`; `DocumentationDriftTests` for `CONFIGURATION.md` | Review rendered Markdown and examples |
| Parser, grid, search or session | Core suite, focused regression test, fuzz replay for PTY input changes | Specification or minimal reproducer |
| AppKit, input, settings or windows | Relevant `CortaTests`, then app suite | Launch the app; record the five-point manual check |
| Rendering or hot path | Relevant rendering tests and app suite | Before/after frame CPU using the same workload |
| Localization or accessibility | Relevant app tests | In-context language or VoiceOver review |
| Packaging or release | `scripts/check-release.sh` against the artifact | Signing and notarization evidence |

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
[`CortaTerminal/Tests/CortaTerminalTests`](../CortaTerminal/Tests/CortaTerminalTests/).
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

Two test plans under `TestPlans/` say what runs where:

| Plan | Contains | Run it with |
| ---- | -------- | ----------- |
| `Unit` | `CortaTests`; `CortaUITests` listed but disabled | `-scheme Corta -testPlan Unit` — the default, and what CI runs |
| `UI` | `CortaUITests` | `-scheme Corta -testPlan UI` — an interactive desktop session only |

`UI` is deliberately not part of the default run: a UI test drives the
keyboard and the frontmost window, so running it takes the machine away
from whatever else is happening on it. It stays *listed* in `Unit` with
`enabled: false` so the target is still built — a compile error in the UI
tests is caught on every run — without anything being driven. Neither CI
nor an offscreen rendering test replaces launching the app.

There is no Release plan yet. Building the test bundle against a Release
app needs `ENABLE_TESTABILITY = YES` in that configuration, because every
file in `CortaTests` uses `@testable import Corta`; that emits
`-enable-testing`, which inhibits optimisation and so changes the very
number a Release measurement is for. Issue #110 settles that trade.

### Which environments can run the render tests

Measured 2026-09-25 (issue #107), by the "Report the runner's Metal
capability" step that now runs on every CI run:

| Environment | Device | `MTLGPUFamily.metal4` | Families |
| ----------- | ------ | --------------------- | -------- |
| GitHub hosted `macos-26` | `Apple Paravirtual device` | **no** | `apple5` |
| Apple silicon hardware (M1 or later) | e.g. `Apple M5` | yes | `metal4`, `apple9`, … |

So the hosted runner runs the ordinary offscreen render tests — it does
have a Metal device — but **cannot** run the Metal 4 suites. Those carry
`.enabled(if: MetalRenderTarget.supportsMetal4, …)`, so a run without the
family reports them as *skipped, with the reason*. Until this was
measured they returned early instead, which is indistinguishable from
passing: every Metal 4 test in `TerminalRenderBackendTests` went
unexecuted on CI for the whole of 1.0 while the job stayed green.

Metal 4 hardware is therefore the only place those tests mean anything,
and there are two ways to get there:

- `.github/workflows/render.yml` — the same test plan on a **self-hosted**
  Apple silicon runner. It is `workflow_dispatch` only, on purpose: this
  repository is public, and a `pull_request` trigger would let a stranger's
  fork run code on the maintainer's machine. Its first step fails the job
  if the machine it landed on does not report `metal4`.
- Locally, before a release: `xcodebuild test -scheme Corta -testPlan Unit`
  on an M1 or later, with the result recorded under `docs/test-results/`.
  The five-point launched-app check (`CONFORMANCE.md` §4.4) is done on the
  same machine and carries the rest of the guarantee.

Once #109 makes Metal 4 the only backend, the hosted runner will not be
able to construct a renderer at all, and *every* render test moves to
those two routes. That is the trade #107 measured and #109 accepts; it is
not a reason to keep a second backend alive.

### The test host cannot reach your own configuration

The Debug configuration builds a separate application — `CortaDev.app`,
bundle identifier `dev.noahqin.Corta.dev` (D22) — and `AppPaths` gives any
bundle whose identifier ends in `.dev` a stage directory. So the test host
reads and writes `~/Library/Application Support/Corta Dev/` and nothing
else: not `~/.config/corta/config`, not
`~/Library/Application Support/Corta/`, not `~/.zshrc`. Nothing has to be
set on the command line for that to hold.

`CORTA_STAGE_DIR` still overrides the choice, which is what stages a
*Release* build for a launched-app check.

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

Never change global hotkeys, secure-input state, shell startup files or
`launchctl` environment variables just to test (D13). Prefer injected
dependencies and per-process environments. Use temporary directories for
fixtures and clean up the resources you create.

## Documentation

```sh
python3 scripts/check-docs.py
```

Checks every local link and image in the repository's Markdown, including
files not yet staged. It does not follow remote URLs or fragments — review
those, and the rendered result, on GitHub or in a Markdown preview.
`DocumentationDriftTests` in the app suite pins `docs/CONFIGURATION.md` to
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
