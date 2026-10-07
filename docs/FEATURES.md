# Features and limitations

[Documentation index](README.md) · [Project overview](../README.md)

This reference describes **1.1.5** and the development tree on `main` since
it; a feature added after the release is listed under `[Unreleased]` in the
[changelog](../CHANGELOG.md).
Configuration keys and defaults are maintained in [Configuration](CONFIGURATION.md);
the [user guide](USER-GUIDE.md) says where each feature lives and how to use it.

## Terminal and text

- A Swift VT parser with true colour, alternate screens, scrollback, query
  responses, synchronized output and bracketed paste.
- Unicode text, East Asian widths, combining marks and emoji, with Core Text
  font fallback. AppKit IME composition is drawn outside the terminal grid.
- Metal 4 rendering — one render pass per frame — with a glyph atlas, instanced quads and line damage tracking. Needs a GPU with Metal 4: every Apple silicon Mac; not a virtual machine's paravirtual GPU.
- OSC 8 hyperlinks, focus reporting and the Kitty keyboard protocol.
- Kitty graphics with direct RGB, RGBA and PNG transmission and placement,
  zlib-compressed or not (`o=z`, what `kitten icat` sends for an image it
  scales to fit). Erasing
  the screen (`clear`, ⌃L, Clear Screen) removes the images on it; erasing the
  scrollback (`clear`'s `ED 3`, Clear History) removes the ones in history — as
  kitty does.

Protocol coverage and dated verification results are in [Conformance](CONFORMANCE.md).
Rendering measurements and their conditions are in [Performance](PERFORMANCE.md).

## Windows and navigation

- Split panes, pane zoom, font zoom and restoration of window arrangements
  and working directories. Reopening a closed pane restores its arrangement,
  not the terminated process.
- Scrollback search with case-sensitive and regular-expression modes, in a
  find bar that narrows with a split pane and moves to the bottom while the
  cursor or the current match is under it; text selection, copy and export. Clear Screen, Clear History and Reset Terminal
  are separate commands with different effects.
- A command palette (⇧⌘P), configurable shortcuts, themes and a native
  Settings window — a sidebar of eight categories, System Settings style —
  backed by `~/.config/corta/config`.
- Directory navigation and history, shell/directory/environment presets, and
  local `path:line:column` references that can open in an editor.

## Shell and remote work

- OSC 133 shell integration: prompt marks (empty Return has no result mark
  since 1.1.1), command history, command-output
  copy/export, navigation between commands and long-task notifications.
  Install or remove the bundled zsh, bash or fish hooks in **Settings ▸
  Terminal**; they go into the login shell's startup file.
- Built-in directory suggestions for standard local zsh sessions, with
  faint alternatives and inline previews, Left/Right selection and Tab
  acceptance. Up/Down keep command history navigation; Shift+Tab passes
  through. Disable the optional feature in Settings or with
  `directory-completion = false` ([usage](USER-GUIDE.md#directory-suggestions-zsh)).
  Local hooks load without changing the user's startup files.
- Optional command-status rules in the prompt margin, with textual tooltips
  and gray interrupted marks for exit status 130.
- Remote context reported by shell integration, a host indicator and reconnect
  action. SSH connections use system OpenSSH, including its configuration,
  agent and `ProxyJump`; Corta does not provide its own SSH implementation.
- A connect sheet for SSH and SFTP that suggests recently connected hosts and
  the `Host` names in `~/.ssh/config` (read, never executed). SFTP's port comes
  from a `Host` alias; the sheet has no port field for it.
- An SFTP browser for listing, transferring, renaming and deleting remote files
  and directories, with managed local copies for editing: Back and Forward, a
  breadcrumb path, sortable columns, hidden files on request, a row menu, drag
  and drop to upload and to Finder, and transfers in a toolbar popover with
  speed and time left. The first connection to a host in a run requires
  confirmation; a remote report alone cannot open it.
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
- Persistent input-source status (`A`, `中`, `あ`, `한` and other language codes)
  in an independent upper-right toolbar group. Automatic display follows enabled
  non-Latin keyboard layouts and IMEs; Latin-only setups hide it. Settings also
  offer prompt-right placement with long-command avoidance, custom colors and
  always/off modes. Shell integration hides the default badge during execution;
  private IME modes that macOS does not expose use neutral styling.
- Sparkle updates through **Corta ▸ Check for Updates…**, plus an optional
  daily background check.

## Optional system status and graphical themes

- A bottom status bar, off by default, with individually selectable local CPU,
  load, memory, network rates, home-volume free space and four thermal levels.
  Click for host, macOS version, chip, core count and total memory. Windows
  share one sampler; hidden bars stop polling. SSH panes still show local data.
- A graphical theme editor in Appearance settings, with separate light/dark
  previews, color pickers and HEX fields, save/cancel and source-color reset.
  It saves through the existing configuration file; manual editing remains
  supported. Built-ins are copied, while custom themes can be edited.

- View → Local host details and Terminal settings expose host configuration
  even with the bar disabled. View → Theme editor opens color editing directly.
- System Monospaced is the primary font, with configurable size and system
  fallback for missing characters. Legacy font-family names migrate to system.
- Cursor shapes are block, bar and underline, with independent blinking; the
  default is a nonblinking block. Programs retain temporary DECSCUSR control.

## Known limits

- **VT conformance is incomplete.** The 2026-09-17 esctest2 run recorded
  126 passed, 334 known bugs and 107 failed out of 567. The historical 81.1%
  figure combines passes and known bugs; it is not a pass rate.
  [Raw results](esctest/2026-09-17-results.txt) retain the failing names.
- **Input latency is above target.** The 2026-09-18 manual measurement was
  66.3 ms average, p95 78.7 ms. See [the method](PERFORMANCE.md)
  for what is included and the hardware used.
- **Bundled shell integration covers zsh, bash and fish.** Other shells need
  their own OSC 133 hooks for command boundaries; without them notifications
  use a heuristic.
- **Emoji presentation sequences take two columns.** Standardized text-default
  characters with VS16 (⚠️, ✍️, 🖼️) occupy a wide pair, including at a
  line boundary. Programs must count the full sequence, not each scalar.
- **Kitty graphics support direct transmission only.** File-based transmission
  is rejected by design. Animation and Unicode-placeholder placement are absent.
- **Quick Terminal hotkeys use physical key positions**, not characters emitted
  by the active input source. Multi-display placement still needs verification.
- **Prompt marks are not nested.** Inside `ssh` to a host whose shell marks
  its own prompts (OSC 133), the remote commands are recorded as commands of
  their own, the `ssh` command itself is never recorded as finished, and its
  exit status marks the last remote prompt.
- **Remote editing uses managed local copies**, not general directory sync.
  Preserve any local edits before removing Corta's application data.
- **Input and accessibility reports remain open.** A Settings shortcut failure
  has not been reproduced; VoiceOver selection reading needs a follow-up listening
  pass. See [Conformance](CONFORMANCE.md) and [the changelog](../CHANGELOG.md).

Built-in multiplexing, cross-platform support, tmux control mode, built-in AI,
RTL text and terminal title queries are outside the current scope. The rationale
is maintained in [Design](DESIGN.md#6-non-goals) and [Decisions](DECISIONS.md).

Remote-edit uploads check the remote content as well as size and modification
time. Each upload sends the version approved in the prompt. If the local copy
changes after that prompt, Corta asks for a new decision; further saves during
an upload remain pending edits. Managed copies remain on disk with private
file modes. Restored sessions retain arrangement and directory metadata,
with `restore-windows = true` by default, and start fresh processes without
restoring terminal text. See [data-at-rest policy](SECURITY.md#5-data-at-rest).
