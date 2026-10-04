# Input-source indicator — 2026-10-04

## Scope

Issue #211: a persistent right-edge input-source indicator, long-command
avoidance, optional prompt-only display and configurable colours. Chinese,
Japanese, Korean and other input sources share the same implementation.

The badge is a native, pane-local overlay. It does not write to the PTY,
change the grid, reserve a terminal column, scroll the child, or switch the
user's input source. It moves only downward during one prompt and hides
when no safe space remains. Input source metadata is read on system
notifications and focus transitions, not on every frame or ordinary key.
Shell prompt readiness and the grid are read under one session lock; an
OSC 133 B on a multi-line prompt is accepted. Without integration, auto
mode falls back to the focused pane. All modes hide in scrollback,
unfocused panes and alternate-screen programs. Native preedit, search and
directory-completion overlays are kept clear.

Settings → Keyboard & Mouse has auto/always/off and direct-input/IME hex
colours. Empty colours use gray direct-input text and a subtle indigo IME tint; custom
backgrounds choose black/white text for contrast. Automatic display requires
an enabled non-Latin layout or IME, using language/script metadata rather
than the user’s region. Changes to enabled sources refresh the policy. Third-party IMEs with private ASCII
toggles use a neutral source badge rather than claiming an unobservable
mode. Config reference, user guide, changelog and all nine locales updated.

## Verification

Host: Apple M5, macOS 27.0.1, Xcode 27.0 (27A266a).

- Full app Unit plan: 800 tests in 129 suites passed, with four reported
  known issues and no unexpected failures. This includes pre-existing
  cursor/window-settings changes in the working tree.
- Full terminal core: 749 tests in 77 suites passed.
- After the last input-event optimisation: 37 focused input-source and
  IME tests passed; 24 focused config/documentation tests also passed.
- Final live UI: three tests passed. Built-in Simplified Pinyin changed
  the badge to 中 without typing, then the test restored the original
  input source. No new input sources were installed or enabled.
- Live child reported 18×60, matching the configured grid. Output longer
  than the screen scrolled normally; history scrolling hid the badge.
- Long input moved the badge down at a fixed right edge; moving the caret
  left did not pull it back. Command execution and alternate screen hid
  it; the returning prompt restored it. A split showed exactly one badge.
- Settings mode and custom colour persisted; opening Settings hid the
  terminal badge. Light and dark native windows were captured, and the
  public demo screenshots were visually inspected for size/orientation.
- Release renderer plan: three tests passed; 120×40 full-screen average
  0.858 ms, p95 3.017 ms over 60 iterations. The offscreen baseline
  excludes AppKit overlay costs; no paired pre-change comparison or new
  idle-CPU/keypress-latency measurement was made.
- Japanese, Korean, Traditional Chinese, known Roman modes and private
  third-party modes were tested with metadata fixtures. Only Simplified
  Pinyin was available for the real CJK-switch test on this host.

UI fixtures use the development app and disposable stage/shell files.
No user shell files or persistent keyboard preferences were changed.
XCUITest emitted existing main-thread/DisplayManager warnings while
assertions passed; they are not a clean runtime-diagnostics claim.
VoiceOver speech, physical multi-monitor layouts, restored-tab replay
and OS accessibility-preference combinations were not manually exercised
for this change.

## Screenshots

- [Chinese badge](../brand/input-source-indicator.png)
- [Long-command avoidance](../brand/input-source-long-command.png)

Result bundles and logs: `/tmp/corta-input-live-final.xcresult`,
`/tmp/corta-input-performance.log`, `/tmp/corta-input-full-unit-2.log`,
`/tmp/corta-input-core.log`, `/tmp/corta-input-ime-final.log`.

## Subtle styling and enabled-language policy follow-up

- Nine focused unit tests passed: Latin-only defaults, non-Latin scripts,
  explicit Serbian script variants, unknown IME metadata, enabled-source
  changes while the selected source remains the same, and manual override.
- Three live UI cases passed across two runs: installed Chinese source
  changes, dark no-integration fallback, prompt/long command/output/settings
  and split focus. The prompt case initially launched without app focus;
  explicit `app.activate()` in the test made its required focus deterministic.
- Logs: `/tmp/corta-subtle-input-tests.log`,
  `/tmp/corta-subtle-input-ui.log`, `/tmp/corta-subtle-input-prompt.log`.
- Fresh Chinese and long-command screenshots replace the former bright pills.

## Unified badge background follow-up

Direct Latin input and unobservable IME modes now use a faint gray rounded
background. Confirmed non-Latin layouts (including Russian and Arabic) share
the subtle indigo style of built-in IME modes. Their accessible descriptions
identify the current source rather than incorrectly calling a known layout
an unknown IME mode. The nine focused unit tests passed again; build/test log:
`/tmp/corta-unified-input-tests.log`.
