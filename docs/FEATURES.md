# Features and limitations

[Documentation index](README.md) · [Project overview](../README.md)

This reference describes the development tree on `main`. Published releases
may trail it; changes not yet released are listed under `[Unreleased]` in the
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

## Speed and efficiency

- Measured core-feed throughput of 317.3 MiB/s, with printable runs
  classified 16 bytes at a time with NEON. This benchmark excludes PTY I/O,
  rendering and display; it is not an end-to-end application throughput.
  The screen follows at the display's pace.
- Scroll regions, history scrolling and inserted or deleted lines shift the
  rendered rows instead of rebuilding them; scrolling allocates no screen rows.
- Cold scrollback compressed in memory as it arrives: 100,000 lines of 120
  columns added about 11 MiB of resident memory in the measured workload.
  Search, reflow and copy read history in place; other text and workloads
  can compress differently.
- Typing, paste and input-method text request the panel's maximum frame rate
  (120 Hz on ProMotion); Low Power Mode, an inactive window and thermal
  pressure lower it otherwise.
- A full-screen window with one pane presents directly to the display: about
  a frame less from keypress to glass.
- An idle blinking cursor is animated by Core Animation; an idle shell causes
  no periodic wakeups; a hidden pane's reader runs at background priority
  after two seconds; an occluded window does not draw.
- Glyph atlases and GPU instance buffers sized to what is on screen: a
  24-byte quad, atlases that grow on demand.
- Kitty graphics with direct RGB, RGBA and PNG transmission and placement,
  zlib-compressed or not (`o=z`, what `kitten icat` sends for an image it
  scales to fit). Erasing
  the screen (`clear`, ⌃L, Clear Screen) removes the images on it; erasing the
  scrollback (`clear`'s `ED 3`, Clear History) removes the ones in history — as
  kitty does. An image wholly inside a scroll region moves with it and is
  cropped at its margins; one straddling a margin stays put, as kitty's page
  rule says. Up to 8192 pixels a side and 16 million pixels an image.

Protocol coverage and dated verification results are in [Conformance](CONFORMANCE.md).
Rendering measurements and their conditions are in [Performance](PERFORMANCE.md).

## Windows and navigation

- Split panes, pane zoom, font zoom and restoration of window arrangements
  and working directories. Reopening a closed pane restores its arrangement,
  not the terminated process.
- A full-screen window with one pane is presented directly to the display,
  not through the window server's compositor: about a frame less from
  keypress to glass. A split, or anything AppKit draws over the text, brings
  the compositor back while it shows.
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
  Standard local zsh sessions load the bundled hooks automatically with
  `directory-completion = true`. For explicit startup-file installation in
  zsh, bash or fish, use **Settings ▸ Terminal ▸ Shell Integration**.
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
  always/off modes. The toolbar badge stays while a program runs — Claude Code,
  an editor on the alternate screen; shell integration hides only the
  prompt-placed badge during execution. Private IME modes that macOS does not expose use neutral styling.
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

- **VT conformance is incomplete.** The 2026-10-07 esctest2 run recorded
  131 passed, 334 known bugs and 102 failed out of 567. The historical 82.0%
  figure combines passes and known bugs; it is not a pass rate.
  [Raw results](https://github.com/noah-qin/Corta/blob/f632d5918653cc2feee28fe1baa0c0fd01e93c0e/docs/esctest/2026-10-07-results.txt) retain the failing names.
- **Windowed input latency is above target.** Full screen with one pane
  measured 49.1–50.8 ms p50 and 82.9–84.2 ms p99 for a person typing
  on one M5 MacBook Air with a 60 Hz panel (2026-10-13). Windowed panes
  use the compositor; the full-screen improvement is a measured comparison
  on that setup, not a guaranteed difference on every Mac.
  See [Performance](PERFORMANCE.md) §5.17 for the method and hardware.
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
