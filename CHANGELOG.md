# Changelog

All notable changes to Corta are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Breaking changes to the config file format are always listed under
**Changed**, with instructions for what to edit. Corta 1.x follows Semantic
Versioning for compatibility changes.

## [Unreleased]

### Fixed

- **Edit** on a remote file, and ⌘-clicking a `path:line` in a remote pane,
  now check **Settings ▸ Terminal ▸ Open File Command** before connecting or
  downloading. With no editor configured the message says so, offers **Open
  Settings**, and nothing is fetched; a command whose executable is missing
  names the path. Previously the file was downloaded first (up to 64 MiB)
  and the listing then said only "open-file-command could not be run". The
  setting's help no longer claims an empty command opens the default
  application — an empty command disables opening files from output.

## [1.6.2] - 2026-11-10

### Changed

- The status bar is lower and sits on the window's own ground without a
  rule. Local lines up with the terminal text and the metrics share the
  bar's width in steady, evenly spaced columns, whichever are turned on.
  CPU and memory carry a small meter that turns orange and red as they
  fill, labels are quieter than values, network rates drop the interface
  name, and the thermal state appears only when it is not normal.
- A new tab grows open from the end of the row as the track lengthens,
  instead of popping up from its centre, and the selected pill slides to
  it; closing runs that backwards, right to left and a little more slowly,
  and choosing another tab slides the pill there.
- The terminal canvas moves with the tab order: a new tab, or one further
  along, comes in from the right; closing a tab, or going back to an
  earlier one, comes in from the left.
- The `cd` folder suggestions sit on a lighter capsule with a hairline
  instead of a frame, behind a folder mark; the chosen folder is held in a
  soft chip rather than underlined, trailing slashes fade, and a count such
  as +3 says how many more there are.
- ⌘+, ⌘−, ⌘0 and pinch zoom every tab of the window, and a new tab opens
  at the window's zoom, as the documentation already said.
- Resume on a folder transfer continues interrupted files and leaves files
  already there untouched; it no longer overwrites them. Retry on a folder
  that failed part-way skips the files it already sent.
- Regex search refuses only patterns that can backtrack exponentially;
  `(\d+\.)+\d+`, `(foo|bar)*` and similar now run.
- A configuration file larger than 1 MiB is treated as unreadable: Corta
  keeps its settings and Settings says why changes are not saved.
- Opening Settings no longer rewrites the configuration file; it creates
  one only when there is none.

### Fixed

- Settings keeps the lines of a preset it cannot use (a relative shell or
  directory, or an empty one) and of a misspelt theme key in the file
  instead of dropping them or writing out an extra theme.
- The status bar's network interface field saves when it loses focus.
  Shell integration install, update and removal time out after ten
  seconds, and a failure or timeout offers Retry.
- With `scrollback-lines = 0` and on the alternate screen, command marks,
  records, a selection and images stay with their text as it scrolls, and
  an image no longer moves when the window loses rows.
- Clear History on the alternate screen clears the main screen's history
  too, and its confirmation counts those lines.
- Each OSC 5522 clipboard write gets its own status reply, even when
  several finish before Corta reads them.
- Search results are dropped and found again after Clear, Reset, a width
  change, Try Again or Reconnect, instead of highlighting text that moved
  or is gone. Try Again shows when the pane fell back to another shell or
  folder.
- Moving focus from a zoomed pane, or closing any pane while one is
  zoomed, ends the zoom first.
- The secure-input lock shows only on the key window. Choosing the tab
  already shown keeps focus in its search field. A tab behind the selected
  one no longer changes the window's resize steps, and leaving full screen
  no longer makes the window taller.
- Quit while a window is asking whether to close brings that question
  forward instead of asking a second time. The command palette disables
  commands the window would refuse, and beeps if one is refused when run.
- A closed pane's history is freed at once rather than after its process
  has been given time to exit. A launch that could not read the saved
  window arrangement resumes saving it once the file can be read.
- The host-key dialog says whether the question came from OpenSSH or a
  machine on the way, sign-in questions appear only over a terminal or SFTP
  window, and the SFTP drop prompt shows a server's folder name sanitised.
- Go to Parent Directory and Go to Project Root type their `cd` only when
  the shell itself, not a running job, holds the terminal.
- A pipe or device chosen for SFTP upload is refused instead of hanging the
  transfer. SFTP Retry reconnects to the folder that was open, and closing
  an SFTP window with a sheet up beeps and shows the sheet.
- Corta's Application Support folder and render-metrics file are
  owner-only. Launch cleanup also removes leftovers of interrupted saves
  beside the config and shell startup files, approval copies Remote Edit
  left, and an unfinished export's temporary folder after it was moved;
  one it still cannot remove after 30 days is reported once.
- Large pastes are cut into chunks off the main thread. Frames take the
  session lock once instead of several times, command-status tooltips,
  search placement and the idle cursor no longer redo or hold work every
  frame, and a covered window stops polling for its title and the command
  history. Directory history and recent hosts load in the background, zsh
  startup files and drop folders are written off the main thread, and Quit
  waits for all of its last writes together.

- Turning the status bar on or off grows or shrinks the window by the bar's
  height rather than resizing the panes, so the canvas no longer flashes
  and running programs are not resized; in full screen, or without room on
  the screen, the panes still make the room.

## [1.6.1] - 2026-11-07

### Fixed

- Closing a pane, tab, window, or the app asks before ending a live SSH
  connection when close confirmation is enabled. Connect asks before replacing
  a session with running work.
- A second Close during a split collapse closes the tab or window normally.
  Moving a tab into a new window keeps keyboard focus in its terminal.
- An SFTP directory that stops answering now offers a fresh connection.
  Closing a browser with active transfers asks before cancelling them.
  Remote Edit restarts an interrupted managed download and distinguishes
  a stalled transfer from an unreachable host.
- Corta keeps the previous window arrangement after a failed restore and
  shows where it was saved. Layout writes run outside the UI thread.
- Settings reports preset write failures and denied program notifications.
  Shortcut recording checks conflicts with fixed menu keys.
- The terminal draws search highlights and command status marks without
  scanning every offscreen result on each frame. Live resizing reuses
  Metal copy textures across small size changes.
- VoiceOver announces terminal feedback. Tab and Shift-Tab can reach the
  buttons on an ended session.
- After an unexpected quit, Corta cleans up its unfinished terminal exports
  and Remote Edit local copies on the next launch. Completed exports stay
  in place.
- Saving recent SSH hosts and clearing recent hosts or directory history no
  longer block the interface on disk writes. Connections and directory
  visits made during a clear are kept.
- The SFTP browser pages through large directories so opening and leaving
  them keeps the interface responsive. Sorting still covers the whole directory.

## [1.6.0] - 2026-11-06

### Added

- Jump to Next Waiting Pane (⌥⌘J), in Window and the command palette, cycles
  through blocked panes across tabs and windows in waiting arrival order.
- The Agents list, in Window and the command palette, leads with the panes
  waiting for you, in the order they began waiting; the rest follow by urgency.
- Drag a pane's header to rearrange panes: an edge of another pane puts it on that
  side, the middle swaps them, and holding over a tab shows that tab. A preview shows
  where it lands, Esc cancels, and the programs notice nothing until the drop.
- Panes move with their programs still running: ⇧⌥⌘ and an arrow key moves the
  focused pane, Swap Pane exchanges it with a neighbour, and Move Pane to New
  Tab, to the previous or next tab, or to a tab by name takes it out of the tab.
  In the Shell menu and the command palette, and rebindable with `bind.`.
- Three optional split behaviours, all off by default: `auto-balance-panes`
  shares the room equally as panes open and close and keeps dividers you placed,
  `focus-follows-mouse` focuses the pane the pointer enters, and `best-fit-split`
  adds Split Pane Along Longer Side. In Settings; ⌘D and ⇧⌘D do not change.
- Corta has a website, https://corta.noahqin.dev, with the user guide,
  the documentation and the changelog in all nine languages the
  repository is translated into. Each README has a sharp, static screenshot
  linking to its language's homepage video, with a still-image fallback and pause control.
- Kill and Reconnect to Host…, in Shell ▸ Terminal and Connection and the
  command palette, ends an `ssh` or `mosh` that has hung rather than exited and
  runs the same command again as a new connection, once you confirm. Rebindable
  as `kill-and-reconnect-remote`.
- A resumed SFTP transfer you cancelled offers Retry, continuing from the
  partial file it kept.

### Removed

- macOS's own window tabs: Show Tab Bar and the tab overview are gone with
  them. Restored windows bring their tabs back as before.
- Removed Quick Terminal, its settings page, global hotkey and Shortcuts action.
  Existing configuration entries are retired on the next config save.

### Changed

- SSH connections now use the current pane in the initiating terminal window,
  replacing its session without adding a tab. Choose Connect in a new window
  for a separate window; a
  connection with no available terminal window creates one. Recent host selection
  uses a blue highlight with the same corner radius as its card, and connection
  buttons have capsule borders.
- Contributor layout: group window, remote, settings, terminal-core sources
  and app tests by responsibility; name the pane controller
  `TerminalPaneViewController` and centralize app-test fixture paths.

- Dropped-file copies clean themselves up instead of staying until removed by
  hand: a copy goes when its pane closes or Corta quits, and what a crash left goes
  at the next launch. **The first launch after updating removes every copy older
  versions kept**, so save anything you still need from
  `Application Support/Corta/DroppedFiles` before updating. Their size and
  Clean Now are in Settings ▸ Privacy & Security ▸ Local Data. A file dropped from
  Finder is used where it is and is never removed.
- The documentation no longer says Claude Code is the only CLI whose task
  state Corta shows: Codex 0.166.0 reports its own, through the same general
  parser. What was and was not checked is in the user guide.
- Settings gains controls for `agent-status`, `notify-from-programs` and
  `agent-processes`, in General's section now called Notifications & Agents, and
  for `paste-warning`, in Keyboard & Mouse. The bottom status bar's settings move
  from Terminal to Appearance.
- The user guide, features page and configuration reference name the Settings
  pages as they are since that move.
- A copy is confirmed by a band of light sweeping along the copied text
  instead of a "Copied" toast in the corner; with Reduce Motion it is a
  single soft flash, and a copy scrolled out of view keeps the toast.
