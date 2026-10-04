# Cursor settings and window placement — 2026-10-04

## Implementation

- New and cascaded windows are constrained to the current display's visible
  frame after final chrome sizing. Restored windows retain their existing
  validation and overlap-based display selection. Small live windows do not
  use the saved-window fallback size.
- Settings → Appearance offers Block, Bar and Underline, plus an independent
  blink toggle. `cursor-shape` and `cursor-blink` round-trip through the
  configuration file and apply live. Defaults remain block, without blinking.
- DECSCUSR parameters 1–6 temporarily override shape and blinking; parameter 0,
  soft reset and full reset restore configured defaults. The override follows
  alternate-screen transitions.
- A 0.5-second main-run-loop timer redraws the cursor overlay. It stops when
  focus is lost, the window is hidden, scrollback is shown, or the pane closes.
  Output restarts the visible phase. No blink timer runs for a steady cursor.

## Verification

Machine: MacBook Air, Apple M5. Host: macOS 27.0.1 (26A434).
Toolchain: Xcode 27.0 (27A266a), macOS 27 SDK. Deployment target: macOS 26.0.
All fixtures used the development app and disposable configuration and shell
files; no Dock, global environment or user shell preferences were changed.

- 79 focused app tests passed, with no failures or skips: configuration,
  geometry, restoration, theme resolution, localization, cursor rendering,
  settings layout and documentation consistency.
- Two UI tests passed: real startup/cascading/restoration at 500×300 configured
  cells, and live settings persistence plus cursor blinking. A final rerun of
  window startup/restoration passed after adding the small-window regression.
- Exported UI screenshots were visually inspected: the cursor alternates
  between a visible bar and an empty cell, and both new settings fit the form.
  The settings image in `docs/brand/` was refreshed from the disposable stage.
- Left-Dock exclusion and multiple displays, including negative coordinates,
  preferred-display sizing and display removal, were checked with synthetic
  visible-frame geometry. Physical left-Dock and multiple-monitor setups were
  not changed or independently exercised on this host.
- The UI result bundles contain two main-thread responsiveness runtime warnings.
  These runs did not establish their origin; assertions passed.

## Release render measurement

The three `CortaPerformanceTests` passed under `-testPlan Release
-configuration Benchmark` (`-O`, without `@testable`). At 120×40 cells with
Menlo 14 at 1×, full-screen frame CPU time was **0.562 ms average,
0.821 ms p95**, over 60 iterations, below the 4 ms project target.

Instance upload p50 / p95: typing **0.021 / 0.054 ms**; scroll
**0.017 / 0.052 ms**; full rebuild **0.119 / 0.125 ms**.

This is a post-change measurement. No paired pre-change measurement was made
under the same conditions, so it does not establish a performance change.
Blink-enabled idle CPU was not separately measured.

## macOS compatibility inspection

No macOS 27-only runtime requirement or deployment setting was found in the
app sources. The mention of macOS 27 in `TerminalWindowController` documents a
previous full-screen verification. Both Xcode targets and the Swift package
currently require macOS 26.0.

The main obstacles to macOS 15 are unconditional Metal 4 submission in
`Metal4Backend`, including `MTL4CommandQueue` and the `.metal4` GPU-family
check, and `NSGlassEffectView` / `NSGlassEffectContainerView` in the command
palette and search bar. Installed SDK headers mark these APIs macOS 26.0+.
Supporting macOS 15 requires a compatible rendering backend and UI fallbacks,
then compilation and runtime verification on macOS 15. This inspection is
not an exhaustive port or a runtime compatibility test on macOS 15 or 26.
