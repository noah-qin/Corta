# 1.1.0 audit closeout — 2026-10-01

The 27-finding review is accounted for by PRs #189–#194. #190 was already
merged; #194 integrates #189, #191, #192 and #193, and completes remote-file
opening, dead-client recovery and Quick Terminal observer ownership. Finding
22 was disproved by the original-code background-job test in #189.

## Automated verification

- `swift test --package-path CortaTerminal`: 720 tests pass.
- `xcodebuild test -project Corta.xcodeproj -scheme Corta -testPlan Unit
  -destination 'platform=macOS' -derivedDataPath .build/audit-final` with
  ad-hoc signing: 726 tests pass, 4 expected known issues. The final observer
  teardown change passes the focused `QuickTerminalGeometryTests` (12 tests).
- Release `corta-fuzz --fuzz 200000 --seed 1
  CortaTerminal/Tests/Fuzz/corpus`: no crash, no hang, caps held.
- Independent read-only candidate review found an untracked window observer
  and an editor-before-watch race. Both were fixed, with regression tests
  for repeated close notifications and an editor saving immediately.

## Launched application

The `.build/audit-final` development app was launched with a private
`CORTA_STAGE_DIR` and `ZDOTDIR` in `.build/audit-stage`. No user config,
shell startup file, input source or machine setting was changed. Other
running development instances were identified by PID and left alone.

The stage requested 100 columns, 30 rows and 12-point system monospace.
The live window was 720 × 483 points; its terminal accessibility help read
30 rows by 100 columns, and the child's `stty size` reported `30 100`.
A window-only screenshot showed upright, full-size green text. A 65-line
fixture scrolled to lines 37–65 with the prompt on the final row, filling
all 30 rows. Command-= grew the window to 820 × 513; View → Actual Size
returned it to 720 × 483 with `stty size` still `30 100`. Command-F exposed
one search field and Escape dismissed it. The staged process was terminated
at the end; the user's other app instances were not terminated.

## Limits

The XCUITest runner failed before executing tests, timing out while enabling
automation mode. The controlled launch and menu checks above were performed
instead. Network changes, an unreachable automount, a recycled PID, restored
tab ordering and locale changes were not induced on the machine. The original
PR descriptions retain their narrower unit/static coverage and skipped checks.
