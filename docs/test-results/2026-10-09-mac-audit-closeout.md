# Mac audit closeout, October 8–9, 2026

This records the Mac follow-up to #277 (`fe0c937`) and #278 (`c777d39`),
not a replacement for their historical Linux audit. Tests ran on the merged
main tree, then on the fixes described below. **Unable to verify** is not a
pass. No system setting, real SSH configuration, shell rc or release key was
changed. All launched apps were development builds with scratch
`HOME`, `CORTA_STAGE_DIR` and `ZDOTDIR`; existing Accessibility/System Events
permission was used without changing it. Test clipboard content was restored
in memory after native paste/copy actions.

## Machine and execution

Apple M5 MacBook Air (Mac17,3), 10 CPU cores, 10 GPU cores, 32 GB RAM;
macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Swift 6.4
(`swiftlang-6.4.0.34.1`). AC power. The actual device probe returned
`device="Apple M5" metal4=true`. Swift 6.2 is not installed.

Logs, xcresults, isolated fixtures and temporary binaries were kept under
`/private/tmp/corta-mac-closeout-20261008`. Hardware identifiers and local
prompt/user details are deliberately omitted from this public record.

Local Xcode commands used `-destination 'platform=macOS'`, scratch
`-derivedDataPath` and distinct `-resultBundlePath` values, with:

```sh
CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM=
```

Benchmark and TSan adhoc builds additionally used
`ENABLE_HARDENED_RUNTIME=NO` on the command line: an unsigned-team test host
otherwise cannot load the Developer-ID-signed Sparkle framework under library
validation. The production project and real signed artifacts retain hardened
runtime. No signing or security system preference was disabled.

## Fixes and release evidence

