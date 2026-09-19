# Features and limitations

[Documentation index](README.md) · [Project overview](../README.md)

This reference describes **1.0.0** and the development tree on `main` since
it; a feature added after the release is listed under `[Unreleased]` in the
[changelog](../CHANGELOG.md).
Configuration keys and defaults are maintained in [Configuration](CONFIGURATION.md).

## Terminal and text

- A Swift VT parser with true colour, alternate screens, scrollback, query
  responses, synchronized output and bracketed paste.
- Unicode text, East Asian widths, combining marks and emoji, with Core Text
  font fallback. AppKit IME composition is drawn outside the terminal grid.
- Metal rendering with a glyph atlas, instanced quads and line damage tracking.
- OSC 8 hyperlinks, focus reporting and the Kitty keyboard protocol.
- Kitty graphics with direct RGB, RGBA and PNG transmission and placement.

Protocol coverage and dated verification results are in [Conformance](CONFORMANCE.md).
Rendering measurements and their conditions are in [Performance](PERFORMANCE.md).

## Windows and navigation

- Split panes, pane zoom, font zoom and restoration of window arrangements
  and working directories. Reopening a closed pane restores its arrangement,
  not the terminated process.
- Scrollback search with case-sensitive and regular-expression modes, text
  selection, copy and export. Clear Screen, Clear History and Reset Terminal
  are separate commands with different effects.
- A command palette (⇧⌘P), configurable shortcuts, themes and native Settings
  backed by `~/.config/corta/config`.
- Directory navigation and history, shell/directory/environment presets, and
  local `path:line:column` references that can open in an editor.

## Shell and remote work

- OSC 133 shell integration: prompt marks, command history, command-output
  copy/export, navigation between commands and long-task notifications.
  Install or remove the bundled zsh hooks in **Settings ▸ Terminal**.
- Remote context reported by shell integration, a host indicator and reconnect
  action. SSH connections use system OpenSSH, including its configuration,
  agent and `ProxyJump`; Corta does not provide its own SSH implementation.
- An SFTP browser for listing, transferring, renaming and deleting remote files
  and directories, with managed local copies for editing. The first connection
  to a host in a run requires confirmation; a remote report alone cannot open it.
- Optional OSC 52 clipboard writes, disabled by default. Clipboard reads from
  terminal output are not implemented.

See [Security](SECURITY.md) for the boundaries between terminal output, local
files, remote connections and child-process input.

## macOS integration

- Open, focus and Quick Terminal Shortcuts actions. These actions do not send
  commands to a shell.
- Quick Terminal with an optional global hotkey, disabled by default. Enable
  it with `quick-terminal = true`, or open it from **View ▸ Quick Terminal**.
- Secure Keyboard Entry under **Shell**, with an indicator of engaged state.
- Sparkle updates through **Corta ▸ Check for Updates…**, plus an optional
  daily background check.

## Known limits

- **VT conformance is incomplete.** The 2026-09-17 esctest2 run recorded
  126 passed, 334 known bugs and 107 failed out of 567. The historical 81.1%
  figure combines passes and known bugs; it is not a pass rate.
  [Raw results](esctest/2026-09-17-results.txt) retain the failing names.
- **Input latency is above target.** The 2026-09-18 manual measurement was
  66.3 ms average, p95 78.7 ms. See [the method](PERFORMANCE.md)
  for what is included and the hardware used.
- **Bundled shell integration is zsh-only.** Other shells need their own OSC
  133 hooks for command boundaries; without them notifications use a heuristic.
- **Kitty graphics support direct transmission only.** File-based transmission
  is rejected by design. Animation and Unicode-placeholder placement are absent.
- **Quick Terminal hotkeys use physical key positions**, not characters emitted
  by the active input source. Multi-display placement still needs verification.
- **Remote editing uses managed local copies**, not general directory sync.
  Preserve any local edits before removing Corta's application data.
- **Input and accessibility reports remain open.** A Settings shortcut failure
  has not been reproduced; VoiceOver selection reading needs a follow-up listening
  pass. See [Conformance](CONFORMANCE.md) and [the changelog](../CHANGELOG.md).

Built-in multiplexing, cross-platform support, tmux control mode, built-in AI,
RTL text and terminal title queries are outside the current scope. The rationale
is maintained in [Design](DESIGN.md#6-non-goals) and [Decisions](DECISIONS.md).
