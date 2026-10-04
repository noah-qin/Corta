# System status and graphical theme editing — 2026-10-04

Branch: `codex/system-status-theme-editor`.

## Delivered behavior

- Dock/menu-bar exclusion is applied after final sizing of new and cascaded
  windows, as well as restored windows. Oversized cell counts are constrained
  to the selected display's visible frame.
- Appearance settings offer Block / Bar / Underline and an independent blink
  switch. Terminal DECSCUSR overrides remain supported; reset restores the
  user's configured defaults.
- The compatibility baseline remains macOS 26+ on Apple silicon. No macOS 15
  fallback backend or macOS 27-only requirement was introduced.
- Terminal settings offer a bottom status bar, off by default, with independent
  CPU, load, memory, network, disk-free and thermal-state switches. All windows
  share one actor sampler; sampling stops when no enabled bar is visible or
  no metrics are selected. CPU/network values wait for a second sample.
- Network uses one primary or explicitly selected interface and never sums
  physical and VPN counters. Interface changes/reset clear the baseline.
  Memory excludes file cache and accounts for physical compressed pages.
  Disk free refers to the home volume and refreshes every 30 seconds.
- Thermal state uses the system's four severity levels, without claiming a
  numeric temperature. Metrics and host information always describe the local
  machine, including during SSH sessions.
- Clicking the bar opens host name, macOS version, chip, CPU core count,
  installed memory and the selected metrics, with accounting explanations.
- Appearance settings can copy an existing theme and edit a custom theme.
  Dark/light colors, foreground/background/cursor and all 16 ANSI colors have
  color wells and HEX inputs, with a local preview. Save persists and selects
  the custom theme; cancel leaves configuration unchanged. Invalid colors,
  invalid names and concurrent edits to the same theme prevent saving.
- Privacy manifest declarations cover local disk-space display and uptime
  used for elapsed-time calculations. The manifest is included in the app.

## Validation

Machine: MacBook Air, Apple M5. Host: macOS 27.0.1 (26A434).
Toolchain: Xcode 27.0 (27A266a), macOS 27 SDK. Deployment target: macOS 26.0.
UI tests launch the development app with disposable configuration and a neutral
shell prompt. They do not alter the Dock or the global shell environment.

- 109 focused app tests passed, zero failures/skips: native CPU/VM/load/disk/
  thermal sampling, counter deltas and reset, network selection, shared sampler
  lifecycle, configuration round trips, theme save/conflict/color bounds,
  cursor rendering, settings, window geometry/restoration, split trees, font
  zoom, and documentation consistency.
- Seven localization coverage tests passed; all 39 new status/theme keys have
  translations in all nine shipped locales. Together with the focused run,
  116 app tests passed.
- 42 selected core tests and 22 license-header tests passed; the standalone
  license check accepted all 531 tracked files. New privacy-manifest licensing
  is explicitly classified in both the header tool and REUSE metadata.
- Four UI tests passed for cursor blinking/settings, oversized initial and
  restored windows, optional status-bar selection/local details/splits, and
  theme creation/edit/cancel/relaunch. Both new UI tests passed again after
  reducing the theme sheet height and avoiding redundant sampler reset tasks.
- Screenshots were inspected and refreshed in `docs/brand/`: settings,
  theme editor, and system status bar. The editor's Save/Cancel controls fit
  within the default Settings window. Narrow status bars truncate the final
  text; the tooltip and details retain the complete selected values.
- An initialization re-entry crash discovered by the first UI run was fixed
  by resolving configuration before registering its observer. Subsequent
  real launches passed.

## Practical limits

Left-Dock exclusion, negative display coordinates, oversized frames, preferred
screens and removed displays have synthetic geometry coverage. Physical
left-Dock and multiple-monitor arrangements were not changed or exercised.
macOS 26 compatibility was checked through deployment settings and API use;
this machine runs macOS 27, so macOS 26 runtime verification remains external.
Native sampling cannot force thermal transitions or every VPN topology.

UI result bundles contain main-thread responsiveness and QoS runtime warnings;
the passing assertions do not establish the origin or absence of those warnings.
The disk figure is available volume capacity, not real-time disk I/O.
Agent integration and LaTeX rendering remain deferred as requested.

## Release render measurement

The three Release performance tests passed with no failures/skips under
`-testPlan Release -configuration Benchmark`. Full-screen frame CPU at 120×40,
Menlo 14 at 1×, over 60 iterations: **0.656 ms average / 2.310 ms p95**, below
4 ms. Instance upload p50/p95: typing **0.020 / 0.047 ms**, scroll
**0.023 / 0.041 ms**, full rebuild **0.157 / 0.175 ms**.

This is a post-change offscreen render measurement, not a paired A/B comparison.
It excludes native status-bar UI and does not separately measure status-enabled
or cursor-blinking idle CPU. Sampler lifecycle is verified functionally.