[PR #292](https://github.com/noah-qin/Corta/pull/292), merged as `8e8716b`,
contains separate commits for checked Sendable immutable state, UI fixture
setup failure instead of skip (and scratch HOME), and a real signed-feed
rehearsal inside a release dry run. Both PR CI jobs passed.

[PR #293](https://github.com/noah-qin/Corta/pull/293), merged as `5173426`
after both [CI jobs passed](https://github.com/noah-qin/Corta/actions/runs/37807099993), contains:

- `ae8574f`: retry a deferred glyph full rebuild only when the atlas did not
  evict; overflow previously forced every subsequent one-cell update to
  rebuild all rows. Metal regressions cover CJK completion and overflow
  followed by a single changed row.
- `21df720`: keep and reuse only the acknowledged contiguous upload prefix.
  The first #293 CI run caught real-server resume corruption from sparse
  in-flight writes. The deterministic sparse-tail regression and 20 repeats
  of the real-server cancellation/resume test passed after the fix.
- `e5bde11`: explicitly order the window requested by identity while app
  activation completes. The existing focus test repeatedly failed on macOS
  27 with the previous shell window ahead of the requested window; it passed
  with the fix. The assertion was retained.

The original [release rehearsal](https://github.com/noah-qin/Corta/actions/runs/37783990828)
passed, but skipped the appcast job. The corrected
[signed-feed rehearsal](https://github.com/noah-qin/Corta/actions/runs/37801755370)
on `8e8716b` passed signing, notarization, both bundle checks and feed checks.
It did not publish a release, tag or feed. Its separate retained appcast
artifact ends with `<!-- sparkle-signatures:` and the verifier printed:

```text
ok    the feed's own signature verifies under SUPublicEDKey (5432 bytes)
```

## #277 security follow-up: nine conclusions

| Item | Conclusion | Evidence and limits |
| :--- | :--- | :--- |
| 1. Release-chain dry run | **Passed; rehearsal gap fixed in #292** | `gh workflow run release.yml --ref main -f dry_run=true`; signed/notarized bundle checks passed before and after stapling. Eight Mach-O files checked: no denied entitlements, hardened runtime, one Team ID, approved dylib/rpath locations, app/exec/decoder arm64-only. No rule was weakened. |
| 2. Apple signing tools | **Passed** | For each actual Mach-O: `codesign -d --entitlements :- --verbose=4`, `otool -L`, full `otool -l` (including LC_RPATH), `lipo -archs`. Same table-C result as 1.1.8, with the additional arm64 decoder. Details below. |
| 3. Signed feed and extraction | **Passed** | Real-key feed rehearsal above; separate locally generated CryptoKit key, loopback feed and temporary adhoc Sparkle host: valid feed found 1.1.9, one-byte feed mutation aborted with Sparkle 1000 / underlying 3002 EdDSA mismatch despite an in-memory failure date 31 days old, ZIP mutation aborted with 4005, “(Ed)DSA signature validation before unarchiving failed”. No release key was used locally. |
| 4. Sandboxed PNG decoding | **Passed within the stated corpus** | Kitty PNG decode and ImageDecoderProcessTests actually ran, including deadline/output caps. Native APC displayed the valid PNG. `sandbox_check(pid, operation, 0)` denied file-read-data, file-write-data and network-outbound for the actual helper (1), allowed them for its parent (0); valid PNG produced 12 output bytes, exit 0, and was reaped. No `sandbox-exec` proxy was used. A broad ImageIO fuzz campaign was not run. |
| 5. Glyph budget / D17 | **Failed, fixed in `ae8574f`; rechecked** | A1 stress output reproduced sustained full-row shaping after eviction. The new test verifies subsequent damage rebuilds only one row. A static 120×40 Retina CJK screen completes across budgeted frames; its early screenshot was partial and later screenshot complete. Same-host 1.1.8/current numbers and sampling are recorded below. |
| 6. App startup / D14 | **Partly passed; Shortcuts UI unable to verify** | Native §4.4 points 1–5 passed. A million-byte DA query stream was interruptible and the pane accepted a follow-up command. AppIntent invalid-file/URL/off-main validation tests passed, but an actual Shortcuts workflow targeting an unreachable mount was not run. Window-by-identity focus failure was fixed in `e5bde11`. |
| 7. Swift 6.2 strict memory safety | **Unable to verify exact requirement** | Only Swift 6.4 is installed. Core and app both compiled with `-strict-memory-safety`; GuardedDescriptor (two copies), SuspendedScreen and AbortFlag now use checked Sendable, followed by recompilation. The [distinct diagnostic inventory](2026-10-09-strict-memory-safety-inventory.md) preserves 6.4 warnings; exhaustive necessary-and-verified versus removable classification on 6.2 remains owed. |
| 8. App Unit TSan | **Passed on the recorded tree** | Command below; zero TSan race reports and zero xcresult runtime warnings. Final TSan: 946 passed, 0 failed, 4 skipped, one expected failure; no race report. This does not replace the requested exact-toolchain memory-safety audit. |
| 9. TCC and forced-quit secure input | **Unable to verify clean-account TCC** | No disposable Mac user account was supplied. Finder automation, camera access and Documents attribution were not attempted with the real user's permissions. Secure Keyboard Entry did release after forced quit: details below. |

### Signature inventory compared with table C

All eight files reported `flags=0x10000(runtime)` and Team ID `646VSJ9K5F`.

| Bundle-relative Mach-O | Architectures | Entitlements |
| :--- | :--- | :--- |
| `Contents/MacOS/Corta` | arm64 | none |
| `Contents/MacOS/corta-exec` | arm64 | none |
| `Contents/MacOS/corta-image-decoder` | arm64 | none |
| `Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle` | arm64, x86_64 | none |
| `…/Versions/B/Autoupdate` | arm64, x86_64 | only `com.apple.application-identifier=org.sparkle-project.Sparkle.Autoupdate` |
| `…/Versions/B/Updater.app/Contents/MacOS/Updater` | arm64, x86_64 | none |
| `…/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer` | arm64, x86_64 | none |
| `…/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader` | arm64, x86_64 | none |

The app's rpath is `@executable_path/../Frameworks`; loads/rpaths remain inside
the bundle or approved system locations. Symlink aliases were not counted as
additional binaries. The denied-entitlement policy produced no false positive.

Sparkle's extraction-start/did-extract delegate notifications fire around a
failed unarchiver operation too; their occurrence was not treated as proof of
successful extraction. The actual rejection was the pre-unarchiving signature
validation error, corroborated by Sparkle's validation-before-unarchiver path.

## #278 local closeout: nine conclusions

| Item | Conclusion | Evidence and limits |
| :--- | :--- | :--- |
| 1. Unit / Metal 4 | **Passed** | `xcodebuild test -project Corta.xcodeproj -scheme Corta -testPlan Unit`. SessionLifecycleTests, GlyphAtlasTests and the suites in SystemEntryPointTests actually executed on Apple M5; they were not the Metal-unavailable CI skips. Final count below. |
| 2. Frame CPU | **Measured** | Release/Benchmark performance plan, exact same Mac/toolchain before and after; see D17 table below. |
| 3. UI plan / fixtures | **Unable to verify; setup handling fixed in #292** | `TEST_RUNNER_CORTA_UI_FIXTURES="$(CortaUITests/stage-ui-fixtures.sh)" xcodebuild test -project Corta.xcodeproj -scheme Corta -testPlan UI` (with separately staged feedback fixtures). Xcode timed out enabling automation mode before any case ran. InputSourceIndicatorUITests and DirectoryCompletionUITests cannot be claimed passed. Missing shared fixture env/config now throws an explicit setup failure, not skip. |
| 4. Session-ended bar | **Native local cases passed; VoiceOver/SSH unable to verify** | Exit 0/1, SIGTERM, Python Ctrl-D, isolated split-pane exit and Quick Terminal exit checked. Last output remains visible, no cursor, native selection/copy, scroll and Find work; New Session presents Cancel/Start confirmation, Close Pane removes the pane. The bar has AXGroup/AXStaticText text and accessible buttons; actual spoken VoiceOver and SSH Reconnect were not verified. |
| 5. Quick Terminal race | **Passed in the staged case** | Five native global-hotkey hide/recall pairs (30 ms into hide), then stable for two seconds; panel remained visible. Test binding existed only in the disposable config and process. |
| 6. Blocked paste | **Passed for interruption; exact latency not measured** | `stty -icanon -echo; sleep 30`, native paste of 131,072 bytes, Ctrl-C, `stty sane` and follow-up marker all completed. Gross Ctrl-C helper-to-marker interval 2.152 s includes focus, event dispatch and follow-up typing; it is not a measurement of SIGINT latency. Real-PTY cancellation unit tests also passed. |
| 7. Font zoom | **No wrong glyphs observed; sustained reclamation unable to verify** | Twelve native ⌘= followed by twelve ⌘−; screenshots preserve Latin/CJK/emoji. RSS 126,112 → peak 127,712 → 127,616 KiB after five seconds: a small fall, not a return to baseline or a long-running Activity Monitor assessment. |
| 8. Remote SFTP/editor | **Unable to verify real host** | No authorized disposable remote host was supplied. Real local `/usr/libexec/sftp-server` tests found resume corruption in CI,
fixed in `21df720` and rechecked 20 times; but do not substitute for the three remote UI scenarios or SSH Reconnect. |
| 9. Brand screenshot | **Updated** | [Ended-session image](../brand/session-ended.png), captured from an isolated public-output shell and composed with the documented brand recipe; asset catalog updated. |

For an interactive `/bin/sh`, bare `kill -TERM $$` is ignored by the shell's
interactive signal disposition and correctly does not end the session.
`exec /bin/sh -c 'kill -TERM $$'` terminates the session by signal 15, which the
bar reports as SIGTERM. Python Ctrl-D returns to the still-live shell and
never shows the ended-session bar.

§4.4 evidence: 80×24 child size with a 704×452-point window; full-size upright
Latin/CJK output, >screenful output across all rows, native paste, zoom,
search and menu actions reach the pane. The ended bar overlays early retained
rows at the top; it leaves the final `LAST-OUTPUT` and logout visible at the
bottom. This pass does not assert restored tabs, full-screen Spaces or IME
composition checks beyond the requested first five points.

## Commands, counts and D17 numbers

SwiftPM and fuzz replay:

```sh
swift test --package-path CortaTerminal --scratch-path "$scratch/core-tests"
"$scratch/strict-core/debug/corta-fuzz" --target osc CortaTerminal/Tests/Fuzz/osc/*
"$scratch/strict-core/debug/corta-fuzz" --target kitty CortaTerminal/Tests/Fuzz/kitty/*
"$scratch/strict-core/debug/corta-fuzz" --target sftp CortaTerminal/Tests/Fuzz/sftp/*
swift build --package-path CortaTerminal --scratch-path "$scratch/strict-core" \
  -Xswiftc -strict-memory-safety
xcodebuild build -project Corta.xcodeproj -scheme Corta -configuration Debug \
  'OTHER_SWIFT_FLAGS=$(inherited) -strict-memory-safety'
```

The SwiftPM groups reported 733 core tests, 125 SFTP tests (124 before the new regression), 9 ReleaseCheck
tests and 22 license tests, all passed. All three checked-in fuzz corpora
replayed successfully. Initial Unit documentation failure was an unrelated
pre-existing untracked draft with host-absolute links; the draft was preserved
outside the scanned tree for checks and restored without modification.

```sh
TEST_RUNNER_CORTA_TEST_TIMEOUT_SCALE=3 TEST_RUNNER_TSAN_OPTIONS=halt_on_error=0 \
  xcodebuild test -project Corta.xcodeproj -scheme Corta -testPlan Unit \
  -enableThreadSanitizer YES -only-testing:CortaTests
xcodebuild test -project Corta.xcodeproj -scheme Corta -testPlan Release \
  -configuration Benchmark -only-testing:CortaPerformanceTests
```

Local path/signing arguments described above were appended. The xcresult
summary counts unique tests, not parameter expansions. The initial clean Unit
and TSan results each reported 944 passed, 0 failed, 4 skipped and one expected
failure. The final Unit pass reported 946 passed, 0 failed, 4 skipped and one expected
failure, including the two new renderer tests. The final TSan rerun also reported 946 passed, 0 failed, 4 skipped and one
expected failure, with zero runtime warnings and zero ThreadSanitizer race
reports. The four skips and expected failure were existing suite conditions,
not the required Metal/PNG cases.

D17 measures CPU preparation plus synchronous GPU completion; its tail is
sensitive to GPU scheduling. The CPU-only upload benchmark is reported too.
The earlier published 0.57 ms figure used a different macOS build and is not
a same-environment regression baseline. The exact 1.1.8 tree (`27be3fe`) was
archived to scratch and rebuilt with this Mac's current Xcode.

| Tree | Frame avg, three runs (ms) | Frame p95, three runs (ms) | CPU-only full rebuild p50 (ms) |
| :--- | :--- | :--- | :--- |
| 1.1.8, `27be3fe` | 0.638 / 0.612 / 0.639 | 0.863 / 0.797 / 0.798 | 0.154 / 0.145 / 0.145 (paired sample) |
| #277/#278, before overflow correction | 0.617 / 0.624 / 0.640 | 0.862 / 0.844 / 0.814 | 0.133 (first run) |
| After overflow/focus correction | 0.627 / 0.749 / 0.659 | 1.869 / 2.936 / 2.155 | 0.135 (first run) |
| Paired 1.1.8, alternating | 0.816 / 0.855 / 0.822 | 3.758 / 3.575 / 3.430 | 0.154 / 0.145 / 0.145 |
| Paired final fix, alternating | 0.776 / 0.872 / 0.822 | 3.467 / 3.533 / 3.999 | 0.158 / 0.154 / 0.133 |

The first two batches average 0.630 and 0.627 ms. The third averages 0.678 ms
(+7.7% against the 1.1.8 batch), with larger GPU-completion tails; a stable
CPU-path slowdown cannot be inferred from that batch alone. The alternating follow-up averages **0.831 ms before / 0.823 ms after**
(about −0.9%); both batches have the larger completion tails. CPU-only ranges
overlap (0.145–0.154 / 0.133–0.158 ms). This paired sample does not show a
stable frame-time regression, and avoids interpreting the earlier GPU wait
shift as a CPU-path change.

A1 fixture: 12,000 distinct `a` plus two combining-mark clusters, then one
ASCII cell rewritten at 60 Hz, with `CORTA_RENDER_METRICS` directed to a scratch
file. At ~five seconds, main-thread `ps -M` sampled 4.0% on 1.1.8 and 36.6%
before the overflow correction. The latter was repeatedly shaping in
`TerminalRenderer.rebuildAllRows`; it did not reach the 600-frame metrics
summary during the 23-second sample. These are samples, not a sustained
cross-machine performance claim. The dense diacritic screenshot is intended
fixture output, not ordinary shell text.

### A1 after the overflow fix

The fixed Benchmark development app was launched in a minimal environment,
activated and kept on screen. With the same distinct-cluster fixture and
one-cell writes at 60 Hz (extended to 3,000 writes to collect steady batches),
main-thread sampling at ~five seconds was **4.7%**, versus **36.6%** in the
pre-fix sample. `CORTA_RENDER_METRICS` produced four 600-frame batches:

| Batch | CPU frame avg | p95 | p99 | Max |
| :--- | :--- | :--- | :--- | :--- |
| First | 0.78 ms | 1.05 ms | 7.32 ms | 26.88 ms |
| Second | 0.65 ms | 0.88 ms | 1.02 ms | 1.13 ms |
| Third | 0.61 ms | 0.86 ms | 1.06 ms | 1.20 ms |
| Fourth | 0.60 ms | 0.87 ms | 0.99 ms | 1.13 ms |

For context, the 1.1.8 first 600-frame batch was avg 2.27 ms, p95 1.22 ms,
p99 143.97 ms, max 261.29 ms. The static Retina 120×40 CJK capture after the
fix showed all rows filled; the Metal regression also requires all 2,400
glyph instances within four updates and no eviction. These results are
specific to the measured font/size and fixture, not arbitrary unlimited atlas
capacity. Early partial-frame screenshots are not evidence of persistent
missing text.

### Secure Keyboard Entry and cleanup

`IsSecureEventInputEnabled()` returned false before launching the isolated
app with `secure-keyboard-entry = true`, true while its window was active,
and false after killing **that PID only** with SIGKILL. The observed release
was within 25 ms after `wait()` reaped the process. No other application's
secure-input state or permission was changed. A process check after PNG tests
found no `corta-image-decoder` process left running; limit tests and the valid
sandbox probe reaped their children.

Native ended-session copy/scroll was repeated using the minimal launch
environment and passed: copy retained the public last-output marker, and
scroll exposed earlier rows plus “20 lines back”. Initial command-injection
and inherited-launch-environment failures were harness failures; only the
successful native key/paste runs are reported as passes.

The latest merged code was also launched after the SFTP fix: native `stty size`
reported 24×80, and retained-output copy/scroll passed again. The final
DocumentationDriftTests run passed before restoring the pre-existing draft.
Both fixture script directories were removed after the app processes exited;
the disposable local Sparkle private seed was deleted. No release artifact,
real SSH key, shell startup file or system preference was modified.
