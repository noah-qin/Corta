# Conversation recovery review3 verification — 2026-10-30

This record is a maintainer-requested exception to the usual PR/issue evidence
location in [TESTING](../TESTING.md). Work stays on `V1.6.0`, starting at
`68f417111870fbcf625648220c016e6f4d6db3de`. No PR or push is requested.
The scope is #434/#436 review repairs; #437 remains unimplemented pending the
stage-discovery decision.

## Repair coverage

| Review item | Regression coverage | Implementation commit |
| --- | --- | --- |
| 1: retain UUID source | `failedProbeRetainsVerifiedUUIDOnlyForSameAgentProcess`, `codexClosedRolloutRetainsItsOriginalSource`, contradictory picker/UUID decoding | `9c9d94dd` |
| 2: tcsh startup isolation | `RemoteTmuxTests`' 20 shell/branch cases using tcsh `-f -c` | `e3ad63a8`, lint-only cleanup `bd91c321` |
| 3: process HOME | `ConversationProcessHomeTests`, including a real isolated process and its own record | `9c9d94dd` |
| 4: delayed notice | `hiddenDeletedOrEditedCommandsDoNotGetTheContinueNotice`; unchanged hidden-input cases remain covered by Unit/UI | `4e499ab2` |
| 5: confirmed mixed group | whole-group classification and `confirmedMixedGroupClearsThePersistedIdentity` | `9c9d94dd` |
| 6: success cache / retries / real timestamp | `failuresRetryWithinAFiniteBudgetAndOnlySuccessIsCached`, `realClaude21312ProcStartLiteralMatchesKernelEpoch` | `9c9d94dd` |
| 7: fd-table failure reason | `codexFallbacksExposeReasonsAndNeverGuessANonRolloutFile` distinguishes nil from empty and ambiguous candidates | `9c9d94dd` |

## Environment and isolation

macOS 27.2 (26B123), Xcode 27.1 (27A9275), Apple silicon. Installed versions
queried directly: `~/.local/bin/claude --version` → `2.1.312 (Claude Code)`;
`/opt/homebrew/bin/codex --version` → `codex-cli 0.165.0`. The npm launcher
symlink targets `../lib/node_modules/@openai/codex/bin/codex.js`.

App-hosted tests use the throwaway XCTest stage (D22). UI tests use only the
scratch stage made by `CortaUITests/stage-ui-fixtures.sh`, with an isolated
ZDOTDIR and disabled history. They use the already trusted Corta checkout;
no installed CLI trust/configuration, user shell startup file, system preference, installed
binary, or service is changed. One tiny reply with no tool calls is requested
by the opt-in Unit test. Generated CLI conversations are normal CLI artifacts;
no existing conversation is edited or removed. UUIDs and content are omitted
from this record. Temporary signed fixtures are removed by their tests.

## Real CLI results

The opt-in `CortaSpaceTests/realClaudeAndNpmCodexSourcesSurviveClosingAndReopeningSpace`
passed on the repaired tree. It checks persisted `space.json` metadata against
each pane's observation, independently compares Claude's process-record UUID,
and then closes/reopens the window and checks the unsubmitted command.

| CLI | Persisted kind / source | Observation | Reopened fill |
| --- | --- | --- | --- |
| Claude Code 2.1.312 | `claude` / `sessionRecord` | success; UUID equals the process record | `claude --resume <same UUID>`, no Return sent |
| npm Codex 0.165.0 | `codex` / `picker` | `noOpenFile` | `codex resume`, no Return sent |

Privacy-safe application Logger excerpts, subsystem `dev.noahqin.Corta`,
category `space`, from `/tmp/corta-review3-real.log`:

```text
conversation kind=claude source=picker result=recordMissing
conversation kind=claude source=sessionRecord result=success
conversation kind=codex source=picker result=noOpenFile
```

This demonstrates Claude's enhanced path and npm Codex's baseline. It does
not verify Codex's real `openFile` enhancement or which background app-server
might own a rollout. An observed `noOpenFile` does not prove a file is never
briefly opened.

One warm round over **both Agent panes (all agents in the fixture)** took **0.001306041 seconds
(1.306041 ms)**. Method: in `Task.detached(priority: .utility)`, measure
`SuspendingClock.now` before and after `terminals.map { $0.conversationObservation }`.
The Claude success cache was warm; this is one round, not a latency percentile
or a cold-record measurement. Test printing/persistence are outside the interval.
No sampling or file read was moved onto the main actor.

The `procStart` regression literal `Thu Oct 29 17:27:02 2026` was copied from
the prior Claude 2.1.312 acceptance process record (local run on October 30).
Its independent epoch is 1793294822; only this identity timestamp is retained,
with no conversation content. The regression does not derive its expectation
from Corta's formatter.

## Reproduction

From the repository root, run the focused Unit check with these launch-only switches:

```sh
TEST_RUNNER_CORTA_CONVERSATION_REAL_CWD="$PWD" \
TEST_RUNNER_CORTA_CONVERSATION_REAL_CLAUDE="$HOME/.local/bin/claude" \
TEST_RUNNER_CORTA_CONVERSATION_REAL_CODEX=/opt/homebrew/bin/codex \
TEST_RUNNER_CORTA_CONVERSATION_REAL_HOME="$HOME" \
xcodebuild test -project Corta.xcodeproj -scheme Corta -testPlan Unit \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= \
  -only-testing:CortaTests/CortaSpaceTests \
  -only-testing:CortaTests/SpaceConversationTests \
  -resultBundlePath /tmp/corta-review3-real.xcresult
```