- Tabs are Corta's own and sit in the titlebar row beside the window
  buttons, titles left-aligned (D30, #451). Each tab shows the program
  running in its focused pane as an icon — a dark prompt tile for a shell,
  the program's own colours otherwise — and a tab with split panes fans
  the other panes' icons out behind it, like a hand of cards. Hover for the close
  button, drag to reorder, double-click to rename; the right-click menu
  adds Close Other Tabs. The row beside the tabs drags the window and
  double-clicks like the rest of the titlebar. Tabs keep a fixed width at the leading edge and
  share the row only once they no longer fit; past that the row scrolls
  sideways, fading at its edges, and keeps the selected tab in view, so every
  tab keeps its name and close button. A new tab springs in. Opening or closing a
  tab cross-fades the canvas: the old one stays until the new one has drawn
  — a new shell's prompt included — so no empty frame flashes between them. A lone tab is a single pill,
  and the track appears with the second tab. Codex's tile is white. The titlebar band and the
  gaps between panes share a ground colour a step darker than the panes,
  and the tab track a step darker again. The default light theme's background is
  pure white (was a warm off-white). Pane cards come up to within a margin of the
  tabs, and their corners are concentric with the window's. A tab's background panes stop drawing while it is
  hidden and keep running. A narrow tab keeps the start of its name, fading
  out, and the Connect and New Tab buttons answer the pointer as the tabs do.
- Tabs move between windows with their panes still running: drag one off
  the strip into a window of its own or onto another window's strip, or use
  Window ▸ Move Tab to New Window (also in the tab's menu) and Merge All
  Windows. ⌃Tab and ⇧⌃Tab step through the tabs, as before; a closing tab
  shrinks out while the others and the track close the gap, and a dragged
  tab held at a scrolling strip's end carries the row along.
- ⌘1–⌘8 show that tab and ⌘9 the last, from File ▸ Show Tab; each is a
  command of its own (`select-tab-1` … `select-tab-8`, `select-last-tab`)
  that `bind.` can move or clear.
- The titlebar band is the theme's own colour, without the window title or
  a separator line, and the toolbar's Connect and New Tab buttons are bare
  symbols. In the toolbar, the input-source badge is grey for every source.

- Light and dark mode choose their themes separately: Settings ▸ Themes
  keeps a choice per mode, written `theme = light:<name>,dark:<name>`; a
  single name still serves both. New beside a mode saves the theme for
  that mode.
- Switching theme or appearance blends the window into the new colours
  over a fifth of a second instead of jumping, titlebar and terminal
  together.
- The `corta` and `mono` themes' colours were retuned: every hue in both
  variants now reads at 4.5:1 or better on its background (the default
  dark theme's blue was 1.9:1). Solarized is unchanged, as published.
- Settings: the shortcut keys line up in one column, the sidebar's groups
  are evenly spaced, the Shortcuts search field matches the sidebar's, and
  setting names use one capitalisation.
- The bundled updater is Sparkle 2.10.1 (was 2.10.0).
- `link-activation = click` opens URLs only. A `path:line` takes ⌘-click under
  either setting, since it starts your editor.
- A window resize over a long scrollback no longer stalls frames: the reflow
  runs outside the lock they need.
- A tab behind another stops drawing under steady output, and draws what it
  missed when shown.
- A very large image can now be refused sooner: its whole decoding peak has to
  fit in the pane's image budget.
- An SFTP browser connection that does not answer fails after 30 seconds per
  step of connecting and can be retried. The time a sign-in dialog is on screen
  does not count, in the browser or in remote editing.
- An SFTP sign-in dialog now always says its question may come from OpenSSH or
  the server.

### Fixed

- README screenshots keep their aspect ratio in narrow GitHub columns and
  use the original high-resolution PNG for crisp text.

- Closing a split pane smoothly collapses its gutter and prepares the final
  terminal size before the transition, avoiding a second reflow at the end.
- Opening and closing tabs moves and fades their entire terminal content,
  including text, while preserving the existing tab-label animation.
- Settings search has more space above the category list; sidebar width and
  category text retain their original layout.
- The pane-header zoom control appears on hover or keyboard focus, remains
  available to VoiceOver, and is hidden when there is only one pane.

- A pending local file-reference check that fails or times out abandons the
  click instead of opening an unconfirmed remote file or another fallback.

- Hovering over empty or ordinary text keeps tracking the resting pointer, so a
  link that later appears there gets its tooltip without another mouse move.
- An SFTP connection is not failed by a cancelled deadline that has just reached
  its last tick, including when a successful answer cancels it at that boundary.
- A new shell prompt now ends a pane's reported Working and Waiting states, also in
  the Agents list, the Dock count and ⌥⌘J's queue, even when the shell sent no
  command-finished mark. Done and Failed stay.
- OSC 7501 follows the Program Status Protocol in more cases: an unknown `kind` no
  longer drops the report, paths such as `task/1` are accepted and `clear` removes
  everything beneath them, a new subtask past the limit replaces the stalest instead
  of being refused, and spaces around fields are ignored. The differences that remain
  are listed in `docs/CONFORMANCE.md`.
- A second file drop on a pane still receiving the first now says the first was
  cancelled, and a drop that cannot start no longer cancels it.
- ⌘Q no longer hangs after an SFTP row has been dragged. On the way out the app
  waited for a file promise nobody could keep.
- An edit to the config file is picked up within about a second even while something
  keeps writing in the folder that holds it. Each write used to put the reload off again.
- An SFTP row dragged out leaves nothing behind once its file is handed over, and a
  failed one no longer offers a Retry that could only fail.
- Holding an SFTP row over Finder no longer freezes Finder. Merely hovering
  started the download, twice, and Finder waited on it, sometimes until Corta
  quit, and the drop could deliver nothing. The download now starts once, when
  you drop.
- File drops on terminal panes and SFTP listings negotiate by type without
  triggering lazy downloads while hovering. Promised files are received
  asynchronously, with a deadline and visible failures. Pane drops are bound
  to the session and foreground process group at release; Corta's own SFTP
  rows are refused by panes.

- Agent navigation and notification clicks reveal panes hidden by another
  pane's zoom and select the target pane in hidden tabs and other windows.
- Agents menu and palette entries show Corta-owned names and fixed labels,
  excluding program-supplied app/title text. Equal-urgency task states use
  a stable slot-ID tie-break.

- A long task or a program's notice in a tab behind the one you are looking
  at reaches you: tabs share a window, and being in the key window counted
  as being watched. A shell's report of a command ending no longer waits for
  the tab to be drawn.
- Moving a tab while it fades out after ⌘T no longer leaves it blank in its
  new window, and a click during that fade reaches the new tab, not the old
  one.
- With two or more tabs open, Corta no longer keeps waking to read process
  details after output has stopped.
- A double-click on a tab's × closes that tab, not the one that took its
  place. A tab whose agent reports a status says so in its tooltip and to
  VoiceOver again.
- A tab dropped over a window now lands in the frontmost one under the
  pointer, never in a covered window or one on another Space; a window asking
  something in a sheet keeps its tabs through Merge All Windows.
- A background tab's reader drops to background priority as soon as the tab
  is left, and the window resizes by the cells of the tab in front.
- Move Tab to New Window's windows no longer come back at a stale saved size.
- ⌃Tab leaves the key alone when you have bound it to a command, and when
  there is only one tab.
- Settings' sidebar answers the arrow keys after a click, and its search
  finds what the Appearance and Themes pages now show.
- The website has its own "Page not found" page, a language switcher that
  fits a small phone in German, and selected code that stays readable.
- Gemini's tab tile showed only a dot, and Java's orange tile read as Claude's
  while `java` started: Gemini's star is drawn whole, and Java shows a cup on
  Java's blue. A program's icon now appears only once it takes the terminal
  (a REPL, an editor, an agent); a command that only runs and prints keeps
  the prompt tile. Kimi, Copilot, Goose and SQLite tiles take their brands'
  colours.

- After a theme or appearance switch the selected tab kept the old
  theme's fill — a white pill on a dark titlebar — and the pane header
  kept its old text colour until the next output.
- Splitting a pane again while the previous split was still opening
  crushed the new panes to a sliver, and the crushed layout was saved and
  restored. A split now settles first; ⌘D / ⇧⌘D beeps instead of making a
  pane smaller than its minimum; and a restored layout keeps every pane at
  least that size.
- Claude Code installed by its native installer showed as "2.1.316" with a
  plain terminal icon: it runs an executable named after its version
  (`…/claude/versions/2.1.316`). A version-named process now reads as the
  tool whose `versions` directory holds it, in the title, the tab and the
  pane header.
- A large paste no longer freezes the window: past 64 KiB it is checked in the
  background, a newer paste replaces one still being checked, and most text is
  checked far faster. A paste past 64 MiB is refused with a notice.
- Text judged safe because bracketed paste was on is asked about again if a
  program turned it off while the warning was open, and is never sent unmarked
  with its line breaks unasked.
- A confirmed paste or drop no longer lands in a session started since it was
  asked for.
- A click in a split pane with its search bar open, while the keyboard is in
  another pane, now takes the keyboard back.
- A link's click opens only what its tooltip names; if output changed the text,
  the tooltip updates and the click does nothing. Tooltips follow output under a
  resting pointer.
- A `path:line` still being checked when the shell changes directory no longer
  opens a different file.
- A menu change that could not be saved (theme, appearance, Secure Keyboard
  Entry) now says so, and Secure Keyboard Entry no longer reports success.
- A launch no longer waits on saved directories on a mount that stopped
  answering, and a config file on such a mount no longer stalls the app:
  settings stay as they are, saving is refused, and it is read again when it
  answers.
- `cd` and history Run wait for a paste still on its way, so their Return cannot
  run it.
- Input methods and text replacements can no longer commit control characters,
  and committed line breaks take the paste warning. Losing focus mid-composition
  also cancels the composition in the input method.
- An image that failed to decode for lack of memory or a helper that could not
  start is tried again rather than lost until sent again, and an upload stuck on
  the GPU no longer stops other panes' images.
- Compressed Kitty images under 64 KiB of base64 no longer stall frames, and a
  large image now takes far less memory while it decodes.
- Through a `ProxyJump` or `ProxyCommand`, an SFTP password or host-key question
  from a machine on the way named the final destination as asking. Its dialog
  now says an intermediate step is asking, and that the fingerprint is not the
  destination's.
- After a remote-edit re-download failed, later saves to that file no longer
  prompted. It now says so and asks about the conflict again; a save made while
  a re-download runs is kept instead of the download.
- The SFTP browser no longer reads local file details on the main thread: a
  network volume that stopped answering froze the app before a transfer started.
  That row now fails after five seconds with Retry.
- Cancelling an SFTP transfer still in pre-flight or looking for a Keep Both
  name stops what it was asking, and going to another folder cancels the listing
  it replaces. A row can no longer stay on Cancelling for good.
- An SFTP sign-in dialog now closes when its connection's `ssh` is gone or the
  window it hangs on closes, rather than waiting on nobody.
- Text an SFTP server chose — a STATUS message, a file name, a path, a banner —
  reaches confirmations and error lines with control and concealing characters
  replaced, and bounded in length.
- Remote file names that differ only in case take turns as transfer
  destinations, and connections to one machine under different users or keys
  share those turns.
- OSC 5522: a clipboard write that sanitising leaves empty now answers a fixed
  `status=EIO`, so a client no longer waits forever for its status.
- Kitty graphics: any delete command now aborts an unfinished chunked upload, as
  the protocol requires, and releases what it held.

### Security

- State directories are created owner-only, state files are tightened as they
  load, and copies left by a save that died are removed at launch.
- Opening a file from output can no longer fall through to LaunchServices; the
  unused path is gone.
- OSC 7: a remote host outside the `RemoteHost` character rule is ignored, and a
  path from any working-directory report is ignored if it holds a C0, DEL or C1
  control or passes 1,024 bytes. Every label showing a reported host or path
  replaces controls and format characters.
- `corta-image-decoder` now ends itself after 15 seconds, so a decode stuck when
  Corta is killed no longer leaves it running.
- `corta-exec` is only ever run from `Contents/MacOS` inside the app bundle.
- The update-feed workflow no longer runs any code from a release tag's tree in
  the job that can reach the signing key, and refuses a tag not on `main`.
- `corta-release-check` now fails an app whose `SU*` `Info.plist` values differ
  from `Sparkle-Info.plist`.

## [1.5.1] - 2026-10-27

### Changed

- About Corta opens in the middle of its display, as other apps' About
  windows do, instead of over the window it was opened from. Command
  History still opens centered over its window.

### Tests and tooling

- SwiftLint now reports nothing over the project's sources, tests and
  scripts (1,813 findings before). Each rule kept or adjusted in
  `.swiftlint.yml` says why; the generated `CharacterWidth.swift` is
  excluded, and the pane controller's file length is judged by
  `docs/DESIGN.md` §4.1 instead. Long functions and types were split into
  named steps, extensions and `Type+Area.swift` files, tuples became named
  types, and `try!` became thrown or reported errors. Behaviour is
  unchanged; the frame-CPU baseline is at parity.
- The build has no compiler warnings, and Periphery's two scans read
  together report no dead code: unused imports, an unused sort overload,
  the canvas `clearColor` and an unused clipboard accessor are gone.
  `docs/TESTING.md` explains the package scan on a toolchain whose SwiftPM
  builds with `swiftbuild`.

## [1.5.0] - 2026-10-26

### Added

- Terminal compatibility: title save/restore, live dark/light reports, coloured
  single/double/curly underlines, XTGETTCAP capability answers, and Neovim's
  underline-style probe. Programs can set/query/reset selection colours and
  restore default text, background and cursor colours to the live theme.

- Built-in history suggestions for standard local zsh: type a command prefix
  to see the most recent matching suffix faintly, accept with Right/End or
  dismiss with Esc. Tab and shell history navigation stay native. Enabled
  by default, configurable with `history-suggestions` and a Terminal settings
  toggle; yields to zsh-autosuggestions and leaves startup files unchanged.

- OSC ecosystem coverage (#411): iTerm2 inline PNG/GIF first-frame images,
  multipart transfer, host/cwd, marks, clear history, cursor, attention and
  clipboard extensions; VS Code shell-integration marks; ConEmu prompt marks;
  kitty colour, pointer and bounded text clipboard protocols. A tested OSC
  verdict table records implemented forms, no-ops, refusals and limits.

- Claude Code task-state integration on native tabs and the Dock, with a
  pane-jumping Agents list in the command palette and Window menu. Claude
  Code is currently the only CLI with a dedicated task-state integration;
  other tools have process detection and generic protocol support only.
  OSC 7501 status,
  OSC 9/777/99 notifications, OSC 9;4 progress and OSC 21337 tab metadata
  are bounded and sanitised. Background attention uses fixed Corta text;
  program notices are labelled pane messages and coalesced per pane. Claude
  Code’s `done` signal is distinct from idle; process-only detection shows
  unknown state, and ordinary messages or bells do not imply permission or
  completion. Tab indicators remain centered when the native tab strip
  resizes their accessory. Delayed program notices do not repeat an already
  announced wait for permission, and notification authorization includes Dock
  badges.

- Right-click a pane to find text, copy the clicked command’s output, or
  open/copy a link or file reference under the pointer.
- Paste warnings for shell pipes, sudo, recursive forced deletion,
  backslash continuations and concealed Unicode characters, including with
  bracketed paste enabled. Review a visible text preview, cancel, or suppress
  warnings for that pane; `paste-warning` selects `dangerous`, `always` or `off`.

### Fixed

- Clear Screen (⌘K) immediately keeps a ready integrated shell's prompt and
  unsubmitted input visible, with the editing cursor intact. Multiline
  prompts, wrapped input, wide characters and deferred wrapping keep their
  cell data. No keystrokes are sent to the child and no command is executed.
  Scrollback is kept; Clear History and Reset Terminal keep their separate
  roles. Alternate-screen applications and editors taller than the screen
  are left intact.
- About and Command History open centered over the invoking window, within
  the current display's usable area. A window already open stays where the
  user put it. Command History uses a fixed size to keep its filters usable,
  and shows a localized empty state and command count.
- Rounder Liquid Glass across Corta's floating surfaces. Connect to Host
  (and the file browser's host step) has a glass capsule host field, a large
  Terminal / Files switch, glass cards for Advanced and suggestions, and glass
  Cancel / Connect buttons. The command palette is rounder with a search
  glyph and soft row highlights; Command History has a glass search field,
  toggles, row buttons and results card; a pane's stopped/failed card is glass
  with glass buttons; directory candidates sit in a glass capsule. Connect to
  Host is never taller than its window: in a small one it scrolls.
- Stopped and failed session panels are centered in their pane, with the
  primary recovery action still receiving keyboard focus. Connection labels
  use Host and Open in consistently across the terminal and file browser.

- In zsh vi insert mode (`bindkey -v`), Esc over a history or directory
  suggestion now dismisses it and enters command mode in one press.
- A finished-command mark printed by a live full-screen program, such as a
  log viewed in `less -R`, no longer turns off its bracketed paste or
  keyboard protocol; a crashed program's shell still ends the command at
  its next prompt.
- Paste warnings also catch a shell fed without a pipe: `bash <(curl …)`,
  `source <(…)` and `sh -c "$(curl …)"`. Very large warned pastes preview
  their first 64 KiB instead of stalling before the dialog.
- Typing past the end of zsh history no longer rescans the whole history on
  every key while history suggestions are on.
- Eight unfinished kitty (OSC 99) notifications no longer block every later
  one for the rest of the session; the stalest incomplete message is dropped.
- The command palette no longer selects an agent pane by default, so Return
  runs a command; agent matches sort after commands while searching.
- Moving the mouse no longer resets the cursor on every move, which fought
  the split divider's resize cursor; a program-chosen pointer shape is kept.
- Copy Command Output is disabled on the alternate screen, where it could
  copy an unrelated earlier command's output.
- Clicking a notification from a pane that has since closed brings its
  window forward instead of doing nothing.
- The cursor image used for the caret follows program cursor and colour
  changes (OSC 10/11/12) like the live cursor.
- A refused or failed kitty clipboard write (OSC 5522) now replies with a
  fixed `EPERM` or `EIO` status, so a waiting program does not hang.
- Marks set with iTerm2's `OSC 1337;SetMark` are now stops for Previous /
  Next Command (⌘↑ / ⌘↓), even without shell integration.
- Closing one kitty notification no longer discards another program notice
  that arrived just before it.
- A program's wait for permission after a terminal reset (RIS) is announced
  again instead of being taken for the wait already announced.
- A selection colour set by a program (OSC 17, kitty OSC 21) keeps the
  theme's translucency, so box drawing and underlines inside the selection
  stay visible.
- With `directory-completion = false`, `cd ` input now gets history
  suggestions instead of no hint at all.
- An iTerm2 inline image is limited to 4096 cells across and down, as kitty
  placements are.
- Spaces typed after underlining ends no longer keep an invisible underline
  colour, which kept them from being trimmed as blank.
- Directory candidates now appear in a compact, bordered panel beside the
  input, flipping above it near the bottom and staying within the pane's
  horizontal bounds. The panel no longer paints a full-width strip over
  previous output; inline previews and terminal row counts are unchanged.
- Clear stale agent waiting, subtask and progress metadata at reported shell
  command boundaries after an abrupt CLI exit, including a CLI left on the
  alternate screen. Preserve explicit completion
  on clean exit; interruption is Idle and a known failed exit is Failed.
- Cancel resolved fixed attention notices, recheck visibility before delivery,
  and deduplicate BEL and kind changes within the same waiting episode.
  Generic bells cannot overwrite a pending program message; late cancelled
  submissions finish before replacement delivery.
- Reserve a main status slot alongside 32 subtasks. Keep generic OSC 21337
  decoration separate so it cannot hide Done or compete with typed state.
- Match development and acceptance version Claude Code 2.1.310 in captured
  wire regressions. Document the supported task states and notification
  channels, actual sending conditions, unsupported features and verification
  limits; other Claude versions are not guaranteed.

### Tests and tooling

- Regression checks now assert visible prompt/input cells and cursor state
  after Clear Screen, plus continued editing in real shells. Local zsh
  completion is verified through three consecutive directory levels;
  no completion defect was reproduced and its logic is unchanged.
- Limit the existing SwiftLint source inventory to project sources and
  scripts, excluding generated build trees; no lint cleanup is included.

## [1.4.0] - 2026-10-22

### Added

- The project overview, the user guide and troubleshooting are now available
  in every language the app speaks: Simplified and Traditional Chinese,
  Japanese, Korean, German, French, Spanish and Brazilian Portuguese. A
  language bar with flags at the top of each switches between them, and each
  translation says which English version it follows.

### Changed

- Run PNG decoding in an independently signed App Sandbox helper app,
  replacing the deprecated runtime sandbox interface.

- A pane whose session ended, whose connection dropped or that stopped
  working now shows one panel over its dimmed output, which stays
  readable — and, once the session has ended, selectable: what ended and
  how in a sentence — a dropped
  ssh connection names its host and explains exit code 255 — with the
  raw reason under **Details**. **Reconnect** and **New Session** start at
  once; the panel says the output is cleared, instead of asking again.
  Settings… is offered only where a setting can be the cause.
- **Connect to Host** replaces the separate SSH and Remote Files sheets:
  one toolbar button, a Terminal / Files switch, the user, port and key
  under Advanced, and recent hosts with their port, key and when they were
  last used — forget one with its ✕ or its menu. Hosts that only take git
  (`github.com`, a `Host` with `User git`) are no longer suggested. From a
  remote pane the sheet offers that host's files first.
- The SFTP password dialog says once whom it is for, names what the field
  wants (password, passphrase or answer), and its Cancel reads **Cancel
  Connection**. A failed SFTP connection says why — sign-in refused, host
  unreachable, host key unknown or changed, no SFTP — with **Try Again** and
  **Edit Connection**, and ssh's output under Details.

### Fixed

- Discard cancelled or superseded font scans and SSH host suggestions.
- Rebuilding Corta reuses one Metal pipeline archive path instead of adding
  a new path to Metal's bounded usage index on every build, which could
  eventually log `MDB_MAP_FULL`. Routine accessibility query logs now
  require an explicit diagnostic switch instead of filling Xcode's console.
- Large SFTP listings convert and sort in the background; superseded work
  cannot replace a newer directory or sort order.
- Opening remote editing no longer hashes the old cache on the main thread.
  Cleanup runs in the background with a per-run work budget.
- Remote-edit operations time out after 120 seconds once connected, releasing
  a stuck upload and offering its approval again for retry.
- Idle block-cursor capture resumes from GPU completion without blocking
  the main thread or holding the renderer lock; failed captures back off.
- Release SFTP stderr listeners with their channels and prevent PTY signals
  from racing child-process reaping.
- Cancelling an SFTP password prompt no longer opens it again. OpenSSH
  read the cancelled prompt as an empty password, tried it and asked again,
  up to three times or more; Cancel now ends that connection attempt.
  Cancelling a key's passphrase still only skips that key.
- Dropping files from Finder on the SFTP browser uploads them again — into
  the folder shown, or the folder row they land on. The drop never reached
  the listing.
- A terminal connection made from the connect sheet is remembered as a
  recent host once it is established, not when Connect is pressed: a host
  that refused the connection, or offers no shell, no longer appears.
- **Reconnect** and **New Session** start the new session at the pane's
  size and font size. The child started at the configured window size and
  was resized afterwards, so a remote banner and prompt were laid out at
  the wrong width, and a ⌘+ zoom was lost.
- A pane's failure page is no longer white in a dark window: its colours
  were resolved against the app's appearance instead of the window's.
- The failure page no longer mentions a Try Again button it does not show.

## [1.3.1] - 2026-10-21

### Fixed

- A large Kitty graphics image no longer freezes every window while it
  arrives. Its base64 and zlib were decoded while the pane's state was
  locked, and each frame waits for that lock: a 4K `kitten icat` held
  the whole app for about 110 ms. The decode now runs with the lock
  released, and the image is placed at the same point in the output.
- A screen of Chinese, Japanese or Korean text Corta has not drawn
  before — a new tab, a zoom step, a page of new output — no longer holds
  every window for tens of milliseconds while its characters are drawn
  for the first time. New characters are drawn about 8 ms' worth per
  screen refresh, shared by every pane, and the rest appear over the next
  few frames.
- On macOS 26, every terminal window now renders offscreen and presents its
  drawable through a classic Metal queue. This avoids the normal Metal 4
  drawable presentation path suspected in the repeated WindowServer crashes
  of #380. The reporter confirmed a diagnostic build launches normally
  on the affected Mac; macOS 27 keeps its measured presentation behavior.
  Thanks to @FrankChen-CLC for the investigation and the fix (#386).

### Security

- Exported terminal text and Corta's private state — recent hosts,
  directory history, window state, the remote-edit manifest — drop any ACL
  entry the folder hands down before a byte is written. `0600` set the mode
  bits only: a folder granting another account inherited read access passed
  it on to each file, and the rename and `chmod` kept it.
- Updating a shell rc file or the config file keeps its permissions from
  the first byte. The new copy was written at the umask and `chmod`ed
  after, so a private `~/.zshrc` holding exported tokens was readable by
  other accounts for a moment, and for good if the `chmod` failed.
- Directory suggestions believe only the pane's own zsh. Any output — a
  `cat`ted file, a remote shell over `ssh` — could forge the prompt marks
  and a suggestion report, and the overlay that appeared took Tab,
  Left/Right and Esc from every prompt after it and drew the attacker's
  text beside the cursor as if typed. The automatic zsh bootstrap now signs
  each report with a per-session secret. A folder name's bidi overrides and
  zero-width characters show as U+FFFD, as in the terminal itself.

## [1.3.0] - 2026-10-21

### Added

- Settings ▸ Appearance ▸ Font chooses the terminal font again: System
  Monospaced, or any installed monospaced family whose regular, bold and
  italic faces keep one width, grouped as Apple's or yours, with a line
  saying where the chosen font comes from and whether it carries its own
  CJK design. The list follows fonts installed while Corta runs (#372). A
  family whose rows are one em tall, as many CJK families declare, gets at
  least the configured line spacing, so rows no longer touch.
- Typography preferences in Settings ▸ Appearance and the config file:
  `font-weight` (`light`, `regular`, `medium`), `line-spacing` (1.0–1.4,
  default 1.18), `font-fallback` and `emoji-rendering` (`color`,
  `monochrome`); and in Settings ▸ Terminal, `ambiguous-width` (`narrow`,
  `wide`) for East Asian Ambiguous characters, where box drawing then spans
  both its cells.
- Chinese, Japanese and Korean fall back to the face for the system
  language — PingFang SC, PingFang TC, Hiragino Sans or Apple SD Gothic Neo
  — and kana and Hangul always to their own script's face, so Japanese
  kanji are no longer drawn in Chinese forms on a Japanese Mac.
- Settings ▸ Appearance ▸ CJK Font and `font-family-cjk` choose the font
  Chinese, Japanese and Korean are drawn in — any installed font with CJK
  characters, monospaced or not — ahead of the system language's (#374).
- Double (`SGR 21`, `4:2`) and curly (`SGR 4:3`) underlines, and the ITU
  T.416 colon forms of SGR colours (`38:2::r:g:b`). Other sequences with a
  colon are still ignored whole. An underline colour (`SGR 58`) is
  consumed rather than misread as attributes.

### Changed

- **Config file:** `font-size` now defaults to 13 and takes 10–24 in whole
  points; a value outside that range is clamped to it the next time Corta
  writes the file. Set it again if you used a size above 24 or below 10.
- The terminal's side padding is 10 pt on each side (the left was 14).
- `SGR 21` turns on a double underline, as xterm, VTE and kitty read it,
  instead of being ignored.

### Fixed

- A symbol the font lacks, such as a prompt's `❯`, is no longer drawn bold
  beside regular text, nor below the line: macOS answered SF Mono Medium
  with Menlo Bold. Arrows, dingbats, geometric and technical symbols from a
  fallback font are now drawn in its regular weight and centred where the
  font centres its own; braille, Powerline and Nerd Font icons, and pieces
  whose height is their meaning (scan lines, bracket pieces, corner
  triangles), keep their place.
- System Monospaced is drawn in its Regular weight, as every other family
  and the CJK and symbol fallbacks are, so text and its fallbacks share one
  weight. It was Medium, which left Chinese and Japanese a step lighter
  beside it.
- CJK in bold text is bold: it was drawn in PingFang SC Regular whatever
  the style, and now uses PingFang SC Semibold under a bold face.
- `font-family` in the config file is no longer replaced with `system`. A
  family that is not installed, or not one width, draws as System
  Monospaced and Settings shows a Font Status row saying why (#372).

### Security

- Command History's **Run** sends Return only for a command its row showed
  whole, measured as drawn. The check counted up to 80 characters, more
  than the column shows at the window's default width, and a wide
  character counted as one: a forged history entry could hide the end of
  the command it ran. Run also fills, rather than runs, a command whose
  row output rewrote after the list last showed it.
- Hovering a line built of combining-mark clusters no longer freezes the
  window: joining a row's text took time in the square of its width, and
  a link or file-reference check on such a line ran for seconds on every
  mouse move. Such a cluster also no longer shifts where a match on the
  rest of the line is drawn.
- A keyboard-protocol pop (`CSI < n u`) costs the depth of the stack, not
  the `n` the program asked for: a stream of large pops kept the pane
  busy far beyond its size.
- A long-task notification is titled with the tab's name you gave it, or
  its directory. It used the window title, which a program sets with OSC
  0 or 2, so any output could post a notification worded as Corta's own.

## [1.2.3] - 2026-10-19

### Added

- The user guide has a *Coming from another terminal* section: the Corta key
  for each habit carried over from iTerm2, Ghostty or Terminal.app (⌥ as
  Meta, copy on select, a hotkey window, OSC 52 writes), and what has no
  equivalent.
- `README.zh-CN.md`, a Simplified Chinese summary of the README's first
  screen and installation steps.
- `docs/DECISIONS.md` opens with an index of every decision and its status.

### Changed

- The README is shorter: one table of measured figures, each naming the
  release it was measured on, and the comparison with iTerm2 and Ghostty
  moved to the feature reference. "What is planned" links to the open
  issues instead of an empty milestones page.

### Fixed

- Rapid clicks on New Tab always append and select the rightmost tab, even
  while the previous tab's selection transition is still in progress;
  toolbar actions keep their owning window throughout the transition.
- SFTP rename, new-folder and upload dialogs keep the directory they opened
  for when navigation finishes behind them, and refuse a replacement
  connection. Remote-edit change detection, upload snapshots and saving a
  copy elsewhere process file contents off the main thread; an older change
  check cannot replace a newer edit or an approved baseline.
- A pane no longer stops drawing for good after a few ordinary pauses. A frame
  dropped just before the window was minimised, covered, moved to another
  Space or put to sleep was taken for a stalled GPU when drawing resumed, and
  the fourth time in a pane's life it showed the renderer failure. Only a
  queue that finishes nothing for a second counts now, and a rebuilt one that
  draws for ten seconds starts the count again.
- Waits that end in a failure no longer count time the Mac spent asleep: a
  shell starting, an image decoding or a remote file opening across a closed
  lid is not reported as timed out on wake.
- `quick-terminal-key` refuses a Shift-only key such as `shift+a`, which would
  have taken capital A away from every application.
- A connection that drops on its first request after connecting is reported
  by its real cause, not as a lost connection. Closing an SFTP browser or
  remote edit no longer waits on the main thread for ssh to exit, and a
  dropped connection no longer ties up a thread per pending request while its
  cause is read.
- The idle block cursor gives up on a GPU busy with other work after 100 ms
  instead of holding the window for up to two seconds.
- zsh history is saved to `~/.zsh_history` again with directory completion
  on. macOS's `/etc/zshrc` set `HISTFILE` while `ZDOTDIR` still named Corta's
  temporary startup folder, so history went there and was deleted with it.
  Each zsh session's startup folder is now removed when the session ends,
  not only when Corta quits.
- Clicking a task notification handles the click on the main thread whichever
  thread the system delivers it on.

### Security

- A dropped file path, and the directory typed by Go to Parent Directory and
  Go to Project Root, is quoted by Unicode scalar. An apostrophe or backslash
  joined to a combining mark in a file or folder name was written unescaped,
  which closed the quotes and let the rest of the name run as a command.
- An SFTP upload, including saving a remote edit, keeps the mode of the file
  it replaces — and its group where the server allows — and a file reached
  through a symbolic link keeps its target's mode. Replacing a file used to
  leave it at the server's default mode, so a private (0600) file such as
  `.env` could become readable by other users on the host. A new remote file
  asks for the local file's permissions, narrowed by the server's umask.
  Uploaded files also keep a real access time instead of 1970.

## [1.2.2] - 2026-10-15

### Changed

- Building a frame's instances takes a third or more less CPU when the whole
  screen changes: the per-cell reads of the terminal core and the glyph
  cache's ASCII hits are inlined. Text joined by combining marks, emoji
  modifiers or flag pairs no longer allocates per character as it arrives.

### Removed

- Directory-history favourites. Nothing in the app could ever mark a
  directory as one, so the history now ranks by frecency alone; a history
  file that still carries the old flag loads as before.
- The experimental per-window render thread (`CORTA_RENDER_THREAD=1`), which
  was off by default and never shown to save power. Every window renders on
  the main thread, as it always has by default.

### Fixed

- A selection disappears when the program running in the pane rewrites the
  text it covers. Claude Code's in-place redraws left a highlight lying
  across unrelated text that a click could not remove (#341).
- The input-source badge beside the prompt takes its text colour from the
  terminal theme, as the directory hint does, so a theme darker or lighter
  than macOS no longer draws it dark on dark (#348).
- After a crash, restored tabs keep the tab that was selected and the names
  given to them: switching or renaming a tab now saves the arrangement, as
  moving or resizing a window already did.
- A pane no longer risks drawing its whole session in a fallback font
  with no letters when macOS's font service hiccups as the pane opens: the
  terminal font's fallback list is applied to the font already loaded
  instead of looking the font up again.
- A split's focus ring, and the settings rows' status icons, follow
  Increase Contrast when it is switched while Corta runs, instead of
  keeping the width and colour they had until the focus next moved.
- The `cd` directory-completion hint takes its colour from the theme —
  built-in or defined in the config file — instead of the system label
  colour, which drew the alternatives almost black on a dark theme while
  macOS itself was in Light mode. A theme change recolours a hint already
  showing, and Increase Contrast strengthens it.
- The user guide and configuration reference no longer promise a directory
  switcher: directory history is recorded and can be cleared in Settings,
  but nothing in the app lists it yet. Troubleshooting entries that had
  drifted below "Going back to your old terminal" are back under their
  topics, and release-specific notes read as current behaviour.

## [1.2.1] - 2026-10-14

### Added

- The SFTP browser and remote editing ask for a password, a key passphrase,
  a one-time code or a new host key in a dialog, through OpenSSH's own
  `SSH_ASKPASS`, so a host that takes only a password can be browsed and a
  new host no longer has to be accepted in a terminal first. Nothing is
  saved; the host-key dialog shows the fingerprint and defaults to Cancel.
- The SSH and SFTP connect sheet has user, port and private-key fields
  beside the host, the same for both: SFTP can now reach a non-default port
  without a `~/.ssh/config` alias, and a chosen key is offered first, with
  other `ssh-agent` keys left out. Recent connections remember the fields they were made with.

### Changed

- The remote badge at the front of a window title reads *Remote:* instead
  of the `⟂` symbol, and a connection opened from the connect sheet names
  the destination you typed instead of *host unknown*. Browse Remote Files…
  in such a pane connects to that destination without asking for it again.

### Fixed

- Configuration and user guides now include every scalar setting in the
  complete example and distinguish automatic zsh hooks, remote editing and
  protocol queries from older behaviour; documented defaults are checked
  against the implementation.
- Release preparation and packaging checks accept version-independent README
  download instructions, so editing installation prose no longer breaks the
  release pipeline.
- Renaming a tab and then clicking or switching to another tab, closing a
  tab or entering full screen saves the name, instead of leaving the tab
  blank and its editor stranded where the tab used to be.
- SFTP and remote editing work for a host whose `~/.ssh/config` entry has a
  `RemoteCommand`, which made ssh refuse the file channel, and no longer
  inherit `RequestTTY force` or become a `ControlMaster` themselves.

## [1.2.0] - 2026-10-13

Corta 1.2 is a performance release: faster from the byte a program writes
to the pixel on the panel, lighter in memory, and quieter when nothing is
happening. Figures are from one Apple M5 MacBook Air, before and after on
the same machine and toolchain; [Performance](docs/PERFORMANCE.md) has each
method and what it does not show.

### Changed

- **2.3× the output throughput.** The parser and grid take 355.9 MiB/s,
  up from 158.0, and output arriving from a shell 317.3 MiB/s, up from
  137.2. Runs of printable text are classified 16 bytes at a time with NEON;
  common CJK text skips the width table (+23%), and `yes` runs 70% faster.
- **A frame less from keypress to glass in full screen.** A full-screen
  window with one pane presents its frames directly to the display instead
  of through the window server's compositor. A person typing sees the median
  drop from 64–68 ms to 49–51 ms and the worst cases halve (p99 154–180 →
  83–84 ms). Nothing visible changes; `CORTA_DIRECT_FULLSCREEN=0` turns it
  off for a comparison.
- **The panel's full refresh rate while you type.** Typing, committed
  input-method text, paste and mouse reports lift the frame-rate ceiling to
  the panel's maximum — 120 Hz on ProMotion — and it settles a second after
  the last key. Critical thermal pressure still limits it.
- **Scrolling reuses what is already drawn.** Scroll regions, history and
  inserted or deleted lines shift the rendered rows instead of rebuilding
  them: a one-line region scroll takes 0.026 ms of CPU a frame instead of
  0.130, and output arriving while you read history 0.010 ms instead of
  0.096. Screen rows keep their memory as they scroll.
- **Scrollback in a fraction of the memory.** Cold history is compressed in
  memory as it arrives, off the terminal lock: 100,000 lines of 120 columns
  take 11.4 MiB instead of 185. Search, resize and reflow read it in place.
- **Smaller GPU footprint.** A rendered quad is 24 bytes instead of 48, and
  glyph atlases grow on demand: four panes at a prompt hold about 1 MiB of
  atlas instead of 81 MiB. The atlas's rectangle table is uploaded only when
  it changes.
- **Quieter at rest.** An idle blinking cursor is animated by Core Animation
  instead of redrawn every half second; an idle shell no longer wakes its
  reader four times a second; a pane you cannot see drops its reader to
  background priority after two seconds, and returns to interactive
  priority the moment you type or paste.
- Kitty images are decoded by the sandboxed helper straight into memory the
  GPU reads, with no copy through the app, then moved into GPU-private
  storage; raw RGB/RGBA images are converted in place.
- The disk image is an APFS volume compressed with lzma, about 15% smaller
  to download than 1.1.9's. Opening it shows a fixed window with Corta, an
  arrow and the Applications folder.
- Changing the font size (⌘= / ⌘− / ⌘0, a pinch or Settings) keeps the
  window's frame; only the rows and columns refit, as in full screen and
  with splits.
- An ended session shows a compact, centred card with accessible
  **New Session** and **Close Pane** buttons that fit narrow panes.
- An opt-in per-window render thread (`CORTA_RENDER_THREAD=1`) is available
  for testing; it stays off by default.

### Fixed

- With View ▸ Show Tab Bar on, a new window opens at the configured `rows`
  instead of two or three rows short.
- Kitty images inside a scroll region — and lines inserted or deleted around
  them, as vim, less and tmux do — move with their text and are cropped at
  the region's edge, including in the alternate screen and with scrollback
  off.
- A Kitty image near the 16-million-pixel limit whose width needed padding
  for the GPU was refused; it now shows. Narrow images and many small ones
  no longer fill the image budget early, and an image whose upload met a
  busy GPU is retried instead of staying blank.
- In full screen, a frame whose rendering failed is redrawn instead of
  being presented as drawn.
- Square table corners stop at the strokes they join instead of protruding
  past the border, at every display scale.
- Directory suggestions hide while an input method composes text, so they
  no longer overlap the preedit or the candidate window.
- Input-method and accessibility cell positions match what is drawn while a
  live resize briefly makes the grid taller than its pane.
- Idle blinking cursors give way to the drawn cursor before new output
  renders, so a cursor is never shown twice.
- Automatic focus reports no longer raise a hidden pane's reader priority;
  only your input does.
- With `CORTA_RENDER_THREAD=1`, a GPU that stops responding no longer takes
  the app down when a pane closes or the font changes.

### Security

- The image decoder's sandbox is verified by the test suite instead of by a
  deliberate denied file read on every image, which logged a sandbox
  violation for each picture shown.
- Every pull request is scanned by CodeQL (Swift, C, Python and workflows)
  and dependency review before it can merge.

## [1.1.9] - 2026-10-09

### Changed

- Future releases use a signed, notarised disk image (`.dmg`) for installation
  and automatic updates. Earlier releases keep their original ZIP files.

### Added

- Discussions now have forms for questions and early ideas; bug reports ask
  for diagnostic information when Corta freezes or crashes.

### Fixed

- Cancelled SFTP uploads keep only their confirmed contiguous prefix before
  resuming; out-of-order in-flight writes could leave a hole that a retry
  skipped by trusting the partial file length.
- Focusing a window by its Shortcuts identity brings the requested window
  forward even while macOS is still activating the application.
- A screen overflowing the glyph atlas no longer makes every unrelated cell
  change re-shape an entire frame of text; deferred first paints that fit
  still fill in across frames.

### Security

- Inline images (the Kitty graphics protocol) are decoded in a separate,
  sandboxed process with no access to files or the network, so a flaw in
  the system's PNG decoder can no longer reach anything Corta has been
  allowed to read.
- Updates are checked harder: Corta refuses an update feed that is not
  signed with its update key, with no grace period, and checks a
  downloaded update's signature before unpacking it rather than after. The
  feed's notes, links and flags were not covered by any signature before.
- The update feed's own check now refuses an entry that carries release
  notes, a link or an update flag, which Sparkle would act on and the
  update's signature does not cover; the feed has never published any. The
  release check also refuses an app in which any part could be debugged,
  load another developer's libraries, or search outside the app for them.

- The SFTP browser and remote editing no longer forward your SSH agent, X11
  or ports to the host, and never run a `LocalCommand`, whatever
  `~/.ssh/config` says for it — as `sftp` itself does. A `ForwardAgent yes`
  meant for interactive logins reached a host named by a remote shell's own
  report.
- Retrying a failed transfer after **Change Host** no longer sends it to the
  new host. The row named the host it was queued for, and Retry ran on
  whichever host the browser was connected to by then.
- **Run** in the command history fills, rather than runs, a command the
  list cannot show whole: more than one line, longer than 80 characters, or
  holding a tab. The records come from shell-integration marks that any
  program's output can imitate, so a part you never saw could run.
- A working-directory report (OSC 7) is believed only where the kernel puts
  the shell or the running program. Any output — a remote shell, or `cat` of
  a file — could name a local folder by leaving out the host, and new tabs,
  splits, restored windows and the directory history followed it.
- Editing a remote file by ⌘-click or **Edit** copies at most 64 MB, and any
  download stops if the server sends more than the size it stated, or more
  than a READ asked for. A server that gave no size could fill the disk with
  no progress row to cancel from.
- The SFTP browser shows control, right-to-left and zero-width characters in
  a remote name as `�`, and saves them as `_`, so `invoice\u{202E}fdp.sh` no
  longer reads as `invoicehs.pdf`.
- Remote-edit copies are removed 30 days after their last use (when remote
  editing is next used), unless they hold an edit not yet uploaded or
  dismissed. A file opened once stayed in
  Application Support, and its backups, for good.
- Exported output and selections are written readable by you only (`0600`).
- A remote-edit copy from 1.0.x, which recorded no content digest, now asks
  the conflict question before its first upload, as the security notes
  always said; size and time alone miss a same-size change within the
  second. **Upload Anyway** records the digest for next time.

### Added

- A pane whose session has ended says so until you act: a bar names the
  exit code or the signal, and offers **New Session** (or **Reconnect** for
  an `ssh`-style command) and **Close Pane**. The last output stays readable
  and selectable, and no caret is drawn. A program that exits back to the
  shell's prompt is not the session ending, and shows nothing.

### Fixed

- Two uploads to the same remote file no longer share one partial file. The
  second could finish and report success while the first, still writing
  through its own handle, changed the file it had committed. Transfers to
  one destination now take turns, from any browser window, folder transfer
  or remote-edit save, and a transfer from zero writes a partial of its own.
- On a server without `posix-rename`, a failed overwrite can no longer lose
  both files. The old file is renamed aside rather than removed, put back if
  the new one cannot take its name, and removed only once it has; if even
  putting it back fails, the error says where both copies are.
- **Save Local Copy Elsewhere** no longer deletes the file you agreed to
  replace when the copy then fails. The copy is made beside it first and
  only then renamed over it.
- A transfer whose source shrinks, grows, is rewritten or replaced while it
  is read now fails, and leaves the destination as it was. It used to
  commit what it had read — a truncated or mixed file — and report success.
- Ctrl-C reaches a program that stopped reading in the middle of a paste's
  last chunk. With nothing of the paste still queued, Ctrl-C waited behind
  the blocked write instead of interrupting the program.
- Opening a remote file no longer waits forever on a server whose SFTP
  service never answers: the connection is given up after 30 seconds, a
  cancelled open stops waiting at once, closing the pane cancels its opens,
  and the next open connects afresh.
- The Quick Terminal no longer disappears just after it was summoned, when
  the summon came while an earlier hide was still sliding out.
- A setting changed in Settings no longer writes over an edit to the config
  file made a moment earlier, before Corta had read it.
- Changing the font size while a frame was still being drawn could show
  glyphs from the new size in that frame. The glyph atlas now leaves the
  textures a queued frame uses alone.
- Plain-text search stays fast on long lines with a near-miss query, and
  stops promptly when the query changes, instead of finishing a scan that
  could take hundreds of milliseconds.
- Clicking a long-task notification lands on the pane that posted it, not
  the first pane of its window with a command of the same number.
- VoiceOver's selected text includes the last selected character, and a
  single selected character is reported as a selection.
- A cancelled upload resumes from where it stopped on OpenSSH servers,
  instead of starting over: every write moved the partial's timestamp, so
  it no longer looked like the same file.
- Uploading a folder that was moved or deleted while it waited in the queue
  now fails, instead of creating an empty remote folder and reporting
  success; an unreadable subfolder fails the upload too.

## [1.1.8] - 2026-10-07

### Fixed

- A window with a tab bar showed two **+** buttons, the toolbar's and the
  tab bar's. The tab bar's is gone; the toolbar's opens a new tab.

### Commits

- fix(ui): drop the tab bar's + in favour of the toolbar's (#273)

## [1.1.7] - 2026-10-07

### Added

- A **+** button in the toolbar, beside the network and folder buttons,
  opens a new tab. The tab bar's own **+** goes with the bar, which a window
  of one tab does not show.

### Fixed

- The command palette's arrow keys get past a command you ran recently. It
  is listed twice — under Recent and in its group — and stepping onto the
  second copy jumped back to the first, so nothing below it could be
  reached with the keyboard; both copies were also highlighted at once.
- Clicking another window while the command palette is open leaves that
  window in front. The palette used to bring back the window it opened
  over.
- Find highlights stay on their text while output arrives. Between sweeps
  each highlight was drawn as many rows off as lines had arrived since.
- The find bar's "No Results" and its button names are translated.
- Chinese and Japanese composition shows where you are typing. The block
  cursor sat over the first letter of the preedit (`我 █ou` for "you"), and
  inside Claude Code its own cursor cell showed through the text. The
  preedit now draws on the terminal background with a caret at the input
  method's position, and the terminal cursor steps aside while it is up.
- The input-source badge in the toolbar stays while a program runs. It
  disappeared for the whole of a Claude Code session or an editor on the
  alternate screen; only the prompt-placed badge, which sits over output,
  still steps aside.

### Changed

- The Corta theme's light cursor is a slate grey instead of near-black.
- The find bar is smaller: about 28pt tall instead of 36pt, and about
  55pt narrower. Its buttons have tooltips.
- The command palette finds a command by its group's name (`panes`) or its
  configuration name (`new-tab`) as well as its title, and the list scrolls
  only as far as the selection needs. Its rows and shortcuts are worked out
  once per keystroke rather than on every redraw.
- Find builds its highlights once per search rather than on every frame.
- The input-source indicator's default mode is called **Automatically**
  (was "While entering commands"): in the toolbar it now shows while
  programs run too.

### Commits

- fix(app): show the IME caret, keep the badge, fix palette and find (#269)

## [1.1.6] - 2026-10-07

### Fixed

- Rounded box corners (`╭ ╮ ╰ ╯`) — the boxes Claude Code draws — meet
  their sides. 1.1.5 drew straight borders on the cell grid but still took
  the corners from the font, whose arcs sat apart from the lines and at
  another weight, so every rounded box had four broken corners. The arcs
  are now drawn with the borders, at their position and thickness.

### Commits

- docs: describe 1.1.6 and record its release checks (#265)
- fix(app): draw rounded box corners with the borders they join (#264)
- ci: pass the release secrets to the feed step (#262)

## [1.1.5] - 2026-10-07

### Responsiveness and resilience (reliability review, 2026-10-07)

- A network volume that stops answering no longer freezes Corta. Hovering or
  ⌘-clicking a `path:line`, restoring windows at launch and opening a pane
  in such a directory checked it on the main thread, where `stat` could
  block for minutes — at every launch, when the saved arrangement named it.
  The checks now run in the background with a short limit; a directory that
  does not answer in time is treated as missing, and the pane opens in the
  home folder.
- Waking the Mac no longer risks a "renderer failed" pane: a frame
  submitted just before sleep was counted as overdue by the time asleep.
- A GPU that cannot allocate even the smallest glyph atlas fails that pane
  with a recovery view instead of quitting the app.
- With the search bar open over streaming output, refreshes are spaced at
  least 250 ms apart instead of running back to back.
- Large SFTP transfers update their progress row a few times a second rather
  than for every 32 KiB block.
- CI now runs the real OpenSSH/SFTP suite against a throwaway local sshd on
  every change.

### Your files and remote copies (reliability review, 2026-10-07)

- A config file or shell rc file that is not UTF-8 text (or cannot be read)
  is no longer overwritten. Before, the config read as empty and the next
  change in Settings replaced it with defaults; installing shell
  integration replaced the whole rc file with Corta's block. Both now say
  why and leave the file alone.
- A remote-edit upload that fails asks again instead of leaving the edit
  stuck, when later saves never prompted. An edit never uploaded before
  quitting is offered for upload when the file is opened again, and a local
  copy Corta has lost track of is kept aside instead of blocking the open.
- Deleting in the remote file browser removes what the confirmation named,
  even if the listing moved to another folder before you confirmed; a
  download started before navigating fetches the chosen entries.
- Window arrangement, directory history and the remote-edit records saved
  by a newer Corta are no longer overwritten by an older one.
- Move to Applications no longer fails every time when opened straight from
  the download (App Translocation), and never replaces a newer installed
  Corta with an older copy.

### Keyboard (reliability review, 2026-10-07)

- ⌥← and ⌥→, ⌥⌫, Home, End, Page Up, Page Down, forward delete, F1–F12 and
  the shifted arrows reach the terminal again. The system input context —
  with any input source, ABC included — answered them with text-editing
  commands the terminal dropped. A command answered for a key is now
  encoded from the key itself, so the plain arrows also honour application
  cursor mode again; an IME composing still gets every key first.
- ⌥⌫ sends `ESC DEL`, which shells bind to deleting the previous word.
- With the kitty keyboard protocol's disambiguation on, Escape is reported as
  `CSI 27 u`, and ⌥Return, ⌥Tab, ⌥⌫ and ⌥-as-Meta keys as `CSI code ; 3 u`,
  as the protocol specifies for keys that legacy encoding cannot tell apart.
  A key release is reported only for a press the program received.

### Reliability review (2026-10-07)

- Ctrl-C now cancels a paste still queued for the shell: what has not been
  sent is dropped, keystrokes typed after it are kept, and a bracketed paste
  the shell had started reading is closed so it leaves paste mode. Before,
  Ctrl-C waited behind the whole paste, or was refused once more than 4 MiB
  was queued, and closing the pane was the only way out. When the shell has
  stopped reading altogether, the interrupt is delivered as the signal the
  terminal would raise for it, instead of waiting behind the blocked write.
  History insertion is cancellable the same way.
- Input typed or pasted as the shell exits no longer raises the "terminal
  session failed" recovery view; the pane reports the exit as usual. A
  program that gives up the terminal without exiting gets the recovery view
  instead of a pane that silently stops responding.

### Terminal recovery (#228)

- PTY read/write failures show a persistent recovery action instead of silently
  losing input or output. A failed write discards the remaining queued input;
  keyboard backpressure is reported. Trying again or reconnecting explicitly
  starts a new session and closes the current one.
- Faulted or persistently stalled Metal queues can be replaced up to three
  times without replacing the terminal session or render caches. Missing GPU
  completion feedback and exhausted recovery show a recovery action.
- A terminal reset no longer reuses synchronized-output episode identities,
  so a new output hold retains its timeout and ignores older timeout callbacks.
- Regex search checks cancellation and its time budget during engine progress,
  including expensive failed matches missed by the early pattern check.
- Escape consumed while closing search no longer reaches the terminal child.

### Terminal feedback (#213)

- Standardized VS16 emoji sequences (such as ⚠️) occupy two columns so
  subsequent text and table borders stay aligned, including across PTY reads
  and at the right margin.
- Solid light/heavy table borders draw on the cell grid instead of using font
  glyph bearings, keeping Claude Code table corners and junctions connected.
- Terminal windows retain an opaque theme background across appearance changes,
  including newly created and inactive tabs.
- Font settings, keyboard zoom and pinch refit rows and columns while keeping
  the window in place, subject to minimum-size constraints. A single-pane
  window moves its bottom and right edges to whole cells so the grid fills
  it, keeping the same gap under the last row at every size; a pinch settles
  once when it ends, and the new rows and columns reach the shell in one step
  instead of after the resize debounce.
- Previous/next tab commands (⇧⌘[ / ⇧⌘]) are configurable. Tabs can be renamed
  in place by double-clicking their title or using the tab context menu; Return
  saves, Esc cancels, and names survive shell output and restore. Tab and
  terminal context menus include New Tab.
- Solarized and Mono join Corta in the theme picker; custom themes are preserved.
- URL hover explains ⌘-click and shows the target. Secure Keyboard Entry’s lock
  opens Privacy & Security settings. Close confirmation keeps its running-job
  default and makes Cancel the default keyboard action.

### Added

- Optional local system status bar with CPU, load, memory, one-interface network
  rates, home-volume free space and four thermal levels; click for host details.
  Metrics are selectable, sampling is shared across windows and pauses when hidden.
- Graphical theme creation and editing with light/dark previews, color pickers,
  HEX input, cancel and source-color reset, saved to the existing config file.

- Persistent input-source badge for Chinese, Japanese, Korean and other input
  sources, fixed in an independent window-toolbar group by default, separated
  from network and file actions, with optional prompt-right
  placement and long-command avoidance,
  prompt-only/always/off modes and configurable direct-input/IME colors. Private
  IME modes use a neutral badge; scrollback and alternate-screen programs hide it.
  Automatic display follows enabled non-Latin layouts and IMEs. Default styling
  uses faint gray direct-input badges and a subtle indigo tint for non-Latin
  layouts and confirmed IME modes.

- Live cursor shape and blinking settings, with temporary DECSCUSR overrides
  from terminal programs; blinking pauses in inactive or hidden panes.

- Optional built-in directory suggestions for local zsh sessions: faint
  folder alternatives below `cd`, inline suffix previews, Left/Right selection
  and Tab acceptance without executing the command. Up/Down keep shell history
  navigation and Shift+Tab passes through. Settings can disable suggestions;
  bundled startup hooks do not edit the user's shell files.
- Localized settings for directory suggestions and command-status marks,
  with usage and opt-out instructions in the user guide.

### Changed

- A Release build no longer honours `CORTA_SFTP_SSH`, the test hook that
  swaps the SFTP browser's `ssh` for another program; the development
  build accepts only an absolute path to an executable and logs its use.
  Every `CORTA_*` launch switch is listed in `docs/TESTING.md`.
- A block cursor is opaque in the theme's cursor colour, with the character
  under it drawn in the background colour, as Terminal.app draws it.
- Selection, search-match, hovered-link and command-mark colours come from
  the active theme instead of fixed values chosen for a dark background, so
  they stay visible in light themes; `docs/CONFIGURATION.md` §4 gives the
  formulas.
- Primary font is System Monospaced; legacy configured families migrate to it.
- Corta zsh integration inserts four spaces for Tab on a blank command line
  while preserving command completion and terminal output tab stops.
- The optional status bar uses a compact 24-point layout with localized short
  labels and full metric values in details, tooltips and accessibility.

- Command-status rules sit in a narrow margin beside the prompt with text
  tooltips. Exit status 130 uses a gray interrupted mark and a textual history
  status instead of the red failure indicator.
- Shell groups focus, command output, working-directory, pane-layout and
  connection tools into submenus while keeping splitting and clearing direct.
- Keyboard Shortcuts uses aligned columns, clearer section boundaries and
  explicit labels for commands without bindings. About links have separators.
- Confirmations that belong to a window — closing a window, tab or pane with
  something running, quitting, clearing history or resetting, and pasting
  text with newlines — appear as a sheet on that window instead of a dialog
  that blocks the whole app.
- The find bar and the command palette draw SwiftUI's Liquid Glass
  (`glassEffect`) instead of AppKit glass views, with the same opaque fill
  under Reduce Transparency and drawn border under Increase Contrast.
- The first terminal window opens centred on the screen. Restoring the
  previous arrangement opens only the saved windows, instead of first
  starting a shell in a home-directory window and closing it.

### Fixed

- Making a window bigger while a program is running no longer hides part
  of what it draws. The scroll region kept its old bottom edge, so a
  program that redraws after the resize (Claude Code) piled its input box
  and status lines onto the old last row and left the new rows blank, and
  a shell's output kept scrolling above the window's real bottom. A resize
  now gives the scroll region the whole new screen, as xterm does.
- Making a window wider or narrower no longer moves the cursor back onto
  text. A cursor after a typed space, or past the end of a line, came back
  at the line's last character; one that had just filled a row came back
  on that row's last character, which the next character then
  overwrote. It now keeps its place after the line, and a line that ends
  exactly at the new edge still wraps when typing continues.
- SFTP progress accepts full-width remote sizes without overflowing the toolbar
  total, and deeply nested remote paths build only a bounded breadcrumb trail.
- SFTP sessions stop safely when a peer withholds 1,024 cancelled request
  replies, releasing retained request metadata instead of growing indefinitely.
- Folder downloads reject collisions with `.corta-part` staging names before
  changing local files. Default file transfers refuse existing partials;
  explicitly chosen single-file overwrite and resume remain available.
- Large terminal forward/backward tab counts stop at the margin, allowing
  subsequent output and user interaction to proceed promptly.
- Visible Kitty images that together exceed a pane's texture budget no longer
  evict and re-decode each other on every frame; the ones that do not fit wait
  until others leave the screen or are deleted.
- Holding ⌘ over output, or opening Shell ▸ Commands and Output, scans for a
  `path:line` once rather than twice, and skips lines too long to hold one.
- Startup folders for zsh integration left in the temporary directory by a
  crash or force quit are removed at the next launch, once a day old.
- Save Local Copy Elsewhere in a remote-edit conflict says when the copy
  could not be written, and keeps the conflict, instead of dismissing it as
  if the copy had been made.
- A theme's `ansi = #…, #…` list kept only its first colour: the second `#`
  was read as the start of a comment. Settings and the theme editor write
  every theme this way, so a custom theme's other fifteen ANSI colours
  reverted to its base theme's the next time the file was read.
- Appearance previews follow light/dark changes immediately and show cursor
  shape and blinking. The default remains a nonblinking block cursor.
- View menu and Terminal settings expose local host details even with the
  status bar off; View also opens the theme editor directly.

- New terminal windows and cascaded windows fit the screen’s usable area,
  avoiding a side Dock and oversized configured grids.
- The terminal context menu displays configured shortcuts for editing,
  splitting and closing, including custom bindings and unbound commands.
- Try Again on a pane whose shell failed to start no longer stacks another
  focus ring and highlight over the pane each time.
- Opening the Shell menu, or the shortcut for Copy Last Command Output, on a
  pane whose setup failed no longer crashes Corta.
- Command-status rules stay beside their own prompt while output scrolls.
  They were drawn a frame or two ahead of the text, so during continuous
  output a prompt briefly showed the green or red of a command below it.
  They are now drawn with the text, in the theme's green and red (#238).
- Resizing a window no longer crashes Corta after a program typed in insert
  mode (`CSI 4 h`) over a line ending in a wide character: the shift pushed
  the character's second half off the row, and the next reflow read past it.
- A program that hides the cursor (`CSI ? 25 l`) — vim, htop, fzf, Claude
  Code — no longer has a block cursor drawn wherever it last left it, and a
  hidden cursor stops blinking. Autowrap off (`CSI ? 7 l`) overwrites the last
  column instead of wrapping, and origin mode (`CSI ? 6 h`) addresses the
  cursor from the scroll region's top. DECRQM reports all three as they are;
  it had answered "permanently set" for the first two. CNL and CPL stop at
  the scroll region's margins, as cursor up and down do.
- Narrowing a window while a full-screen program runs no longer leaves text
  past the new right edge in its rows, where it was invisible but still
  copied and found by search.
- A UTF-8 sequence cut short by plain text, a control character or an escape
  sequence shows as one replacement character instead of combining with bytes
  that arrive after it into a character the program never sent.
- Chunked Kitty images whose later chunks carry only `m=` — the protocol's own
  form, sent by `timg`, `chafa` and terminal file managers — are displayed;
  they were discarded with `EINVAL:bad size`.
- With macOS set to a script-tagged language such as Simplified Chinese
  (`zh-Hans`), a shell started from the Dock got an invalid `LANG`
  (`zh_Hans_CN.UTF-8`) and ran in the C locale, so CJK text was handled one
  byte at a time. The locale is now `language_REGION.UTF-8` when the system
  has it, otherwise `en_US.UTF-8`.
- A terminal reset (`reset`, or Shell ▸ Reset Terminal) keeps the configured
  `command-history-limit`; with history turned off, it had started recording
  commands again.
- Closing a pane whose process ignores hangup (`trap '' HUP`) ends it ten
  seconds later with `SIGKILL`, as `SECURITY.md` §4.4 intends; it ran on
  without a terminal and was never reaped.
- An SFTP download from a server that answers a read with less than was
  asked — the protocol allows it anywhere, and some servers cap reads below
  Corta's block size — no longer stops at the first short reply and saves a
  truncated file as complete.
- An SFTP transfer under the "fail if it exists" policy no longer replaces a
  destination that appeared while it ran, locally or on the server.
- The SFTP browser and folder downloads leave out a remote name that is not
  valid UTF-8: Corta could only address a lossy copy of it, which names a
  different file.

### Security

- Kitty images sent as PNG (`f=100`) must be PNG. Image I/O recognises
  formats by content, so any program's output could reach its TIFF, JPEG,
  HEIC and other decoders under the name of a PNG.
- Pasted text drops DEL and C1 control characters along with C0 ones. A
  line editor treats DEL as backspace, so a pasted DEL erased text that had
  been on the clipboard and left a different command in its place.
- Holding ⌘ over a long run of text without a colon — 100,000 characters of
  output, from any program — no longer freezes every Corta window for up to
  a minute and a half, and opening Shell ▸ Commands and Output after such a
  command no longer freezes it for hours: the `path:line` detector
  backtracked quadratically, and located each of a line's matches by
  counting from its start. Both are linear now.
- Kitty images on the alternate screen share the pane's 320 MB budget with
  the main screen's, an unfinished transmission counts against it, and all
  panes together keep at most 1 GB. Under a megabyte of compressed output
  could make one pane hold about 0.9 GB.
- Bidi overrides, isolates, the hidden zero-width characters (ZWSP, word
  joiner, BOM, the invisible operators) and Unicode tag characters outside a
  subdivision flag are drawn as U+FFFD instead of
  nothing, as `SECURITY.md` §2.5 requires: invisible, they let a command look
  like something other than what a copy of it contains.
- Text a program places on the clipboard with OSC 52 also loses its control
  characters other than tab and newlines. Corta's paste stripped them, but
  another application's might not, and an ESC there can end a bracketed paste.
- A link's tooltip names the URL that opens — host in its IDNA form,
  invisible characters percent-encoded, user and password removed — and that
  URL is the one opened. `https://аpple.com` (a Cyrillic `а`) had shown as
  Apple's address, and `https://github.com@evil.example` named GitHub first.
- Files downloaded from the SFTP browser, including ones dragged to Finder,
  carry macOS's quarantine mark, so an app, script or installer among them
  gets Gatekeeper's first-open check like any other download.
- A file whose name contains `{line}`, `{column}` or `{file}` opens under its
  own name with `open-file-command`; the placeholder in the name was
  substituted too, opening a different file from the one shown.
- A host name reaches `ssh` only if it passes the check the connect sheet
  applies, whichever way it was named: the SFTP browser's own field and a
  remote pane's reported host (`⌘`-click on a remote `path:line`) skipped it.
- `directory-history.json` and `state.json` are owner-only (`0600`), as
  `recent-hosts.json` already was.

### Commits

- ci: count the dispatched CI toward the release and feed PRs (#260)
- chore(project): set the version to 1.1.5 and bring the docs up to it (#258)
- fix(app): keep the cursor's column through a reflow (#257)
- fix(app): give the scroll region the whole screen after a resize (#256)
- fix(app): keep stat off the main thread; harden render and transfer paths (#255)
- fix(app): never overwrite unreadable user files; keep remote edits recoverable (#254)
- fix(app): deliver terminal keys that the input context swallowed (#253)
- fix(terminal): let ctrl-c cancel a queued paste; treat write EIO as exit (#252)
- fix(app): bound terminal work and protect sftp transfer state (#251)
- ci: pin the self-hosted render workflow's actions by commit (#250)
- docs: say what the release environment actually requires (#249)
- fix(app): harden links, downloads, host checks and image textures (#248)
- fix(terminal): bound pattern scans, image memory and hidden characters (#247)
- fix(app): harden image decode, paste and SFTP; remove dead code (#245)
- fix(terminal): resolve the terminal-core review findings (#244)
- ci: pin release artifact uploads and pass the fuzz seed via env (#246)
- ci: make releases a single manual workflow run (#243)
- fix(terminal): recover failed I/O and rendering and bound search holds (#242)
- refactor(app): move test hooks out of production code (#241)
- fix(app): draw the command-status rules in the metal pass (#240)
- docs(docs): record why the canvas stays below the titlebar and frames present alone (#239)
- fix(ui): keep the border on opaque glass under both accessibility settings (#237)
- feat(ui): draw the find bar and command palette with SwiftUI glass (#236)
- refactor(app): delete the storyboard and start the app in code (#234)
- refactor(app): build the terminal window in code, born at its size (#233)
- refactor(app): use sheets, NSApp.activate() and a spawn chdir action (#235)
- refactor(app): make the terminal canvas opaque and drop the flash guard (#232)
- refactor(app): build the main menu in code (#231)
- refactor(app): replace the nonisolated(unsafe) globals with locks (#230)
- test(tests): run the stage-writing UI tests and match zoom to its rule (#227)
- refactor(app): split the remaining ViewController extensions (#224)
- feat(app): derive overlay colours from the theme, invert the block cursor (#226)
- refactor(app): read every CORTA_ switch through DiagnosticsEnvironment (#225)
- fix(app): fit a zoomed window to whole cells and refit in one step (#223)
- refactor(app): move the pane's menu commands into PaneCommands (#222)
- refactor(app): move the pane's remote side into PaneRemote (#221)
- refactor(app): move pane search into PaneSearch (#220)
- refactor(app): move the pane render loop into PaneFrameLoop (#219)
- refactor(project): move the sftp client into its own package target (#218)
- fix(app): address terminal rendering and tab feedback (#217)
- feat(app): pin input source indicator to independent toolbar group (#216)
- feat(app): add system status and graphical appearance controls (#215)
- feat(app): add optional directory suggestions and clearer status marks (#212)
- Fix shortcut hints, Shell menu organization and auxiliary window layout (#210)

## [1.1.1] - 2026-10-03

### Fixed

- Empty Return at a zsh, bash or legacy fish prompt no longer creates a
  success marker or repeats the previous command's failure marker. Command
  completion is emitted only after a command actually started. Existing
  installations must update Shell Integration in Settings and open a new
  shell to load the corrected hooks.
- The update-feed workflow now requests squash auto-merge after CI passes,
  so a brief delay in GitHub's merge eligibility refresh does not reject
  the merge. The log includes the PR number, URL and merge state.

## [1.1.0] - 2026-10-03

The Apple-silicon-only release (D21): Metal 4 is the one renderer, and
an Intel Mac stays on 1.0.1. New are SSH and SFTP in the toolbar, an
SFTP browser that works like Finder, a sidebar Settings window, Kitty
images `kitten icat` has to scale, a separate development build (D22)
and an archive signed and notarised in CI (#185). Search is about fourteen
times faster over a long scrollback, reflow twice as fast, and a
flooding pane wakes the main thread once a frame. Two reviews' findings
are closed under **Security** below. esctest2: 126 passed, 334 known
bugs, 107 failed of 567 (81.1%), the same failing list as 1.0.0's.

### Added

- Debug-only SFTP connected-state preview with sample files and transfer rows;
  the connection window opens centered, with a centered host form.

- SSH and SFTP toolbar entries, each opening a sheet on the window. The
  sheet suggests the hosts you connected to recently and the `Host` names in
  your `~/.ssh/config` (read, never run); typing narrows the list, a click
  fills the field, a double-click connects. Recent hosts can be cleared in
  Settings ▸ Privacy & Security.

- Settings is a sidebar of eight categories — General, Appearance,
  Terminal, Keyboard & Mouse, Shortcuts, Quick Terminal, Connections, and
  Privacy & Security — where General alone used to hold eight sections. It
  adds verified font selection, command-history limits, mouse override,
  search defaults, shortcut recording (a reset arrow beside a changed one)
  and preset management in place.

- About ▸ Acknowledgements shows the license of Sparkle, the updater Corta
  ships with, and the notices of the code Sparkle bundles — terms that
  require the notice to travel with the app.

### Changed

- The SFTP browser works the way Finder does: Back and Forward (⌘[ ⌘]), a
  breadcrumb path that becomes a field on a click or ⇧⌘G, columns that sort,
  sizes aligned right, dates such as "Yesterday at 20:00", hidden files on
  request (⇧⌘.), and a right-click menu on rows. Drop files on the listing
  or on a folder row to upload them; drag a file to Finder to download it.
  Transfers moved from a section under the listing to a toolbar button with
  a progress ring, whose list shows speed and time left, Show in Finder for
  a finished download, and Clear. The window is titled with the host; the
  toolbar no longer overflows at the size it opens at; a connection can be
  cancelled while it is being made, and a failed one corrected in place.
  The connect sheets' suggestions sit in a rounded well, Settings' sidebar
  draws each category on a coloured tile (its icons no longer flicker as
  the window opens), and the browser opens at a smaller default size.

- Counts read as English, German, French, Spanish and Portuguese write
  them: "1 item" rather than "1 items", "1 of 1 file", "1 host remembered",
  and the same in the status line, Settings, Command History, the Clear
  History question and the SFTP transfer rows.

- The find bar has a visible edge and shadow on any background, shrinks
  with a narrow split pane instead of covering it, and moves to the bottom
  of the pane while the cursor or the current match is under it.

- **Intel Macs are no longer supported.** Corta now runs only on Macs
  with Apple silicon (M1 or later); the minimum macOS stays 26.0. 1.0.1 is
  the last version for Intel Macs and remains available from its release
  page. An Intel Mac running 1.0.x is not offered this update, so it keeps
  working on the version it has (D21).

- The bundled updater is Sparkle 2.10.0 (was 2.9.6).

- **Metal 4 is the only renderer.** The classic Metal path is gone, and
  every frame — backgrounds, text, colour glyphs and every Kitty image —
  is drawn in one render pass. A GPU that stops completing work now costs
  dropped frames instead of stalling the window: before, each frame could
  wait up to a second for the GPU on the main thread. A Mac whose GPU does
  not support Metal 4 — in practice, macOS running in a virtual machine —
  shows "This GPU does not support Metal 4" in the pane and starts no
  shell, rather than falling back to a second renderer.

- Building Corta from source now produces a separate application: **Corta
  Dev** (`dev.noahqin.Corta.dev`), with its own icon, its own
  configuration and state under `~/Library/Application Support/Corta
  Dev/`, no updater and no offer to move itself into `/Applications`
  (D22). Nothing about an installed Corta changes — the release build
  keeps its identifier, icon, name and signature — but a development
  build can now run beside one without touching its configuration, its
  global hotkey or its update path. `scripts/build-and-run.sh` is
  replaced by the `Corta (Dev)` scheme, and the test suites are selected
  by test plan (`Unit`, `UI`) rather than by `-skip-testing`.

- The app's measurements are Xcode tests: `MeasurementUITests`, in the
  `Release` test plan, times launch, idle and occluded CPU, 1-, 2- and
  4-pane floods, the memory of opening and closing windows, and scripted
  keypress-to-glass; energy and the signpost chain are one `xctrace`
  recording each. The `measure-*.sh`, `record-signpost-trace.sh` and
  `find-release-app.sh` scripts are gone, and no Python remains in
  `scripts/`. `CORTA_RENDER_METRICS` accepts a file path, and appends each
  summary line to it.

- The release check is a Swift tool, `corta-release-check`, in the core
  package; it also builds the archive and its SHA-256 sidecar.
  `scripts/check-release.sh`, `package-release.sh` and the manual
  feed-signing `release.sh` are gone, and the update-feed workflow is the
  only route that signs `appcast.xml` (D20). A release archive's sidecar
  now names the archive without a leading `./`; `shasum -a 256 -c` reads
  it the same way.

- The configuration file Corta writes no longer labels its Quick Terminal
  and Presets sections with internal work-item codes (`(B16)`, `(U16)`).
  An existing file still loads unchanged; the new wording replaces the
  old the next time Corta saves it.

- Scrollback search is an order of magnitude faster. A query and a line
  that are both ASCII — the overwhelmingly common search — are now matched
  against the grid's cells directly, instead of building a string and a
  per-character position table for every logical line and handing it to
  Foundation. Over a 100k-line scrollback a warm query goes from 399.8 ms
  to 27.6 ms — about fourteen times faster — and that is what the search
  bar re-runs on every keystroke. A query with anything outside ASCII takes
  the old path untouched; a *line* with anything outside ASCII also takes
  it, after the byte walk has tried and rejected that line, which measures
  about 2% slower on a document where every line is non-ASCII.

- A pane flooded with output wakes the main thread at most once a frame.
  It used to queue a main-thread task for every chunk the reader parsed
  — about 40,000 a second under `yes` — each resuming the display link
  and, with long-task notifications on, restarting a timer. The
  notification's quiet period is now measured from the last output
  itself, so it stays right for a window that is hidden and not drawing.

- Redrawing the screen costs less CPU. Text glyphs are looked up by index
  rather than by hash, block elements (progress bars, shades, quadrants)
  no longer allocate per cell — a screen of them went from 10,555 heap
  allocations a frame to none beyond the frame's own — and a redraw that
  changes every row, as a full-screen program does, is spliced into the
  instance buffer in one pass instead of one per row. A full redraw of a
  120×40 screen takes 0.12 ms of CPU, down from 0.17–0.34 ms.

### Fixed

- `kitten icat` shows images it has to scale: a picture wider than the pane,
  or one placed with `--place`. It sends those zlib-compressed (`o=z`), which
  was ignored, so they never appeared. They are inflated now, bounded to the
  declared size, with the zlib header and checksum checked.

- The SFTP browser's free space counts in the server's fragment size: a Mac
  with 650 GB free was shown as 168 TB, because APFS reports a 1 MiB block
  beside the 4 KiB unit its counts are in. Folders show "--" for their size,
  as Finder does, instead of their directory entry's bytes.

- Remote editing requires a configured editor command. A downloaded file
  previously opened in its default application, which could execute
  `.command` or `.terminal` files supplied by a remote host. Local file
  references also require `open-file-command` instead of launching their
  default application.
- Remote editing reconnects on the next operation after a broken SFTP
  conversation, without restarting Corta. Failed uploads keep their
  pending decision and are never silently replayed.
- Starting the Quick Terminal more than once no longer leaves duplicate
  notification observers, and releasing it removes its observers.

- Output that costs a program a few bytes can no longer cost Corta far
  more. A letter followed by thousands of combining accents (about 130 KB)
  made Corta store several gigabytes; a character now keeps at most 32
  code points, and the marks past that are dropped. A Kitty image
  placement asking for thousands of rows scrolled every one of them,
  freezing the pane for seconds over a few kilobytes; it now scrolls at
  most the scroll region plus one screen. Once more than 2 047 links were
  on screen and in history at once, every new link searched the whole
  scrollback before giving up — `ls --hyperlink -R` over a large tree
  stalled the pane — and now searches at most once per 511 links.

- Hovering a very long wrapped line — a minified file printed as a single
  line — no longer stutters: finding where the line starts and ends no
  longer copies every row of it on each mouse move.

- Two Kitty images that use the same placement number both stay on
  screen. A placement number belongs to its image, but the second image
  replaced the first one's placement.

- A shell no longer inherits files Corta has open. Every descriptor Corta
  held without close-on-exec — the pipes of an open SFTP connection, a file
  in the middle of a transfer, a watched file — was open in every shell
  started after it, so a program in that shell could write into the SFTP
  stream, and closing the connection did not end ssh's input.

- A file transfer whose remote file cannot be opened leaves nothing behind:
  the local file stayed open until Corta quit, and a download left an
  empty partial file. A transfer that failed after its local file was
  closed could close an unrelated file Corta had opened since.

- Closing an SFTP connection whose ssh had already exited no longer sends
  `SIGKILL` to that process ID, which the system may have given to another
  program by then.

- A slow SFTP upload no longer stalls the rest of the app. Every pending
  write to ssh held one of the few threads Swift concurrency shares
  across the whole process.

- Closing a pane never waits on its shell, and a read or write on a pane
  being closed can no longer reach a file another pane opened in the
  same instant.
- Changing a pane's width keeps its command marks. Any change in columns
  — resizing the window, splitting, toggling the sidebar, changing the
  font size, or leaving a full-screen program after one — erased every
  prompt and success/failure mark, so the marks beside prompts vanished,
  and once history had been re-wrapped, jumping between commands, copying
  a command's output and opening a file it printed could land on the
  wrong lines.
- Shell integration reports directories with unusual names correctly. The
  directory went out unencoded, so `C# projects` was taken to be `C` and
  `what?` to be `what` — new tabs and splits opened in the wrong place —
  and a directory whose name holds escape sequences, as one unpacked from
  an archive can, injected them into the terminal on every prompt. The
  zsh, bash and fish hooks now percent-encode the path; **Settings ▸
  Terminal ▸ Shell Integration** shows **Update** for an integration
  installed before this change.

- Changing to the parent or project directory, or dropping a file, in
  fish can no longer run a command hidden in the name. The quoting was
  correct for sh, bash and zsh, but fish reads a backslash inside single
  quotes differently, so a name such as `x\'; cmd; \'` ran `cmd`.

- A directory name in the window title has its control characters removed,
  as every other part of the title already did; a newline or a
  right-to-left override no longer reaches the title or the tab.

- The window title no longer checks the current directory on disk with
  every burst of output. In a directory on a network volume, a program
  printing steadily — a build, an AI assistant — made each check wait on
  the server, dropping frames and slowing typing.

- A local pane stays local after the Mac's network name changes. Corta
  compared the name a shell reported when it started with the name the Mac
  has now, so after joining another network a local pane could show a
  remote host in its title, open new tabs in your home folder and ask to
  connect to your own Mac over SFTP to open a file.

- Opening the Shell menu no longer checks the current directory on disk.
  A directory reported on an unreachable automount (`/net/…`) froze Corta
  until the mount timed out. **Change to Project Root** and **Open Project
  Root in New Pane** are enabled whenever the directory is known, look for
  the project after you choose them, and say so when there is none.

- Directory history keeps at most 1 000 directories besides favourites,
  dropping the least visited. The directories come from what the shell
  reports, so output that reported a new one on every prompt grew the
  history file, and the work of saving it, without limit.

- The warning before a multi-line paste is no longer switched off by what a
  program prints. Bracketed paste mode — under which the warning is not
  needed — could be turned on by any output, `cat` of a file included, and
  stayed on under a shell that does not support it, such as the bash that
  ships with macOS. Each finished command now turns it off; shells that
  support it turn it back on for the next prompt.
- A large paste no longer leaves the shell stuck in paste mode. A paste is
  sent in pieces, and when a program was slow to read — Claude Code or zsh
  with several megabytes on the clipboard — Corta stopped part-way, after
  the marker that opens a paste and before the one that closes it, so
  every key after it, Return included, was taken as more pasted text and
  the pane looked frozen. A paste is now sent whole or, if the program has
  stopped reading, not at all, with the same notice as before; a dropped
  file or Services text, which was discarded without a word, gets the
  notice too.

- Ctrl-C, Esc and the other keys work again after a full-screen program
  quits. A program that switched on the Kitty keyboard protocol and left
  the alternate screen without switching it off — which the protocol
  allows — or that crashed or was killed while it was on, left the shell
  receiving its keys in that encoding until `reset`. Each screen now has
  its own setting, as in kitty, and a finished command clears the main
  screen's.

- The scroll wheel scrolls `less`, `man` and `git log`. On the alternate
  screen, with mouse reporting off, the wheel moved through Corta's own
  history, which that screen does not have, so nothing happened; it now
  sends arrow keys, as Terminal.app and iTerm2 do. A program can turn this
  off with `ESC [ ? 1007 l`.

- Scrolling with a trackpad in vim (`mouse=a`), tmux and other programs
  that read the mouse moves at the right speed. Every trackpad event, the
  tiniest movement and the momentum after a flick included, was sent as a
  whole wheel notch; movement now adds up into notches as it does for
  scrolling Corta's own history.

- The window title no longer shows "remote?" while a pipeline such as
  `git log | less` runs. The command naming the job had already finished,
  and a job without a name was treated as a possible remote session.

- Shell integration for bash works when bash starts as a login shell,
  which is how Corta starts it. The hooks were only in `~/.bashrc`, which
  a login bash never reads, so unless your `~/.bash_profile` sourced it,
  prompt marks, command jumps and notifications never started. They now
  also go into the file a login bash reads — `~/.bash_profile`,
  `~/.bash_login` or `~/.profile` — and Settings shows **Update** for an
  integration installed only in `~/.bashrc`. The hooks run only in an
  interactive bash, so `bash -lc` output is untouched and other shells
  reading `~/.profile` skip them. A command no longer appears to start
  while the startup files run, or once per part of a `PROMPT_COMMAND` you
  set yourself, and `a; b` is one command. **Remove** clears the hooks
  from every file bash may have been given them in, and deletes a file
  only if Install created it.

- Emoji are sharp and fill their two cells. They were drawn at the text
  size and then scaled down on the GPU to fit, which left them smaller than
  the text around them and slightly soft. An emoji written with the emoji
  variation selector after a character that is text by default — 🖼️, ✍️,
  ❤️ — is still counted as one column, as `wcwidth` and the shell count it,
  but now draws at full size into a blank cell after it instead of
  shrinking into its own.

- The command palette's search field sits at the top of the panel. It was
  a whole title bar height lower, leaving an empty band above it.

- The window title stops naming a program once it has exited. A program
  that finished and returned to the prompt within half a second of the
  title's last update — `kitten icat`, say — stayed in the title until the
  next output.

- `kitten icat` shows images again. kitty's own client sends an image in
  128 KiB pieces, far past the 6 KiB a single piece was allowed, so any
  image above about 4 KB was silently discarded — in 1.0.0 and 1.0.1 too.
  And after an image, the cursor now moves below it as it does in kitty,
  scrolling the screen when the image reaches the bottom, instead of
  staying where the image began so the prompt was drawn over it. Each
  image `icat` shows now stays on screen; before, every one shared a
  single slot and the next took the last one's place.

- `clear` no longer leaves a faint vertical line at the left edge of the
  window (#165). Shell integration's prompt marks outlived the text they
  sat beside: clearing the screen kept every earlier command's green or
  red rule on the now-empty rows, and `clear`'s own result coloured the
  empty row it had been typed on. Clearing the screen now removes the
  marks with the text. The grey rule on the current prompt — and on the
  row a command's output starts — is gone too: a mark now appears only
  once a command reports, green for success and red for failure. After
  zsh's or bash's ⌃L, or Clear Screen (⌘K), the next command is marked on
  the prompt it was typed at.

- Closing a window or a pane now frees its memory. The terminal view held
  on to itself through its own keyboard handler, so every closed pane
  stayed in memory with its drawables until Corta quit — about 33 MB a
  window on a Retina display. Opening and closing four windows grew the
  app from 63 MB to 193 MB; it now stays where it started. 1.0.0 and 1.0.1
  have the same leak.

- With fish 4 and Corta's shell integration for fish, each command is now
  recorded once. fish 4 marks its own prompts, so every prompt arrived
  with two sets of marks, and the second opened and closed a phantom
  command that had never run. "The last command" and command history found
  that empty command instead of the real one. The fish integration now leaves the marks to fish
  when fish sends them, and Corta counts a doubled mark once, so an
  integration installed by an earlier version works too. An empty line in
  fish no longer leaves a command that looks as if it is still running.

- A fish prompt that shows the last command's exit status shows it again
  with Corta's shell integration installed. The integration ran its own
  commands before drawing the prompt, so `$status` and `$pipestatus` always
  read 0 there — fish's default prompt never showed a failure in red. The
  prompt is now drawn first.

- Settings ▸ Terminal ▸ Shell Integration now says when the installed
  hooks differ from this version's, and offers **Update**, which replaces
  them where they sit in the rc file (an edit made inside the block is
  replaced too), beside **Remove**. Corta never rewrites that block on its
  own, so until now a fix to the hooks — the fish ones above — never
  reached anyone who had already installed them.

- VoiceOver can now reach the buttons on the Settings page's status rows —
  Install, Remove and Update for shell integration, and Clear for the
  directory history. The row was one element that read its message, and
  hid its button.

- Frames no longer wait behind a flood of output. Drawing a frame reads a
  few pieces of the terminal's state besides the screen — the bell, the
  running command, the palette — and those reads could queue behind the
  thread reading the child's output for most of a frame. Under a `yes`
  flood a frame took about 6 ms to prepare (2.4 ms in 1.0.0); it now takes
  under 0.1 ms, with the same output throughput.

- Clearing the screen now clears its images. `clear`, zsh's ⌃L and Clear
  Screen blanked the text but left every Kitty graphics image (`kitten
  icat`) drawn over the empty screen; now, as in kitty, an image that
  reaches the visible screen is removed with it, while one scrolled wholly
  into history stays, and clearing the scrollback removes the images there
  (#161). As in kitty, an image nothing shows any more is freed with it, so
  drawing and clearing images over and over no longer fills the pane's
  image memory until new ones are refused.

- A pane that could not start — its failure message showing — no longer
  takes the whole app down when the font size changes (⌘=, ⌘-, or the
  configuration file) or when focus moves to it: both reached the pane's
  missing session or renderer.

- A pane with shell integration no longer freezes when the machine's name
  resolver is slow or unreachable. Every prompt's working-directory report
  (OSC 7) looked this machine's name up through DNS, on the thread that
  reads the shell's output, and on a machine where that lookup waited for
  a timeout the pane showed nothing for as long as 40 seconds. The name
  now comes from the kernel (`gethostname`), which is what the shell
  itself reports.

- The Quick Terminal no longer stays behind on a display that is gone. Its
  frame was computed when it was summoned and never revisited, so
  unplugging a display, changing its resolution or changing which display
  is the main one while the panel was open could leave it at coordinates
  no screen contained. It now repositions itself when the display
  arrangement changes, keeping the screen it is on when that screen still
  exists.
- A cancelled SFTP download sometimes left the server's file handle open.
  The CLOSE it owed was allocated a request id that a finished request's
  cancellation handler had already marked as refused, so the session
  resolved it as cancelled without ever putting it on the wire and nothing
  recorded that it had been dropped. Request ids now identify one
  allocation rather than a number that is handed out again and again, so a
  cancellation arriving late — for a request that has finished, or for an
  id since reissued to another transfer — can no longer speak for whoever
  holds it now.
- Two races in the SFTP session, found by looping its tests under the
  thread sanitizer on a saturated machine. The in-flight window counted
  requests from the moment they registered a reply waiter rather than
  from the moment they were admitted, so a burst of concurrent senders
  could all pass the check at once and the window bounded nothing. And a
  request cancelled between admission and registration had its id
  recycled at once, so the next request — the CLOSE after an aborted
  download, in practice — could take that id, find the cancellation
  marker meant for the other request, and fail as cancelled without ever
  being sent, leaving the server's handle open.
- The nightly sanitizer job had failed every run since 2026-09-15: the
  SFTP test rig's idle-read deadline was a fixed 10 seconds that a
  sanitizer-slowed, fully loaded runner exceeded while nothing was
  wrong. Its deadlines now scale with `CORTA_TEST_TIMEOUT_SCALE` like
  every other test ceiling, and three transfer tests that assumed the
  window's READs arrive in offset order assert the resume offset itself.

### Security

- Reject stale search status and repeated/concurrent SFTP handshakes; cancel
  pending handshakes and keep slow directory mounts off the UI thread.
- Bind remote-edit upload approval to a private content snapshot and compare
  remote content digests, including changes with identical size/timestamp.
- Create private download partials, tighten managed copies and manifest modes,
  and refuse existing directory-download destination symlinks.
- Bound glyph clusters before shaping and reject oversized ink before eviction;
  build Unicode row strings once and reuse reflow scratch buffers.
- Correct restoration/export privacy documentation and add regression,
  sanitizer and isolated SSH/SFTP validation evidence.
- Synchronize the live color palette between settings changes and the
  renderers that read it; the unit tests no longer read or write the
  development build's own configuration.
- Downloads to volumes without ACL support (exFAT, FAT, some SMB shares) and
  into a download folder that is itself a link work again; remote-edit
  copies from 1.0.x no longer report a conflict on every upload; a pane whose
  directory probe waited on a slow mount gets its proxy icon once there is
  room; approval snapshots left by a quit are removed at the next launch.

## [1.0.1] - 2026-09-21

A patch release: three fixes, no new features, no configuration change.
It is planned as the last release that runs on Intel Macs — the 1.1.0
milestone builds for Apple silicon only (issue #108) — and it is the
first release signed into the update feed from CI rather than by hand
(D20).

### Fixed

- `theme.<name>.<variant>.cursor` now colours the cursor. The key was
  documented, parsed and written back by the Settings page, but the
  renderer painted a fixed grey for every style, so a theme's cursor
  colour — including the built-in themes' own — never reached the screen.
  The block cursor keeps its translucency over the character under it;
  the bar and underline styles draw the colour as it is.
- Installing or removing the shell integration, and every Settings-page
  write to the config file, now edits the file a symbolic link points at
  instead of replacing the link with a plain file. A `~/.zshrc` or
  `~/.config/corta/config` kept in a dotfiles repository stays the
  repository's copy, and the file's permission bits survive the write.
- The directory history is written half a second after the last command
  finishes, on a background queue, instead of being encoded and written
  to disk inside the frame that noticed the command end. A burst of
  commands with shell integration on is one write, not one per command,
  and none of them sits on the render path. Quitting writes anything
  still pending.

### Changed

- Publishing a GitHub release now signs it into the Sparkle update feed
  from CI: the `Update feed` workflow runs after the maintainer publishes
  the draft, waits for their approval of the `release` environment, signs
  the archive with the key held there, checks the feed item against the
  shipped app, and merges `appcast.xml` through a pull request. Signing
  by hand with `scripts/release.sh` is the fallback rather than the
  route. Decision D20 records where the key lives and what that costs.

## [1.0.0] - 2026-09-19

Sixteen batches (`B01`–`B16`) on top of 0.1.1: explicit session and
input semantics, shell integration and command navigation, one config
file for everything, a Metal 4 backend, remote context with SFTP and
remote editing, open-source packaging, and system entry points. esctest2:
126 passed, 334 known bugs, 107 failed of 567 (81.1%), every failure a
subset of 0.1.1's. The entry as released, with the evidence behind each
line, is in [the record](https://github.com/noah-qin/Corta/blob/f632d5918653cc2feee28fe1baa0c0fd01e93c0e/docs/history/2026-09-19-V1.0.0-CHANGELOG-FULL.md).

**Known at this release:**

- Keypress-to-glass latency is above its target: 66.3 ms average typing, 61.9 ms scripted (`docs/PERFORMANCE.md` §5.6).
- ⌘, once failed to open Settings for one tester; not reproduced since.
- VoiceOver's *Read selected text* needed one more listening pass to confirm the fix below.
- Multi-display Quick Terminal placement and thermal forcing were not judged.

### Added

- TUI mouse drag and motion tracking (`?1002`/`?1003`), with an Option-drag selection override (`mouse-override-modifier`); SGR encoding alone no longer turns on mouse reports.
- Keypress-to-glass latency measured inside the app (`CORTA_RENDER_METRICS=1`, `scripts/measure-keypress-latency.sh`); render-metric dumps include p95.
- App Intents for Shortcuts: Open, Focus and Toggle Quick Terminal; windows are addressed by a saved identity, and no intent sends text to a shell.
- The Quick Terminal: a floating panel on every Space, summoned by a hotkey (`quick-terminal-key`), off by default (`quick-terminal`).
- Secure Keyboard Entry under Shell (`secure-keyboard-entry`), with a titlebar lock while it is engaged.
- `scripts/check-release.sh`: one implementation of the release rules, used by local packaging and CI alike; the release notes read the minimum macOS from the built app.
- Documentation split into durable documents and a dated record (`docs/README.md`, `DECISIONS.md`, `TROUBLESHOOTING.md`, `docs/history/`), plus issue and pull request templates.
- A Metal 4 rendering backend (`CORTA_METAL4=1`), pixel-equivalent to the default path; no speedup is claimed.
- Render pipelines shared across panes: a new pane no longer pays ~10 ms of shader compile. Provably empty render passes and redundant Metal 4 state changes are skipped.
- Measurement seams `CORTA_FRAME_LATENCY` and `scripts/measure-energy.sh`.
- SFTP over the system `ssh`, with no SSH library: Shell ▸ Browse Remote Files…, upload and download with progress, cancel, retry and a conflict sheet, atomic partial files and validated resume, and whole-folder transfers that never follow links.
- The first connection to a host in each run is asked, with the name editable; Corta never connects on a remote shell's say-so.
- Remote editing: a remote file opens as a managed local copy, and changes go back only by explicit upload after the remote is re-checked.
- Remote context: a pane shows which host it is talking to (`⟂ host · directory`), from OSC 7 or the foreground `ssh`/`mosh`; local paths never pick up a remote directory.
- Command records carry their host, and Command History can filter by it.
- Shell ▸ Reconnect to Host re-runs a dead connection's exact command as a new connection.
- Every non-English string is marked `needs_review` until a native speaker reads it; `CONTRIBUTING.md` explains the convention.
- Directory history ranked by frecency, with favourites and fuzzy filtering (`directory-history`, clearable in Settings).
- Safe app-initiated `cd`: only when shell integration is active, nothing is running and the prompt is untouched.
- Command records (`OSC 133`) with exit status, timing and directory; Snapshot Running Command's Output.
- Settings ▸ Terminal ▸ Shell Integration installs, diagnoses and removes the zsh script, reversibly.
- A child that exits on its own shows a toast; `TerminalSession.write` reports accepted, backpressured or stopped, and pastes are sent in bounded chunks.
- User-visible performance targets (`docs/PERFORMANCE.md` §1.1), the recorded toolchain, a wider real-workflow test matrix, and PNG attachments on render-test failures.
- OSC 4/104 (indexed palette) and OSC 5/105 (special colours) query, set and reset; an OSC 4 override repaints.

### Fixed

- ⌘+/⌘−/pinch zoom no longer changes the saved default or other windows; ⌘0 returns to the current setting, and a zoom no longer survives a relaunch.
- The scrolled-away viewport stays on the text it showed as output arrives; typing or pasting returns to the bottom.
- Settings rows are one height; sections, status rows, scroll position and the font preview's spacing corrected.
- "Open file with" is validated when the edit is committed, so `{file}` can be typed.
- A settings change refreshes the page once, and opening the window runs its setup once.
- The Quick Terminal position reads "Center".
- The Quick Terminal appears beside a full-screen application.
- The close confirmation's subject is localised.
- VoiceOver's *Read selected text* reads a real selection.
- `CSI n X` (ECH) is implemented; tmux's status line no longer keeps stale text.
- An ssh failure is classified after its last stderr line is read.
- The SFTP browser reports a refused login as an authentication error, not a lost connection.
- A restored tab group keeps its order and selected tab, and every tab lays out below the tab bar.
- A reopened window no longer shows the desktop through it for one frame.
- ⌘+/⌘− keep the window's top edge in place.
- Command History shows each command's text and can search it.
- The menu bar is localised; the Bell picker shows a localised name; Chinese wording corrected.
- VoiceOver announces the last change of a burst of output.
- The energy and app-baseline scripts no longer touch the real config or window arrangement.
- A restored or preset window's first pane starts in the right directory and shell.
- A selection drag ends when the window loses key status, or when its pane closes.
- `BS`/`CUB` reverse-wrap under `?45`, and the mode survives the alternate screen.
- `CSI s` / `CSI u` save and restore the cursor.
- Search case-sensitivity and regex mode are per pane.
- Esc closes only the focused pane's search bar, in a split or across windows.
- Output at the tail of a burst is searched.
- Closing search restores the scroll position to the same text.
- Large copy and export no longer stall input; an open export panel is cancelled if its pane closes.
- The selection highlight and the copied text agree once the scrollback is full.
- A column-resize reflow clears the selection and scroll position.
- Tab resolved by a candidate UI (e.g. a slash-command menu) reaches the child.

### Changed

- Selection copying uses the same scrollback coordinate mapping as the viewport, search, commands and images.
- CI and the nightly checks use the same pinned, released Xcode.
- Vim mouse selection, Option-drag selection and clipboard copy confirmed by hand.
- The project overview, feature reference and contributor guide reorganised; a testing guide and link checks added.
- The configuration reference lists every `bind.` command; `DocumentationDriftTests` fails when a key or command loses its row.
- Documentation audit: checklist records, numbered design headings, newest-first security log.
- Dated verification passes moved from `docs/CONFORMANCE.md` to `docs/test-results/`; the TextKit evaluation became decision D19.
- A local Release build is signed for development; Developer ID signing belongs to the release workflow. The "Missing Localizability" check is on.

## [0.1.1] - 2026-09-09

The quality release. Nothing here changes what Corta is; all of it is
work on what was already there — the places it could be made to
misbehave, the places it was slower than it had to be, and the places it
was guessing at what the user meant.

**Upgrading.** No configuration change is required and no config key
changed meaning. Everything below is additive or a fix; a `~/.config/corta/config`
written for 0.1.0 keeps working unchanged.

Two things worth knowing before you read the list. `option-as-meta`
existed in 0.1.0 and **did not work** — if you tried it and gave up, try
it again. And the terminal answered `XTVERSION` with `Corta(0.1.0)`
regardless of the build; it now answers with the version it actually is,
which matters to anything doing capability detection.

### Added

- **Every string translated into all nine shipped languages.** The
  commands, settings and toasts added in this release had shipped in
  English only — 41 keys against 156 that were complete. A test now
  checks the whole catalog rather than a sample, including that each
  translation carries the same format specifiers as its source.

- **U11 (2026-09-08)** — Clear Screen (⌘K), Clear History and Reset
  Terminal, as three separate commands with a table in
  `docs/CONFIGURATION.md` §5 saying what each one discards. They act on
  Corta's grid, not on the child's input, so a running job is undisturbed.
  Clear History and Reset ship unbound and ask before discarding history,
  honouring `confirm-close`.
- **U12 (2026-09-08)** — A **Match Case** toggle in the Find bar, backed by
  `search-case-sensitive`; and a pill in the corner of a scrolled pane
  saying how far back the viewport is, changing its wording when new output
  has arrived, and returning to the live screen when clicked.
- **U13 (2026-09-08)** — Zoom Pane (⇧⌘⏎): fills the window with the focused
  pane and puts the split back. Temporary — no pane is closed, no child
  disturbed, and the saved arrangement still describes the splits.
- **U14 (2026-09-08)** — Copy Last Command Output, and Previous/Next Failed
  Command (⇧⌘↑ / ⇧⌘↓), on the OSC 133 marks Corta already records.
- **U15 (2026-09-08)** — Reopen Closed Pane (⇧⌘T), which restores the
  arrangement a closed pane had and never claims to restore its process;
  and Export Text… (⇧⌘S), which writes the selection — or the whole
  scrollback — to a file.
- **U16 (2026-09-08)** — Regular-expression search behind a `*` toggle
  (`search-regex`), budgeted and cancellable, with a per-line length bound
  and a distinct "bad pattern" state; and named shell/directory/environment
  presets (`preset.<name>.*`) under Shell ▸ New Pane with Preset; holding ⌥
  opens one in a window of its own.
- **U17 (2026-09-08)** — ⌘-click on `path:line:column` in program output
  opens the file, optionally through `open-file-command`. Local only: a
  pane inside `ssh` resolves nothing. The URL scheme allowlist is unchanged.
- **U05 (2026-09-08)** — `option-as-meta` is now readable from the config
  file and has a switch in Settings; it was previously written but never
  parsed, so setting it did nothing.
- **U04 (2026-09-08)** — Application keypad mode (DECKPAM / DECKPNM). The
  keypad sends its SS3 forms to programs that asked for them via `smkx`.

### Fixed

- **U01 (2026-09-08)** — The accessibility rectangle for a range ending on a
  wide character clipped half of it: three CJK characters were outlined as
  five cells instead of six. Found by probing the running app through the
  accessibility API, not by a test — the unit test's stub made the wrong
  answer look right.
- **U14 (2026-09-08)** — `OSC 133 ; C` is now recorded, so the last
  command's output is read rather than guessed at one row past the prompt; a
  two-line prompt no longer leaks its second line into the copy. Scrolled
  back, the command copied is the one on screen.
- **U16 (2026-09-08)** — A regular expression whose shape makes a
  backtracking engine take exponential time is refused before it runs and
  reported as too slow, rather than pinning a thread for the life of the
  app: neither `NSRegularExpression` nor Swift's `Regex` exposes ICU's time
  limit, and measurement showed no input length small enough to bound one.
  A sweep that merely runs long stops on a time budget and says its count is
  a floor.
- **U17 (2026-09-08)** — `open-file-command` is validated when it is set, not
  only when it is run, and has a Settings field.
- **U01 (2026-09-08)** — Accessibility hit-testing converted a *screen*
  point as if it were a window point, and both directions of the
  UTF-16-offset-to-column conversion assumed the two counts were equal —
  wrong for any CJK, emoji or combining text. The exposed text also ignored
  the scroll position, so a screen reader scrolled into the history read
  the live screen.
- **U02 (2026-09-08)** — The preedit overlay carried a copy of the cell
  metrics that nothing read; sizing came from the cursor rect all along.
- **U07 (2026-09-08)** — The window arrangement was written only at quit —
  the one moment a crash never reaches — and the state file was deleted at
  launch, so a crash lost it entirely. It is now written debounced as the
  layout changes, with a marker file separating "crashed during a restore"
  from "crashed at any other time". Restored geometry and split trees are
  validated: non-finite or impossibly small frames, divider fractions
  outside a usable range, and trees nested past 12 levels are repaired.
- **U08 (2026-09-07)** — Three shortcuts were hard-coded and so outlived
  their bindings: ⌘V pasted even after Paste was rebound or unbound, ⌘↑
  scrolled to the top of the scrollback once Previous Command was unbound,
  and ⌘F opened the Find bar after Find was rebound.
- **U09 (2026-09-08)** — A pane that failed to start was silent to a screen
  reader and left nothing focused for the keyboard.

**Found while publishing.**

- **An update for 0.1.0 users would never have arrived.** Sparkle compares
  `CFBundleVersion` — the build number — and `CURRENT_PROJECT_VERSION` had
  been 1 since 0.1.0 and was still 1 here, so 0.1.1 looked to every
  installed copy like the version it was already running.
  `generate_appcast` showed it plainly: it overwrote 0.1.0's feed entry
  instead of adding one. The build number is 2 now, a test refuses a build
  number a 0.1.0 install could not be offered, and the release checklist
  names all three version numbers instead of two.

**Found by the Stage 4 audits.**

- The terminal answered `XTVERSION` with `Corta(0.1.0)` whatever version it
  was built as, because that string is written by hand in two places and
  only one of them had moved. A test pins `CortaVersion.string` to the
  bundle's version now, so they cannot drift apart silently again.
- **DECID (`ESC Z`)** went unanswered. A query that is silent leaves a
  client waiting for a reply that never arrives; it answers exactly what
  `CSI c` answers.
- **DECALN (`ESC # 8`)** was not implemented at all — every escape sequence
  carrying an intermediate byte was discarded with the charset designators.
  It fills the screen with `E`, resets the margins and homes the cursor,
  which is how a program asks for a completely known screen.

**Found by using the app, in the manual verification pass (2026-09-09).**
Four defects that no test in this repository would have caught, listed in
the order they were met:

- **Option as Meta had never worked.** With `option-as-meta = true`, ⌥F
  typed `ƒ` instead of sending `ESC f`. The encoder handled the setting
  from the day it shipped and the key event never reached it: an ⌥-only
  press carries neither ⌘ nor ⌃, so it went to the input context first,
  macOS composed the layout's alternate character, and it came back as
  text. On a US layout that is most letters — the setting was inert for
  exactly the keys people enable it for. ⌥ now bypasses the input method
  when, and only when, ⌥ is Meta; with the setting off it still reaches
  the input method, which dead keys and international layouts depend on.
- **Marked text was unreadable in a light appearance.** The IME preedit
  overlay drew in a fixed near-white, from a stored copy of "the colour
  the renderer uses" that stopped being true when the palette started
  following the theme and the system appearance. It reads the live
  palette now.
- **Text grew and shrank through a window zoom.** For a layer-hosting
  view AppKit owns the layer's `contentsGravity` and derives it from
  `layerContentsPlacement`, whose default is "stretch what you are
  holding to whatever size you have just been given" — so the last
  presented frame was scaled up for the length of the animation. The
  placement is set through AppKit now, and the canvas no longer animates
  its own geometry.
- **`commandOutputRows(before:)` could answer with the wrong command.**
  Scrolled above the first prompt, "copy the command in view" copied the
  *newest* command's output, because the lookup fell back to the last
  prompt when the bound was above every prompt.

### Verification

- **Keypress → pixel (2026-09-09)** — an external screen-capture tool at M6.12's settings
  against the Release build: **57.8 ms average, 45.3 ms min, 78.9 ms max,
  5.6 ms SD** over 200 samples, with `PERFORMANCE.md` §5.2's environment
  table held and recorded in full for the first time — machine and chip,
  OS, build, panel and refresh rate, scale, font, window, power source, and
  the test program (`cat > /dev/null`). That is 12.3 ms above M6.12's
  45.5 ms, and §5 records why the comparison is softer than it looks:
  M6.12 recorded its capture settings and not its test program, and no
  run has recorded the machine beyond "MacBook Air, Apple silicon". The
  same run is the re-measurement M9 has owed since it landed.
- **Manual verification (2026-09-09)** — the six checks in
  `docs/history/V0.1.1-MANUAL-VERIFICATION.md`, run by the maintainer. VoiceOver
  reads the grid with correct row and column, and its cursor box covers a
  wide character whole. The IME candidate window follows the preedit across
  font-size changes, both panes of a split, and fullscreen. A German layout
  composes dead keys and its option characters with `option-as-meta` off,
  and sends Meta with it on. `copy-on-select` keeps its default. Composing
  Chinese is indistinguishable from Terminal.app and Ghostty. What was not
  judged is recorded as not judged.
- **esctest (2026-09-08)** — 112 passed, 335 known bugs, 121 failed of
  568, against M6's 106 / 335 / 127. xterm-compatibility is 78.7%, up
  from 77.6%. The failures are classified by real application impact in
  `docs/history/V0.1.1-QUALITY-PLAN.md` Q01, and every failing test name is kept
  in `docs/esctest/0.1.1-results.txt` so the next run is a diff. The
  largest single cause is one absence: OSC 4/5 indexed palette set and
  query are not implemented.
- **Nightly CI (2026-09-08)** — a lane for the checks a pull request
  cannot carry: the core suite under thread and address sanitizers, and
  a twenty-million-iteration fuzz run on a rotating seed. Both are clean;
  the sanitizer lane found a test that had been asserting a property it
  never established, and it is fixed. Pull-request checks gain job
  timeouts, `contents: read`, and the `.xcresult` bundle and fuzz corpus
  uploaded on failure.
- **Real-workflow harness (2026-09-08)** — 12 passed, 1 skipped, 0
  failed against zsh, fish, tmux, Neovim, vim, less, fzf, mouse
  reporting and 20k lines of sustained output, each driven on a real PTY
  and replayed through the core. `corta-dump --serve` answers a client's
  terminal queries from that same core, which is what lets fish — which
  waits for Primary DA before it prints a prompt — run under it at all.
- **Same-machine comparison (2026-09-08)** — 19.1 MB through the tty:
  Corta 0.204 s, Ghostty 0.164 s, Terminal.app 0.305 s, with Corta the
  smallest resident set of the three at idle. Input latency was measured
  separately (above); IME across terminals has no measurement and was
  compared by eye.

### Changed

- **UI02 (2026-09-06)** — The Find bar's glass is now tinted with the
  window background (fully opaque only under Reduce Transparency), and its
  match-count label uses the secondary label colour instead of tertiary, so
  the query and "n/m" stay readable over bright terminal output in both
  light and dark themes.
- **UI03 (2026-09-06)** — The active-pane focus ring is drawn at half
  accent-colour strength instead of full-strength blue, so it marks the
  pane without outshouting the text it frames; full colour returns under
  Increase Contrast.
- **UI06 (2026-09-06, extended 2026-09-08)** — The Shell menu is regrouped
  as presets, create (splits), move (focus moves, then the command jumps),
  terminal state (U11), resize (zoom, grow/shrink pairs, then Equalize
  Panes); command jumping no longer sits behind the geometry group.
- **UI07 (2026-09-06)** — View's separate Theme and Appearance submenus are
  merged into one Theme submenu: the appearance choice (Follow System /
  Light / Dark) heads the list, the themes follow below a separator, each a
  plain checkmarked single choice.
- **C03 (2026-09-06)** — Removed the assertion-less `testExample` template
  test from `CortaUITests`.

## [0.1.0] - 2026-09-05

The first release. Everything below is what `main` accumulated through
M1–M10.

### Added

**Terminal engine**
- A hand-written VT parser covering VT100/VT220 through `xterm-256color`,
  with 256-colour and true-colour SGR.
- Query responses — DA1/DA2, DSR, DECRQM, DECRPM — answered in fixed
  format and never echoing stream-supplied bytes. DECSCL gates DECRQM: a
  program that announced VT200 is answered as VT200.
- IRM (insert mode) and LNM (newline mode) are implemented, not just
  parsed; DECRQM reports their live state honestly, and KAM/SRM report
  permanently reset rather than staying silent. DSR operating status
  (`CSI 5 n`) and DECXCPR (`CSI ? 6 n`) are answered — both were silent,
  which reads as a dead terminal to a program that polls them.
- Unsupported colour spaces (`rgbi:`, `CIELab:` and kin) are refused with
  a documented policy rather than silently ignored.
- The kitty keyboard protocol, so editors can bind `Ctrl+I` and `Tab`
  apart.
- OSC 8 hyperlinks, bracketed paste, focus reporting, alternate screen,
  scroll regions, tab stops, and the mouse reporting modes.
- Lines carry a `wrapped` flag, so reflow, selection and search agree on
  where a logical line begins and ends.
- Cells are a fixed 16 bytes; grapheme clusters and hyperlink ids spill to
  interned side tables. `CellLayoutTests` asserts the size.
- Scrollback with eviction, and incremental reflow on resize.

**Rendering**
- Metal renderer: a GPU glyph atlas, instanced quads, one draw call per
  screen, and a triple-buffered instance buffer.
- Damage tracking at line granularity — a static screen rebuilds nothing,
  and idle CPU measures 0.0%. The check itself compares a per-row
  revision stamp (`Grid.lineRevision`, bumped centrally by `ScreenLines`)
  rather than full row contents, and a whole-screen scroll shift
  repositions surviving rows by a Y-coordinate offset instead of
  rebuilding them through Core Text/atlas lookups.
- `CAMetalDisplayLink` in place of `CADisplayLink` +
  `metalLayer.nextDrawable()`, gated on window occlusion without ever
  pausing the PTY reader thread.
- Compiled render pipelines are cached to disk (`MTLBinaryArchive`) and
  read back on a later launch instead of recompiled.
- The glyph atlas is split into independently packed, independently
  evicted pages (ASCII, shaped/CJK, colour), so a CJK-heavy screen no
  longer evicts the ASCII cache and vice versa.
- The frame-rate range adapts to window focus, Low Power Mode, thermal
  pressure and an active trackpad scroll gesture.
- `RenderMetrics`: ring-buffer percentiles for drawable-wait, frame-CPU
  and GPU time, dumped to the unified log behind `CORTA_RENDER_METRICS`
  — a before/after number without opening Instruments each time.
- Cursor styles (block, bar, underline) with blink; bold, italic,
  underline and strikethrough; selection drawn as document-anchored quads
  that follow their text as output scrolls.

**Graphics**
- The Kitty graphics protocol: images placed and displayed inline via
  the APC-based control/payload sequences, verified against a real
  client (`kitten icat`), which found and fixed four protocol bugs no
  hand-written test had caught.

**Text and input**
- Full `NSTextInputClient` conformance: marked text, a candidate window
  positioned under the cursor in any split, and preedit rendered as an
  overlay that is never committed to the grid.
- Correct East Asian character widths, combining marks and emoji
  presentation, with Core Text font fallback.
- Mouse and keyboard selection — drag, double-click word, triple-click
  logical line, shift-click extend — anchored to document rows.
- Copy joins soft-wrapped lines into one and trims trailing blanks.
- ⌘-click to open a URL, behind a scheme allowlist.
- Pinch-to-zoom, and file drops that insert a correctly quoted path.

**Window and application**
- Splits as a binary layout tree, with geometric focus movement and input
  routed to the focused pane only.
- Search across the scrollback.
- A native settings page and colour themes — Corta, Solarized and Mono,
  each in a light and a dark variant.
- Configuration in one text file at `~/.config/corta/config`, watched for
  external edits. The settings page is a front over that file and holds no
  state of its own.
- `columns` and `rows` in the config file, and a "New window" row in
  Settings: the grid a new window opens with, in cells. It was hardcoded
  at 120×30. The window's pixel size is that grid times the font's cell
  metrics, so two terminals showing the same grid are still different
  sizes on screen when their fonts differ.
- [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md) — every config-file
  key: its values, its default, when it takes effect, the theme and
  keybinding key families, the full command table with default
  shortcuts, and what is deliberately not configurable.
- A long-running-task notification, off by default.
- Shell integration (OSC 133): prompt and exit-status marks in the left
  edge of each prompt row, ⌘↑/⌘↓ to jump command to command, and an exact
  long-task notification when the shell reports boundaries. The
  keystroke-and-idle heuristic remains for shells with no integration
  configured.
- Session restore — windows, split layout, divider proportions and each
  pane's working directory — and a Dock click that reopens a window when
  none is open.
- A confirmation before closing a pane, window or the app while a shell
  still has a foreground job.
- A command palette (⇧⌘P) over every command Corta has, grouped (Recent,
  Window, Panes, View, Edit, App) with recent-use tracking, an empty
  state instead of a blank table, and arrow glyphs for navigation keys
  instead of `LEFT`/`RIGHT`.
- Help > Keyboard Shortcuts (⌘/): every command, grouped, with the key
  that runs it — unbound commands included — read from the same table
  the menus and the palette use.
- A copy confirmation. Copying — from ⌘C or from copy-on-select — shows a
  short-lived label in the corner of the pane, so the clipboard never
  changes with nothing to show for it.
- An About window of Corta's own: icon, version and build, the version the
  terminal reports over XTVERSION when it differs, links to the project,
  the release notes and the licence, and the copyright line the standard
  panel had no value for.
- Check for Updates…, under a signed feed ([Sparkle](https://sparkle-project.org)),
  and a daily background check you can turn off with `update-auto-check`
  in the config file. The one third-party dependency in the app shell;
  the terminal core has none.
- Rebindable keyboard shortcuts, `bind.<command> = cmd+shift+d` in the
  config file; an empty value unbinds.
- Themes defined in the config file, inheriting from a built-in so a
  two-line theme is a legal theme.
- Keyboard pane resizing by whole cells, and Equalize Panes.
- Copy on select, and `link-activation = click` — hovering a link
  underlines it and shows the target, and a click that never moved opens
  it. ⌘-click remains the default.
- OSC 52 clipboard *write*, off by default (`SECURITY.md` §2.6). The read
  form is not implemented and will not be.
- A first-launch offer to move Corta to `/Applications` when it is
  running unzipped somewhere else — direct-download distribution has no
  drag-to-install step, and both Sparkle's update path and Spotlight
  expect an installed location.

**Accessibility**
- VoiceOver and every other assistive technology can now read the
  terminal. `TerminalView` implements the text-area accessibility
  protocol — value, selection, insertion point, per-line ranges, and
  on-screen frames for a character range — from a snapshot gated on
  VoiceOver actually running, so the render path pays nothing otherwise.
- Reduce Motion, Reduce Transparency and Increase Contrast are honoured
  throughout: animations gate on Reduce Motion, the search bar and
  command palette take an opaque fill under Reduce Transparency, and
  status is never carried by colour alone (a symbol and a sentence come
  first, the tint last).

**Project**
- Golden-file grid tests, a fuzz harness (`corta-fuzz`) with a checked-in
  corpus, and a parse/memory benchmark (`corta-bench`) reporting
  p50/p95/p99/max over 2,000 samples rather than an average.
- `os_signpost` across the whole input chain — keyDown → PTY write → grid
  revision → MainActor wake → display-link callback → GPU completion —
  so a latency regression is one interval wide in a trace instead of
  invisible to every passing test. Coverage reaches every keypress path,
  not only the ⌘/⌃ control-sequence bypass: ordinary typing
  (`insertText`) and Return/Delete/Escape/the arrows (`doCommand(by:)`)
  are signposted too — a real-client trace of ordinary typing once
  showed zero `keyDown` events despite real keystrokes reaching the
  child, which is what exposed the gap.
- Apache 2.0 licence, a security policy, a code of conduct and issue and
  pull request templates.

### Changed

- **`copy-on-select` now defaults to `true`.** It was off because copying
  replaced the clipboard silently; the copy is now confirmed on screen,
  which was the whole objection. Set `copy-on-select = false` to restore
  the old behaviour.
- **One theme and one font are offered.** The settings page and the View
  menu list the `corta` theme, and the font family picker is gone: Corta
  uses the system monospaced face. Neither is a removal — `theme =
  solarized`, `theme = mono`, `theme.<name>.inherit = solarized` and
  `font-family = <any verified family>` all keep working from the config
  file. What is gone is Corta recommending faces and palettes it has not
  vouched for.
- The settings page is a tabbed preference window — Appearance, Terminal,
  General — that resizes to the tab it is showing. Every control sits in
  one value column, each explanation is one line under the control it
  belongs to, and the config file's path is pinned under a hairline at the
  bottom instead of scrolling away. It was a single scrolling page 534×819
  points tall for eleven settings.
- ⌘+ / ⌘− / pinch write the new font size to the config file. The size
  used to live only in memory, so the next config change of any kind
  reset the zoom and a relaunch forgot it.
- **Deployment target raised to macOS 26.0**, across every build
  configuration and the `CortaTerminal` package.
- A mouse drag now always selects text past an app-owned mouse
  reporting mode (SGR, etc.) — no modifier held, and no more terminals
  where a program that turned on mouse reporting (Claude Code, `vim`
  with `mouse=a`, `htop`) made its own output unselectable. A click that
  never leaves its starting cell still reports to the child as before.
- The General settings tab is grouped into Window / Closing /
  Notifications sections instead of one flat list.
- The focus ring is thinner (2pt → 1pt), gets a faint accent highlight,
  and only shows while a pane truly holds the keyboard — ⌘-Tabbing away
  now clears it instead of leaving it on the split's last-focused pane.

### Fixed

- `SGR 2` (dim) renders. The attribute was parsed and stored since M1 and
  drawn nowhere, so the secondary text every CLI marks this way — `git
  log`'s hashes, `ls -l`'s metadata, a spinner's hint line — came out at
  full strength.
- The Bell setting survives a rename. The chosen mode was recovered from
  the pop-up's *title*, which worked only while every display name was its
  raw value capitalised.
- Selecting a theme the settings page does not list no longer overwrites
  it. A config file naming an unoffered theme left the pop-up with nothing
  selected, and the next click on any control in the page wrote the first
  item back over the user's choice.
- The notification threshold is disabled while notifications are off, and
  says that it only fires for a background window.
- XTVERSION reports the real version. It was a string literal in the
  query code that a release bump had no reason to visit; it now comes from
  `CortaVersion`, next to the note about keeping it and `MARKETING_VERSION`
  in step.
- The Bell setting did something. The settings page wrote `bell` to the
  config file while the bell itself read a `UserDefaults` key, so changing
  it had no effect at all. There is now one store, as there was always
  supposed to be.
- Only font families that actually render on a grid are offered. The list
  was filtered by `isFixedPitch` on a family's *first* face, which let
  through families whose bold face is wider (bold text painted into the
  next column), families that are monospaced for letters but not digits
  (ragged TUI borders), and bitmap and colour faces (blurred or blank).
  Every ASCII advance is now measured across all four faces Corta draws
  with.
- Italics render. `SGR 3` was parsed and the attribute set, and the
  renderer had no italic path at all, so italic text drew upright.
- A family with no real bold or italic face gets a synthesised one rather
  than silently dropping the rendition.
- A glyph wider than its cell is scaled to fit instead of painting into
  the neighbouring column, and a scalar no font in the cascade covers
  draws a hollow box instead of nothing — output that looked lost.
- One "Settings…" entry in the menu bar instead of two; the theme and
  appearance lists moved to View. The settings page is grouped into
  labelled sections with explanations, and its window resizes and
  scrolls rather than truncating long font names at a fixed 460 points.
- The File and View menus no longer carry inert document and toolbar
  items. They did nothing in a terminal, and Page Setup's ⇧⌘P and Show
  Toolbar's ⌘T silently shadowed real commands.
- A flag emoji is one grapheme cluster again. A pair of regional indicators
  (`🇯🇵` = U+1F1EF U+1F1F5) was stored as two independent wide cells and
  occupied four columns instead of two, so every character after it on the
  line landed two columns late — visible as a broken box-drawn table.
  UAX #29 GB12/GB13.
- Switching the theme, or the appearance between light and dark, no longer
  leaves the terminal apparently blank. Cell colours are resolved into the
  instance buffer when a row is built, but only the clear colour was read
  fresh each frame: forcing a redraw without forcing a rebuild painted the
  new background behind the previous theme's glyph colours.
- No `fatalError` or `try!` on a pane's startup path. Metal absence, an
  atlas that fails to build, a `$SHELL` pointing at an uninstalled shell
  and a restored working directory on an unmounted volume all used to
  crash the app; the recoverable ones now degrade and the rest present a
  failure view with Try Again.
- A failed config write no longer reports success. The settings page now
  rolls the value back, shows the reason, and offers Retry — and "Show
  Config File" no longer reveals a location it failed to write.
- Notification permission is read, not assumed. The switch used to show
  "on" over a denied permission; it now says macOS is not delivering and
  links to System Settings.
- Window restore lands on a display that still exists, and the first
  restored window is a fresh window rather than the storyboard's — whose
  root pane had already spawned a shell in the home directory, which is
  the one thing a restore cannot repair after the fact.
- A `less` search match's reverse-video highlight renders. Reversing a
  cell whose colours were both `.default` — the common case for a plain
  highlight — re-resolved back to the same default colours regardless of
  the swap, so the highlight was computed but never visible.
- OSC 10/11/12 (background/foreground colour queries) answer with the
  live theme instead of a hardcoded dark palette, which had a program
  that queries its background before choosing its own colours (Claude
  Code among them) painting near-white text over a near-white
  background under the light theme.
- The focus ring no longer draws partly under the tab bar on a top
  pane, and no longer shows a false curve at a divider junction on an
  interior or edge pane — both now share the same chrome-overlap
  geometry the grid's own inset already used.
- A settings row whose label wrapped to two lines no longer silently
  loses the second line, and the notification-permission row no longer
  sits visible-but-empty the first time General is opened.
- A crash loading a cached render pipeline traced to the test target's
  own launch path (`CortaTests` `TEST_HOST`-launches directly into
  `Corta`, a more restrictive launch than opening the app) rather than
  real use; the cache now loads back on every real launch and only
  skips the one launch path that crashed.
- Switching settings tabs no longer tears the whole pane subtree down
  and rebuilds it on every click. Xcode's Thread Performance Checker
  flagged the remove-everything loop as a hang risk (the main thread
  waiting on a lower-QoS thread); panes are built once and now stay
  attached, shown and hidden instead of detached and reattached.

### Known gaps

- Core feed throughput is **130.0 MiB/s** (five-run mean), above the
  100 MB/s target; parser-only and parser+grid are measured separately.
- `esctest` xterm conformance is **77.6%** — 127 of 568 tests failing.
- An external screen-capture tool measures keypress-to-pixel latency at **45.5 ms average**
  (24.8 ms minimum, 56.4 ms maximum, 6.8 ms standard deviation), above the
  one-frame-plus-input target; the in-process path to the grid is 0.005 ms.
  Measured alongside iTerm2 (42.7 ms) and Ghostty (31.9 ms) on the same
  machine, Corta is currently the slowest of the three
  (`docs/PERFORMANCE.md` §5.5); Terminal.app could not be measured with
  the tool used.
- Frame CPU is **1.879 ms average** / 2.659 ms p95 for a full 120x40
  rebuild, inside the 4 ms budget.
- OSC 133 marks only appear if the user's shell emits them; Corta ships no
  shell snippets yet.
- `maximumDrawableCount = 2` measured within noise of the default —
  70.1 ms vs. 70.4 ms average across a real end-to-end A/B, so the
  default (3) ships (`docs/PERFORMANCE.md` §5.4). A 12-second real-typing
  `os_signpost` trace found no `output` → `frame` gap exceeding one
  frame period — no evidence, in that sample, of a redraw missing its
  display frame (§5.3). Neither of those two numbers is a controlled
  before/after against the 45.5 ms figure above: `docs/PERFORMANCE.md`
  §5.2's fixed-environment table (in particular, other background load
  on the machine) wasn't held for either run. The render-pipeline
  rewrite (M9) landed and is covered by its own unit tests, but a
  same-conditions end-to-end re-measurement against the 45.5 ms baseline
  is still open.

[Unreleased]: https://github.com/noah-qin/Corta/compare/v1.6.2...main
[1.6.2]: https://github.com/noah-qin/Corta/releases/tag/v1.6.2
[1.6.1]: https://github.com/noah-qin/Corta/releases/tag/v1.6.1
[1.6.0]: https://github.com/noah-qin/Corta/releases/tag/v1.6.0
[1.5.1]: https://github.com/noah-qin/Corta/releases/tag/v1.5.1
[1.5.0]: https://github.com/noah-qin/Corta/releases/tag/v1.5.0
[1.4.0]: https://github.com/noah-qin/Corta/releases/tag/v1.4.0
[1.3.1]: https://github.com/noah-qin/Corta/releases/tag/v1.3.1
[1.3.0]: https://github.com/noah-qin/Corta/releases/tag/v1.3.0
[1.2.3]: https://github.com/noah-qin/Corta/releases/tag/v1.2.3
[1.2.2]: https://github.com/noah-qin/Corta/releases/tag/v1.2.2
[1.2.1]: https://github.com/noah-qin/Corta/releases/tag/v1.2.1
[1.2.0]: https://github.com/noah-qin/Corta/releases/tag/v1.2.0
[1.1.9]: https://github.com/noah-qin/Corta/releases/tag/v1.1.9
[1.1.8]: https://github.com/noah-qin/Corta/releases/tag/v1.1.8
[1.1.7]: https://github.com/noah-qin/Corta/releases/tag/v1.1.7
[1.1.6]: https://github.com/noah-qin/Corta/releases/tag/v1.1.6
[1.1.5]: https://github.com/noah-qin/Corta/releases/tag/v1.1.5
[1.1.1]: https://github.com/noah-qin/Corta/releases/tag/v1.1.1
[1.1.0]: https://github.com/noah-qin/Corta/releases/tag/v1.1.0
[1.0.1]: https://github.com/noah-qin/Corta/releases/tag/v1.0.1
[1.0.0]: https://github.com/noah-qin/Corta/releases/tag/v1.0.0
[0.1.1]: https://github.com/noah-qin/Corta/releases/tag/v0.1.1
[0.1.0]: https://github.com/noah-qin/Corta/releases/tag/v0.1.0