## User-feedback follow-up

The user had the older `.build/ui` development app running while the initial
feature tests used `.build/completion`. The normal Run build was rebuilt and
relaunched via `script/build_and_run.sh --verify`; build and process check
passed. No installed production app was restarted.

- Explicit light/dark choices now drive the preview's observable model state
  immediately, rather than depending on later AppKit/store notifications.
- The Appearance preview displays configured cursor shape and blinking.
  Native idle cursor blinking passed the real-window capture test again.
- Settings exposes only System Monospaced. Existing `font-family` values
  normalize to `system`; size remains editable and CJK/emoji fallbacks remain.
- View → Theme editor opens the editor directly. View → Local host details
  and the Terminal settings button open host configuration even while the
  status bar is off. The host value controls carry accessibility identifiers.
- The Corta zsh integration preserves the original Tab widget in emacs and
  viins maps for nonblank commands. On whitespace-only input it inserts four
  spaces. A real interactive PTY test checks two Tab presses and subsequent
  filename completion. This requires installing/updating integration and a
  new shell; user startup files were not modified during these tests. Literal
  output tabs and full-screen-program input retain the terminal protocol.

67 focused app tests passed, including the real zsh test, installer, font
migration, immediate preview, theme/configuration and documentation checks.
Four distinct UI cases passed across the feedback runs: cursor blinking,
theme save/cancel, optional status bar, and the two new menu entrances with
immediate light/dark preview. An initial host assertion incorrectly assumed
selectable SwiftUI text was a static-text accessibility element; stable value
identifiers fixed that locator and the menu test passed on rerun.
Screenshots were refreshed after visually checking the single-font settings
and preview. Main-thread/QoS runtime warnings remain in UI result bundles.

## Compact status bar and localization follow-up

Height reduced from 28 to 24 points, horizontal padding from 12 to 8, and the
separator from three spaces on each side to one. Short localized labels, load
values without slash padding, one-decimal byte quantities and symbolic B/KB/
MB/GB rate units keep all six selected fields visible in the default-width UI
captures. Full labels and numeric precision remain in AX, hover text and details.
Numeric formatting follows the current locale.

All 45 status/theme keys cover all nine shipped locales. Fifteen focused
sampling/theme/localization tests passed. A real UI test launched the app in
both English and Simplified Chinese, checked all six full metric labels, opened
the translated theme editor and host-details menus, and passed. Both screenshots
were visually inspected; the final thermal metric is fully visible. Chinese
and English captures are in `docs/brand/`. The normal development app was
rebuilt and relaunched successfully via `script/build_and_run.sh --verify`.

The app uses standard bundle localization and follows macOS's preferred
language for this app; the user's English screenshot was not missing Chinese
translations. These runs override language only for the test process, not the
user's system or application preferences.

## Cursor controls grouping

Appearance now has a dedicated localized Cursor section containing the shape
picker, independent blink switch and their live preview. All nine translations
for the section title are present. The existing cursor UI test passed again,
including config persistence and visible/hidden cursor captures in a real idle
terminal. Its settings screenshot was visually inspected: the full group fits
the default window and sits separately from font/appearance controls. The normal
development build was rebuilt and relaunched successfully.

## Final documentation and nine-language audit

65 added/changed catalog keys were checked against all nine shipped locales:
English, Simplified Chinese, Traditional Chinese, Japanese, Korean, German,
French, Spanish and Brazilian Portuguese. Every entry is nonempty and marked
translated, with matching format arguments. Input-source validation text now
correctly describes the default style rather than a system color. Catalog
ordering was preserved to avoid unrelated serialization churn.

The real UI localization case passed all nine launches, checked full selected
metric labels, and opened each translated theme-editor and local-host-details
menu. Nine captured bars were inspected for legibility and clipping. This is
runtime and catalog evidence, not a native-speaker review of every sentence.
The 128.75-second run retained existing main-thread/QoS warnings.

The first launches could not read fixtures inside the sandboxed Xcode 27
runner’s protected container. Shared fixtures now live under
`/private/tmp/corta-ui-stages/`; only the local ad-hoc UI runner was given a
write exception for that directory. Tests explicitly select the app beside
their runner. No shipping entitlements or user app/language preferences changed.

The complete terminal-core suite passed 749 tests. The complete app suite
passed 808 tests, with four skipped cases and one expected failure. An initial
pane-zoom run had two obsolete view-list assertions; they now also assert the
same persistent status-bar sibling across zoom/unzoom while preserving the
original tree-detachment and pane-parentage checks. The full rerun passed.
License verification checked 554 tracked files. User tutorials, changelog and
current configuration/design/security/testing/troubleshooting references were
updated; historical release records were left intact.