The process-relaunch UI check uses a fresh scratch fixture root, with the same
command-local real CLI switches above plus `TEST_RUNNER_CORTA_UI_FIXTURES`:

```sh
fixture_root=$(CORTA_CONVERSATION_REAL_CWD="$PWD" CortaUITests/stage-ui-fixtures.sh)
TEST_RUNNER_CORTA_UI_FIXTURES="$fixture_root" \
TEST_RUNNER_CORTA_CONVERSATION_REAL_CLAUDE="$HOME/.local/bin/claude" \
TEST_RUNNER_CORTA_CONVERSATION_REAL_CODEX=/opt/homebrew/bin/codex \
TEST_RUNNER_CORTA_CONVERSATION_REAL_HOME="$HOME" \
xcodebuild test -project Corta.xcodeproj -scheme Corta -testPlan UI \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= \
  -only-testing:CortaUITests/CortaSpaceConversationUITests \
  -resultBundlePath /tmp/corta-review3-ui-final.xcresult
rm -rf -- "$fixture_root"
```

The run log is `/tmp/corta-review3-real.log`: 22 tests passed, including the
opt-in real CLI test. These paths are local diagnostic artifacts, not portable
repository links. Choose fresh result bundle paths when repeating.

## Process relaunch and app verification

`CortaSpaceConversationUITests/testRealCLIsFillTheirRecordedCommandsAfterAppRelaunch`
passed on both UI runs. It launches installed CLIs in the isolated Space, reads `space.json`,
requires Claude `sessionRecord` and Codex kind, terminates the app process,
launches it again, and verifies both commands from those saved records.
Claude fills the same UUID; npm Codex fills `codex resume`. Neither line is
submitted. The on-disk source fields were independently inspected after the UI
run: `claude/sessionRecord`, `codex/picker` (UUIDs omitted).

The complete five-case conversation UI class passed, including exact/picker
fills, delete/refill, per-pane menus, hidden-pane notice and app relaunch.
The exported real-relaunch screenshot was inspected: upright full-size text,
both restored commands visible, and the existing Liquid Glass note at the
bottom. These checks drive the launched development app, not an offscreen
renderer. No visual surface or localized sentence changed, so the existing
brand screenshot and string catalog remain appropriate.

D14's full seven-point manual checklist was **not** rerun: exact cell/window
metrics, `stty size`, scrolling through every row, gesture/first-responder
coverage beyond the tested menu/input actions, three restored tabs and the
translated menu bar are unverified in this run. macOS 26, Reduce Transparency,
and VoiceOver were not manually checked. No claims are made about #437.

## Automated results

All commands run from the repository root; the Xcode commands use
`-project Corta.xcodeproj -scheme Corta -destination 'platform=macOS'`
and the command-local signing overrides shown above. No signing setting is
saved to the project or machine.

| Check | Result | Local artifact |
| --- | --- | --- |
| `swift test --package-path CortaTerminal --filter 'ClaudeSessionRecordTests\|ConversationProcessHomeTests\|LocalConversationTests\|RemoteTmuxTests'` | 19 passed; tmux's parameterized test covers all 20 shell/branch combinations | `/tmp/corta-review3-core-focused.log` |
| Opt-in focused Unit (command above) | 22 passed, including real Claude/npm Codex | `/tmp/corta-review3-real.xcresult` |
| `swift test --package-path CortaTerminal` (final rerun) | 1,039 passed, 27 skipped (1,066 reported total); zero failures | `/tmp/corta-review3-core-final.log` |
| `xcodebuild test … -testPlan Unit` (final) | 1,213 passed, 7 skipped (1,220 reported total), 4 expected known issues; zero unexpected failures | `/tmp/corta-review3-unit-final.xcresult` |
| `xcodebuild test … -testPlan UI -only-testing:CortaUITests/CortaSpaceConversationUITests` | 5 passed; zero failures | `/tmp/corta-review3-ui-final.xcresult` |
| `xcodebuild docbuild …` | documentation build succeeded; no warning/error diagnostics | `/tmp/corta-review3-docbuild.log` |
| `swiftlint lint --quiet` | passed, no findings | terminal output empty |
| `python3 -B scripts/check-doc-links.py` | all local Markdown links resolve | terminal output |
| `swift run --package-path CortaTerminal corta-license check` | 879 files checked; every header in place | `/tmp/corta-review3-license.log` |

The Unit known issues are the four deliberate invalid render-target probes in
`MetalRenderTargetTests` (0×10, 10×0, −4×10, 16385×10). Skips include native
authorization, Metal-4-unavailable paths on this Metal 4 machine, extended GPU
stress, the SSH app fixture and the opt-in real CLI check (run separately
above). Core skips include opt-in Claude lifecycle, Release-only allocation
checks, unprepared SSH/tmux fixtures, and the non-ACL-volume fixture. Skips are
not counted as passing acceptance.

The first broad core run had one failure in the untouched
`KittyGraphicsDeferredDecodeTests/sessionPlacesInStreamOrder`: cursor column
26 instead of 13. Its isolated 8-test suite passed on retry; the complete
core rerun passed. This is a transient failure observed during this run,
not proof that the underlying timing problem is fixed. No unrelated image
code or test expectation was changed.

Early repair iterations also exposed a platform-binary HOME-query fixture
limitation and a notice assertion that mistook the layout Undo note for a
conversation note; the final temporary signed-process fixture and exact
conversation-note assertions address those test setup issues.
