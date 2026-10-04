# Input-source toolbar placement — 2026-10-04

The default input-source indicator is now a fixed item in the window’s
upper-right native toolbar. `input-source-indicator-position = prompt`
retains the original right-edge overlay and downward long-command avoidance.
Settings → Keyboard & Mouse exposes both placements in all nine UI languages.

The window hosts the focused pane’s existing accessible view; there is no
second source monitor, timer, polling loop, PTY write or reserved grid cell.
Quiet gray/indigo backgrounds, enabled-language automatic visibility,
third-party private-mode neutrality and configurable colors remain unchanged.
Disabled, prompt-placement and Latin-only automatic setups remove the toolbar
slot. Output hides the badge while preserving the slot so it does not shift.

The prompt view is reattached to TerminalView’s flipped coordinates when
switching positions. A grid-size change resets its minimum placement row so
transient geometry cannot pin the badge to a stale row after resize.

## Validation

- Complete app unit suite: 814 tests in 130 suites, with 4 pre-existing known
  issues and no unexpected failures (`/tmp/corta-toolbar-final-unit.log`).
- Live UI coverage: dark no-integration fallback, installed Chinese source
  updates without typing, prompt placement with long-command avoidance,
  fixed toolbar position during typing and caret movement, scrollback,
  execution, alternate screen, position/color settings and split focus.
- UI tests stage data in the test runner’s writable temporary directory.
  Initial infrastructure failures were automation-mode timeout and an
  inherited sandbox-external staging path; both were resolved before final
  verification.
- Screenshots use isolated demo shells. Source switches made by tests are
  restored. Accessibility identity and text are checked by UI tests; a full
  VoiceOver audit and comparative power measurements were not performed.
