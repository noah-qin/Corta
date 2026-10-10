# Background verification for #280–#283, October 9, 2026

Baseline `b0917ddf2fd05f8f36159987a565a1f0c9ed5205`; machine and raw numbers
are in [PERFORMANCE §5.14](../PERFORMANCE.md#514-scrolling-without-per-line-screen-allocation-281-283)
and [the raw record](2026-10-09-scrolling-raw.md). No desktop input, application
window, System Settings change or UI automation was used. Builds used two
jobs. The dedicated compile-time `CORTA_HEADLESS_TESTS` host suppresses normal
AppDelegate startup and sets prohibited activation. It was applied to both
before/after hosts; baseline source changes were limited to this startup
suppression, the identical new benchmark harness and `--memory-only`.
Shipping builds do not define this flag.

## Automated results

- `swift test --package-path CortaTerminal -j 2`: passed, 742 terminal-core
  tests in 76 suites, 125 SFTP tests, 22 release-check tests and 13 license
  tests. Golden fixtures were not re-recorded. The SSH fixture-dependent
  tests retain their normal skips; real SSH integration was not run here.
- `corta-fuzz --fuzz 500000 --seed 1 CortaTerminal/Tests/Fuzz/corpus`:
  passed after the final core change, no crash/hang, caps held.
- Headless Unit selection: 41 tests in DamageTrackingTests, RenderPolicyTests,
  CanvasPresentTests, DiagnosticsEnvironmentTests, ImagePlacementScrollTests
  and DocumentationDriftTests passed. The full Unit plan was **not** run:
  its window/focus tests can interact with the desktop.
- Row-address and pre-write capacity reuse, snapshot isolation, trim-copy equivalence, journal
  ordering/overflow/restart and moved revisions passed in the core suite.
- A 400-step renderer oracle checks mixed full/region/history scrolls, cursor
  moves, edits, selection overlays and journal overflow against full rebuilds,
  comparing every instance field, ordering and all per-row counts. Additional
  regressions cover late history marks, edits before live rows freeze into
  history, one exposed region row and zero rebuilt anchored-history rows.
- Two temporary mutations were tested and removed: deleting Y adjustment
  failed instance equivalence; skipping the journal failed the oracle's
  exposed-row count prelude and existing scroll-reuse assertions.
- The policy decision table tests 60/120 Hz × typing × scrolling × thermal
  state × Low Power Mode × window focus. A timer test verifies rearming keeps
  typing active beyond the old deadline and eventually expires. No machine
  thermal/power setting was changed. Critical thermal pressure now also caps
  scrolling; serious pressure is overridden by interaction.
- Kitty region placement and permanent source clipping tests passed. The
  renderer uses cropped UV extent, not a stretched full image. The rule is
  taken from the [Kitty protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/#interaction-with-other-terminal-actions).
- Three alternating Release core and offscreen Metal measurement rounds
  completed. D17 and the new full-text scrolling scenarios are recorded in
  PERFORMANCE. GPU completion is outside each CPU timing window.

Local Xcode builds used scratch derived data and temporary adhoc signing:
`CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual CODE_SIGNING_REQUIRED=NO
DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO`. The production signing settings
were not changed. No build/test failure was weakened into a pass. An early
fixture using short history lines and a region that emptied out was replaced
by sustained full-width text before recording the final render table.

- The normal development build, without `CORTA_HEADLESS_TESTS`, compiled
  successfully with `xcodebuild build -scheme 'Corta (Dev)'`; it was not launched.
- Final DocumentationDriftTests passed after adding these records, and
  `corta-license check` passed for 650 source files. The strengthened pre-write
  capacity regression also passed, distinguishing retained storage from a
  coincidental allocator address reuse.

## Outstanding acceptance at the end of the background phase

The later [authorized desktop follow-up](2026-10-09-input-followup.md) supersedes
this snapshot for Allocations, full Unit, latency and energy results.

| Issue | Remaining gate |
| :--- | :--- |
| #280 | Step 1 scripted/manual glass decomposition, then evidence-led hold/on-demand decisions; #279 external calibration; no input-hold or driver switch/default change implemented |
| #281 | Valid Instruments Allocations call tree; full Unit plan and launched-app D14 |
| #282 | Scripted/manual normal vs Low Power Mode latency; delivered frameInterval at 60 Hz and a 120 Hz panel if available; idle/occluded/flood energy after grace; D14 |
| #283 | Interactive region/history measurement, flood GPU tails and D14 (nvim/less/tmux/htop/images/selection/search); full Unit plan |

The Allocations command-line attempt failed rights authorization (`-60006`)
and could not attach to the target. It produced no valid allocation evidence
and was stopped; no system authorization settings were changed. This is a
system authorization failure, not a successful allocation measurement.

No 120 Hz panel was exercised. The policy's requested range is not proof of
actual cadence. No latency reduction, zero idle wakeups, tearing result or
completion of #280 is claimed. These issues remain open pending those gates.
