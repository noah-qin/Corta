# 2026-10-12: battery follow-up for output overhead and focus priority

Scope: four runtime files changed after main `16f0df1849133a99a9fea15a8b62d75377f9f33d`, plus a focused reader-priority regression test. This record captures local pre-commit validation; the follow-up pull request records CI and merge status.

## Functional checks

- Debug app build and 9 RenderOwnershipTests: passed.
- SwiftPM ReaderPriorityTests: 2 tests / 3 parameter cases passed. Both focus-in and focus-out reports preserved background QoS through real PTY echo; ordinary input restored interactive QoS.
- Benchmark builds of the clean main archive and changed workspace: passed.
- Native 2× cursor smoke: default and threaded modes each passed 6 handoffs across light/dark block, bar and underline, with matching solid-Metal controls. Each mode captured 120 transition screenshots; no duplicate cursor column groups, missing replacement or stale cursor beyond the control capture envelope. This was approximately one minute per mode, not a five-minute lifecycle run.
- Temporary native harness removed from the workspace after execution; retained at `/tmp/corta-energy-followup-cursor-harness.swift`. Real 1× hardware acceptance is waived by the user.
- One initial performance invocation could not load its test bundle after the UI plan rebuilt the app. Rebuilding with the Release test plan restored the bundle; subsequent invocations succeeded.

## Battery-powered CPU and wakeup comparison

Both versions use Benchmark / `-O`, `CORTA_RENDER_THREAD=0`, the same isolated fixtures and app-only Activity Monitor attachment. Before is a clean `git archive HEAD` at `/private/tmp/corta-energy-followup-before`; after is the changed workspace. Three pairs per scene, with pair order reversed in round 2. Each trace lasts 24 seconds and excludes its first 6 seconds; cumulative CPU and wakeup differences use the remaining first/last samples (approximately 15–17 seconds). This is a short proxy comparison, not a long-duration battery-life experiment.

`ExternalConnected=false` and `IsCharging=false` throughout every measurement, as reported by AppleSmartBattery. Supply settings were not changed. CPU percentages below describe Corta only, not its child producer; 100% represents one core. The hidden scene uses unrestricted `yes`, not a fixed byte count, so equal completed work is not established.

| Scene | Round | CPU before | CPU after | Wakeups/s before | Wakeups/s after |
| --- | --- | ---: | ---: | ---: | ---: |
| flood | 1 | 111.8211% | 111.8353% | 0.5362 | 0.5373 |
| flood | 2 | 114.1536% | 110.6563% | 0.5432 | 0.2989 |
| flood | 3 | 113.1396% | 115.6387% | 0.3009 | 0.5424 |
| idle | 1 | 0.0211% | 0.0054% | 0.6437 | 0.3811 |
| idle | 2 | 0.0040% | 0.0272% | 0.3184 | 0.5771 |
| idle | 3 | 0.0213% | 0.0055% | 0.5745 | 0.4165 |

Hidden-output CPU was nearly identical in round 1, lower after the patch in round 2, and higher in round 3. There is no consistent paired reduction. Idle CPU remains very low; its paired changes also reverse direction. These results do not prove either energy savings or an energy regression.

Unprivileged whole-machine battery current/voltage estimates were also saved, but fluctuated substantially and include other processes and tracing/runner overhead. They cannot establish Corta power usage. Direct `powermetrics` sampling required an administrator password; it was not run. CPU and wakeup counts are not watts. No battery-life or application-level power-saving claim is supported.

## Optimized frame sampling

Five performance tests ran successfully per invocation. The 120×40 frame measurement includes GPU completion wait. Three same-supply before/after pairs gave:

| Pair | Mean before / after (ms) | p50 before / after | p95 before / after | p99 before / after |
| --- | --- | --- | --- | --- |
| 1 | 0.343 / 0.543 | 0.315 / 0.346 | 0.575 / 2.568 | 0.972 / 2.733 |
| 2 (after first) | 0.320 / 0.381 | 0.299 / 0.346 | 0.545 / 0.602 | 0.868 / 1.233 |
| 3 | 0.310 / 0.329 | 0.292 / 0.305 | 0.528 / 0.552 | 0.937 / 0.839 |

The changed build had higher mean/p50 in these pairs, with a substantial first-pair tail outlier. The measured direct renderer path is unchanged by this patch; these short samples do not isolate the cause or establish a statistical regression verdict. They must not be reported as proof of unchanged performance. The render thread remains opt-in/default-off; this follow-up does not satisfy its energy/adoption gate. No code was changed in response to these measurements.

## Records and boundaries

- `/tmp/corta-energy-followup-results.json`: all 12 scene measurements.
- `/tmp/corta-energy-followup-*-live.xml`, `*-battery.json`, `*.trace`: app traces and battery samples.
- `/tmp/corta-energy-followup-unit.log`, `*-reader.log`, `*-native-{0,1}.log`: focused functional evidence.
- `/tmp/corta-energy-followup-frame-pair.log`, `*-frame-repeat.log`: all paired frame samples.
- `git diff --check` for changed runtime/test files: clean.
- All 22 previously excluded security/configuration/image files retain their saved SHA-256 hashes.
- This round did not rerun the complete test suite or TSan. Prior merged-commit results are not substituted for current-patch verification.

## CI scheduling follow-up

The first CI attempt failed the existing image-upload fixture waiting five seconds for its shared-queue worker to enter. The recovered xcresult confirms that entry wait timed out; the production upload remains outside the cache lock. An unrelated SFTP fixture also observed its five-second hold expire before its assertions. The second attempt repeated the image entry timeout and failed an existing PTY fixture waiting thirty scaled seconds for another shared-queue worker to start. The new focus-priority cases passed.

Use dedicated threads for the image fixture's upload/cache lookup and the PTY poll. Keep image upload held until explicit release, rather than letting a two-second timeout accidentally install the texture before the assertion; bound the lookup from the test thread so a genuine lock regression fails and releases the fixture. Assert observations on the owning test rather than in a foreign thread. Reader-priority tests now await their semaphore through a continuation and an independent waiter instead of blocking the shared test executor. Runtime code and global CI settings are unchanged.

Local verification of this follow-up: 19 app tests in two suites passed; 15 core tests in the reader/PTY suites and the targeted same-destination SFTP case passed. Complete CI is required again on the new head before merge. No energy measurement was repeated because this follow-up changes test scheduling only.
