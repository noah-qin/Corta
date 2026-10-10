# Issue-by-issue acceptance audit, October 10, 2026

**Historical audit:** the [October 11 validation](2026-10-11-merge-validation.md) supersedes the remaining-gate column below. Sustained default flood and matched-cadence power checks now pass; the three-second timer is identified in Apple AGX setup, and unaccepted no-sync was removed. Absolute zero process counters are a documented platform limit, not a claimed pass.

This audits the original requirements of #280–#283 against the
[full measurement record](2026-10-09-input-followup.md) and
[raw evidence](2026-10-09-input-followup-raw.md). It supersedes a combined
remaining-gates list that made completed core/renderer work appear unfinished.
This audit records the background-only phase, when desktop-disrupting tests
were prohibited. The user subsequently explicitly authorized foreground
testing; the [later foreground follow-up](2026-10-10-foreground-followup.md)
supersedes its runtime/overlay status and records a new verified collision fix.

| Issue | Implementation and evidence | Remaining acceptance |
| :--- | :--- | :--- |
| #280 | Correlated decomposition; no extra first-resume lead, so no hold; mixed Metal display-link prototype rejected after traps; opt-in CADisplayLink driver, rate limit, synchronized-output guard, nil/drop fallback and drawable presentation covered. Three scripted, external and mains human driver pairs show lower latency; D17, Unit and core pass. DisplayLink remains default as the issue explicitly requires when promotion gates fail. | Experimental flood tails fail promotion; default four-pane GPU p99 includes an outlier outside the old range. Render quiescence established, strict zero process wakeups not established. Complete windowed/fullscreen temporal tearing and directory-completion/IME overlay combinations remain unverified. |
| #281 | Row reuse/capacity, snapshot isolation, trimmed history equivalence and unchanged goldens pass. Three Release pairs improve throughput, 200-column/core/parser paths do not regress; same-build memory is 192.4 MB on both sides. Valid Allocations call-tree numbers show no per-line Line/ScreenLines/Scrollback allocation branch, with batch reservation retained. Final package, 500k fuzz, full Unit and D17 pass. | Required implementation/core acceptance is complete; issue remains open until its code is merged. No new desktop test is required for this issue. |
| #282 | Pure 128-case policy table; all input hooks, rearmed one-second grace, critical thermal cap, screen-change reapplication and condition/frameInterval metrics covered. Three scripted and three mains human old/new pairs per power mode recorded. Human low-power median 184.54 → 68.33 ms approaches current normal 69.02 ms. Only 60 Hz is available, so 120 Hz measurement is expressly unavailable rather than a mandatory missing test. | Original scripted low-power and normal latency distributions are not within the same spread and XCTest cadence differs; human result cannot silently replace that literal scripted gate. Idle/occluded CPU is near zero, but final-build flood energy equivalence and complete D14 temporal/overlay checks are not established. |
| #283 | Core revisions/journal ordering, overflow/generation restart, history document anchoring and cached region/history shifts implemented. 400-step all-instance oracle passes; both deliberate Y/journal mutations fail and were removed. Three Release benchmark pairs improve region/history CPU and anchored floods rebuild zero rows. Final D17 overlaps old spread. Native nvim status, less search, tmux split/status, htop, history selection/search and accepted Kitty-in-less placement/movement/crop/removal were inspected. | Required core/renderer acceptance has evidence; issue remains open until merge. Dedicated XCTest history helper run failed and is retained as failed; separate native history/region measurements are recorded with their method limits. Fullscreen tearing is a #280/#282 gap, not an additional #283-only requirement. |

## Corrections to the prior combined checklist

Normal-mode p99 outliers stay in the record, but #282 does not independently
require every normal-mode p99 to stay within the old range. Its normal-mode
non-regression requirement and the separate #280 tail/flood gates must not
be conflated. The measured p50 difference (68.32 → 69.02 ms) is smaller
than the old three-run range (2.51 ms); this does not prove all tails safe.
A missing 120 Hz panel is explicitly allowed by #282. Completed #281 and
#283 implementation/tests should not be described as unimplemented merely
because the combined PR retains #280/#282 gaps.

## Background wakeup review

The former 250 ms PTY stop poll was replaced by an indefinite two-descriptor
wait with a one-byte close signal. Read/write handles are leased through
GuardedDescriptor, close is idempotent and concurrent signaling writes once.
The ownership review and a fresh low-priority background lifecycle run cover
close, descriptor reuse, no leaks and session stop: **20 tests in two suites
passed**. A current-source `CORTA_HEADLESS_TESTS` build suppresses startup and
sets prohibited activation; **42 tests in six suites passed**, including
DamageTracking (the 400-step oracle), RenderPolicy, CanvasPresent, diagnostics,
image placement and GPU feedback. Tests were inspected for foreground/input
actions before selection; no UI automation suite was executed. Logs are
`/tmp/corta-background-final-lifecycle.log` and
`/tmp/corta-background-final-safe.log`, result bundle
`/tmp/corta-background-final-safe.xcresult`. The prior measured
0.4–0.55 process wakeups/s versus 4.7974/s remain measured results; no
new foreground app was launched in this audit.

In source, status metrics have a two-second timer only while enabled visible
clients need it; the measured fixture disabled the status bar. Cursor blink
was disabled, policy expiry is one-shot, and the GPU watchdog only rearms
while submissions remain pending. None is established as the cause of the
residual process counters. Valid signpost exports contain owned activity
over the full trace but zero intervals starting in the accepted 20-second
idle windows; they are not kernel scheduling stacks. Therefore attributing
residual wakeups to a specific framework, or claiming they were fixed by
this review, would be unsupported. A new foreground scheduling trace cannot
be collected under the current no-desktop-automation constraint.

The existing valid trace exports were rechecked by resolving IDs/references,
not by searching unrelated process strings. They contain 236 owned
DisplayLink intervals and 156 on-demand intervals overall, with zero owned
intervals starting in the accepted idle windows. This independently checks
that the absence of idle intervals is not an empty-export artifact.

## Merge disposition

Latest code and measurement CI at `dfee89c` passed all three jobs.
The combined PR remains draft: passing CI does not fill the outstanding
#280/#282 runtime gates. No issue is closed or experimental driver promoted.

Latest foreground retry: the directory ghost/IME overlap was fixed and full Unit now passes 962 tests. Three additional default four-pane pairs still fail GPU tails; CPU/wakeup proxy results and the confirmed blocked reader are in the later record. No completion/merge is inferred.

October 11 merge follow-up: the [final validation](2026-10-11-merge-validation.md) corrects flood sampling before teardown, records three passing sustained default-driver pairs and a final-source check, matches scripted input cadence across power modes, withdraws no-sync, and attributes the three-second idle timer to Apple AGX deferred GPU setup. Historical negative results above are retained with their method limits; absolute zero process wakeups and an unperformed human panel observation are not claimed.
