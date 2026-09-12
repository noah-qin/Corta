# Configuration

Every setting Corta has, in the one file that holds them:
`~/.config/corta/config`.

That file is the **single source of truth**. The Settings page (⌘,) edits
it and reads the result back; there is no second store. An edit made in
`$EDITOR` while Corta is running is picked up within a moment — the file
and its directory are both watched, because most editors write a
temporary file and rename it over the target rather than writing in
place.

The file is created with the current values the first time the Settings
page is opened, so opening it once and then reading the file is the
fastest way to see the current defaults.

---

## 1. Format

```
key = value        # comment to end of line
```

- One setting per line. Whitespace around the key, the `=` and the value
  is ignored.
- A line whose first non-blank character is `#` is a comment.
- A `#` that **opens a value** is a colour, not a comment
  (`background = #101018`). The key is split off before comments are
  stripped, which is what makes both readings possible.
- Booleans accept `true`/`false`, `yes`/`no`, `on`/`off`, `1`/`0`.
- An **unknown key is preserved**, not dropped: a file written by a newer
  Corta survives a round trip through an older one.
- An unparseable line is skipped, never fatal. A typo in one setting must
  not cost you every other setting, and the terminal has to start.
- An out-of-range value for a known key is **clamped**, not rejected, and
  rewritten in its clamped form.

Two families of key are structured rather than scalar, and both use a
dotted prefix so the flat format needs no nesting: `theme.<name>.…`
(§4) and `bind.<command>` (§5).

---

## 2. Settings

### Appearance

| Key | Values | Default | Notes |
| --- | --- | --- | --- |
| `theme` | a theme name | `corta` | Built in: `corta`, plus `solarized` and `mono`, which still resolve but are not offered in the UI (§4). A theme defined in this file wins over a built-in of the same name. |
| `appearance` | `auto`, `light`, `dark` | `auto` | Which of the theme's two variants is live. `auto` follows macOS and switches while running. |
| `font-family` | a family name, or `system` | `system` | `system` means `NSFont.monospacedSystemFont`. A named family is verified before use: every ASCII printable must advance identically across the regular, bold, italic and bold-italic faces, and the faces must be outlines. A family that fails falls back to the system font. |
| `font-size` | 8–64 | `12` | Points. ⌘+ / ⌘− / pinch write back here, so a zoom survives a relaunch. |

### Window

| Key | Values | Default | Notes |
| --- | --- | --- | --- |
| `columns` | 20–500 | `120` | The grid a **new** window opens with, in cells. |
| `rows` | 5–300 | `30` | As above. The window's size in pixels is this grid times the font's cell metrics plus the pane insets — so two terminals showing the same `columns × rows` are still different sizes on screen if their fonts differ. |
| `restore-windows` | boolean | `true` | Reopen the last run's windows, splits, divider proportions and each pane's working directory. |
| `confirm-close` | boolean | `true` | Ask before closing a pane, window or the app while a shell still has a foreground job. |

### Terminal

| Key | Values | Default | Notes |
| --- | --- | --- | --- |
| `scrollback-lines` | 0–1000000 | `10000` | Lines of history per session. **Applies to sessions opened afterwards**: a running child's history cannot be re-limited without discarding lines. |
| `bell` | `visual`, `audible`, `muted` | `visual` | `visual` flashes the pane; `audible` is `NSSound.beep()`. |
| `option-as-meta` | boolean | `false` | Whether ⌥ acts as Meta — an ESC prefix on the base character, the way a PC keyboard's Alt does — instead of composing the layout's alternate character. Off by default because on macOS ⌥ *is* text input: it types `é`, `ø`, `–`, and starts dead-key sequences, and an international layout needs that. Turn it on when a program wants `M-x` and `M-b`. Special keys are unaffected either way: ⌥ already reaches the child there as the xterm modifier parameter, and an IME still sees every event it would otherwise see. |
| `open-file-command` | string | *(empty)* | The command run when a `path:line` reference in program output is ⌘-clicked. `{file}`, `{line}` and `{column}` are substituted, one argument at a time. The executable must be an **absolute path** and is run directly — never through a shell — so a path containing `;` or `$(…)` stays a path. Empty means the system default application for the file's type, which cannot be told a line number; the hover tooltip says so. |
| `search-regex` | boolean | `false` | Whether the search field is read as a regular expression (ICU syntax, as `NSRegularExpression` accepts it). The **`*`** button in the search bar writes this key. Three things are reported rather than shown as "no results": a pattern that does not compile, a pattern whose shape makes a backtracking engine take exponential time (`(a+)+`, `(a*)*`, `(a\|a)+` — every one has a linear equivalent, and it is refused *before* it runs because ICU's time limit is not reachable from Swift), and a sweep that stopped on its 500 ms budget or on a line longer than 64,000 units, which the match count marks with a `+`. |
| `search-case-sensitive` | boolean | `false` | Whether scrollback search distinguishes case. Off by default: a person searching a log for `error` wants `Error` and `ERROR` too. The **Match Case** button in the search bar writes this key, so the choice survives closing the bar and restarting. |
| `copy-on-select` | boolean | `true` | A finished selection goes straight to the clipboard, confirmed by a label in the corner of the pane. Set `false` for ⌘C only. |
| `link-activation` | `command`, `click` | `command` | `command` opens a link on ⌘-click. `click` opens it on a plain click and underlines the link under the pointer; dragging across a URL still selects it. |
| `allow-clipboard-write` | boolean | `false` | Whether OSC 52 may put text on the system clipboard — the only route from inside `tmux` or an `ssh` session. Off by default because *any* output could use it. The **read** direction does not exist under any setting (`SECURITY.md` §6). |

#### Shell integration (B07)

Not a config-file key — a file on disk, `~/.zshrc`, that only Settings ▸
Terminal ▸ Shell Integration touches, and only inside one marked block:

```
# >>> Corta shell integration >>>
…
# <<< Corta shell integration <<<
```

**Install** appends the block (creating `~/.zshrc` first if it does not
exist); **Remove** deletes exactly that block and nothing else a user wrote
around or inside it. Installing is reversible for the same reason: nothing
outside those two lines is Corta's to change, so removing them undoes the
whole thing. Installing twice changes nothing the second time, and the
script itself guards its own hooks with `CORTA_SHELL_INTEGRATION_ACTIVE` in
case something else sources it again.

The row reports one of three states, read fresh from `~/.zshrc` every time
Settings opens — the file, not a cached flag, is the ground truth, the same
rule the config file itself follows (§1):

| State | Meaning |
| --- | --- |
| Not installed | No Corta block. Offers **Install**. |
| Installed | The block is present. Offers **Remove**. |
| Possible conflict | No Corta block, but the file already sources another terminal's own integration (iTerm2, Starship, VS Code or WezTerm's are recognised by name). Offers **Install Anyway** — installing alongside another integration is not refused, only flagged, since only the user knows whether that is what they want. |

Only zsh ships today; fish and bash are evaluated separately (the B07
roadmap issue). The installed script emits `OSC 133 ; A/B/C/D` from zsh's
`preexec`/`precmd` hooks and `OSC 7` for the working directory — the same
two sequences `Performer+ShellIntegration.swift` and this document's
command-jump entries already describe. Nothing is installed automatically;
a user who never opens this row keeps the keystroke-and-idle heuristic
`TaskNotifier` falls back to, same as before B07.

### Notifications

| Key | Values | Default | Notes |
| --- | --- | --- | --- |
| `notify-on-long-task` | boolean | `false` | Post a notification when a long command finishes. |
| `notification-threshold` | ≥ 1 | `30` | Seconds a command must run to be worth one. |

A notification is posted only when **all** of these hold: the setting is
on, the command ran longer than the threshold, the window is **not** the
key window, and macOS has granted notification permission. With shell
integration (OSC 133) the boundaries are exact; without it, Return starts
the timer and 1.5 s of output silence ends it — which is why the feature
is off by default. The notification carries the pane's title and the exit
status, never the command text (`SECURITY.md` §5).

### History (B08)

| Key | Values | Default | Notes |
| --- | --- | --- | --- |
| `directory-history` | boolean | `true` | Whether Corta remembers directories a completed command actually ran in (`OSC 7`), to rank for the directory switcher. |

Not the config file's own state: `directory-history` only gates whether
`DirectoryHistoryStore` reads and writes its file (Application Support, not
`~/.config/corta/config` — the same split `SessionRestore` draws between
settings and app-managed state). Turning the key off stops it being read
*or* written; **Clear** in Settings ▸ General ▸ History empties it (and
deletes the file) regardless of the setting. Ranking is frecency — visit
count that halves every three days — with favorites always sorted first;
`DirectoryHistory.projectRoot(for:)` separately finds the nearest ancestor
directory containing `.git`, for jumping to a project root rather than
wherever inside it a command happened to run. A directory only ever enters
this history already local — `OSC 7`'s own host check
(`Performer+OSC.swift`) drops a remote report before `TerminalSession
.currentDirectory` ever reports it, so nothing here can rank a path that
belongs to a different machine.

An app-initiated directory change (`ViewController.changeDirectory(to:)`)
writes `cd '<path>'` to the child only when
`ViewController.canChangeDirectorySafely` holds: shell integration is
active, no command is currently running, and the cursor is still exactly
where the prompt finished drawing — so a directory a person picked from
history or a favorite never lands on a busy shell, a TUI holding the
screen, or a prompt with something already typed into it.

### Updates

| Key | Values | Default | Notes |
| --- | --- | --- | --- |
| `update-auto-check` | boolean | `true` | Whether Corta checks `appcast.xml` in the background, once a day. |
| `suggest-applications-folder` | boolean | `true` | Whether Corta offers to move itself into `/Applications` on launch, when it is not already there. |

Check for Updates… (the Corta menu, directly under About) always works,
on or off — this key only gates the unattended check nobody asked for.
Updates are fetched over HTTPS and verified against an EdDSA signature
before installing (`UpdateController.swift`, `docs/DESIGN.md` — Sparkle is
the one third-party dependency in the app shell; the terminal core has
none).

`suggest-applications-folder` turns itself off the first time the prompt
is answered either way — accepting moves the app and there is nothing
left to ask about, and "Don't Ask Again" writes `false` directly
(`ApplicationsFolderMover.swift`). Direct-download distribution (M6.16)
ships a plain `.zip` with no drag-to-install step, so without this, a
Corta run from wherever it was unzipped never gets asked to relocate —
and Sparkle's update path and Spotlight/Launchpad both assume
`/Applications`.

---

## 3. A complete example

```ini
# Appearance
theme = corta
appearance = auto
font-family = system
font-size = 13

# Window
columns = 120
rows = 30
restore-windows = true
confirm-close = true

# Terminal
scrollback-lines = 50000
bell = visual
option-as-meta = false
search-case-sensitive = false
search-regex = false
open-file-command =
copy-on-select = true
link-activation = command
allow-clipboard-write = false

# Notifications
notify-on-long-task = true
notification-threshold = 60
```

---

## 4. Themes

A theme is the sixteen ANSI colours plus the three the terminal owns
(default foreground, default background, cursor), in a **light** and a
**dark** variant. The 6×6×6 colour cube and the 24-step greyscale ramp
are *not* part of a theme: xterm defines them numerically, so a program
asking for colour 137 means one specific colour.

Corta offers one theme, `corta`. Two more — `solarized` and `mono` — stay
defined and resolvable, so `theme = solarized` and inheriting from them
both work; they are simply not recommended from the UI.

### Keys

| Key | Meaning |
| --- | --- |
| `theme.<name>.name` | The display name in the Settings page and the View menu. Defaults to `<name>`. |
| `theme.<name>.inherit` | A built-in to start from: `corta`, `solarized`, `mono`. Defaults to `corta`. |
| `theme.<name>.<variant>.foreground` | Default text colour. `<variant>` is `dark` or `light`. |
| `theme.<name>.<variant>.background` | Default background. |
| `theme.<name>.<variant>.cursor` | Cursor colour. |
| `theme.<name>.<variant>.ansi` | The whole table on one line, comma-separated. A shorter list overrides a prefix of it. |
| `theme.<name>.<variant>.ansi<N>` | One slot, `N` from 0 to 15: black, red, green, yellow, blue, magenta, cyan, white, then the eight bright ones. |

Colours are `#rgb` or `#rrggbb`; the `#` is optional. There is no alpha
component — the terminal surface is opaque content, not a glass layer.

Anything left unset is inherited, so a two-line theme is a legal theme —
and a half-written one still renders, which matters because this file is
hand-edited.

```ini
theme = midnight

theme.midnight.name = Midnight
theme.midnight.inherit = solarized
theme.midnight.dark.background = #101018
theme.midnight.dark.cursor = #00c2c7
theme.midnight.dark.ansi1 = #ff5f56
```

### Following a file reference

⌘-click on `src/main.rs:42:17` in program output opens that file, at that
line where `open-file-command` can express one. A URL wins where both could
match.

Two rules bound it, and neither is negotiable:

- **A bare path is not a reference.** Only `path:line` — the shape a tool
  emits — is detected. Ordinary output is full of things that look like paths
  (`and/or`, `n/a`, `TODO/FIXME`), and underlining a third of every line
  teaches you to ignore underlines.
- **Only files on this machine.** The path is resolved against the pane's
  working directory and must name a regular file that exists locally. A pane
  inside `ssh` has no local working directory — OSC 7 reports naming a remote
  host are dropped by the parser — so nothing resolves there, absolute paths
  included: an absolute path on another machine is no more this machine's
  than a relative one.

This does **not** widen the URL scheme allowlist (`SECURITY.md` §2.4). A
`file://` string in output is still plain text and still cannot be detected as
a link; the `file:` URL that gets opened is built by Corta from a path it has
already resolved and confirmed. The program chooses the path, never the
scheme, and never whether the thing is a file at all.

---

## 4a. Presets

A preset is a named way to open a terminal: a shell, a directory and a few
environment variables. Shell ▸ New Pane with Preset lists them, in the order
the file defines them, and hold ⌥ to open one in a window of its own. With
no presets defined the row is *hidden* rather than greyed out: a submenu's
parent item carries no action, so AppKit enables it unconditionally and a
disabled-looking row would still open an empty menu.

```
preset.api.shell = /bin/bash
preset.api.arguments = -l
preset.api.directory = /Users/you/src/api
preset.api.env.API_ENV = staging
preset.api.env.NO_COLOR = 1
```

Holding ⌥ while choosing a preset opens it in a window of its own instead of
splitting the focused pane.

Every field is optional. `shell` and `directory` must be **absolute** — a
relative path would resolve against whatever Corta was launched from, which on
a Finder launch is `/` — and a preset that names neither an absolute path nor
any setting at all is ignored rather than offered.

`env.*` variables are added on top of the sanitised inherited environment
(`SECURITY.md` §4.3): a preset can add and override, never remove. A preset
whose shell has been uninstalled degrades down the same fallback ladder an
ordinary pane uses, so it opens a working terminal rather than a failure
panel — and the preset's `arguments` apply only to its own shell, since a
fallback `/bin/sh` may not understand them.

A preset is applied once, at spawn. A pane opened from one is an ordinary
pane afterwards: there is nothing to leave and nothing to keep in sync. Presets
deliberately carry no colours, fonts or keybindings — those are window- or
app-wide in Corta (`DESIGN.md` §6), and a per-preset copy would be a second
settings store arguing with this file.

---

## 5. Keyboard shortcuts

```
bind.<command> = cmd+shift+d
bind.<command> =                 # an empty value unbinds
```

Modifiers: `cmd`/`command`, `ctrl`/`control`, `alt`/`opt`/`option`,
`shift`. Joined to the key with `+`, case-insensitive.

Keys: any single character (`d`, `,`, `=`, `+`), or one of the named
keys `up`, `down`, `left`, `right`, `home`, `end`, `pageup`, `pagedown`,
`return`, `enter`, `tab`, `space`, `escape`, `delete`.

Unbinding is not the same as restoring the default: an empty value leaves
the command with **no** key, which is what you want when a TUI needs one
Corta was taking.

An unbound keystroke is **passed to the child process**, encoded like any
other key Corta does not claim — it is not swallowed. That is the point of
unbinding: `bind.close =` is how ⌘W stops closing the pane and starts
reaching the program running in it. It also means unbinding is uniform —
a key Corta never bound and a key you unbound behave identically — and
that nothing can end up doing nothing, which reads as a bug rather than as
a setting. The command itself stays reachable from its menu and from the
command palette (⇧⌘P); Help ▸ Keyboard Shortcuts lists it with an em dash.

Nothing rejects two commands sharing one keystroke. Where AppKit decides,
the first matching menu item in menu-bar order wins; where Corta decides,
the first command in the table below wins. Help ▸ Keyboard Shortcuts shows
the key against both rows, which is how you spot it.

### The commands

| `bind.` key | Command | Default |
| --- | --- | --- |
| `new-window` | New Window | `cmd+n` |
| `new-tab` | New Tab | `cmd+t` |
| `close` | Close | `cmd+w` |
| `split-right` | Split Pane Right | `cmd+d` |
| `split-down` | Split Pane Down | `cmd+shift+d` |
| `focus-left` | Move Focus Left | `alt+cmd+left` |
| `focus-right` | Move Focus Right | `alt+cmd+right` |
| `focus-up` | Move Focus Up | `alt+cmd+up` |
| `focus-down` | Move Focus Down | `alt+cmd+down` |
| `grow-pane-horizontally` | Grow Pane Horizontally | `ctrl+cmd+right` |
| `shrink-pane-horizontally` | Shrink Pane Horizontally | `ctrl+cmd+left` |
| `grow-pane-vertically` | Grow Pane Vertically | `ctrl+cmd+down` |
| `shrink-pane-vertically` | Shrink Pane Vertically | `ctrl+cmd+up` |
| `zoom-pane` | Zoom Pane | `shift+cmd+return` |
| `reopen-closed-pane` | Reopen Closed Pane | `shift+cmd+t` |
| `equalize-panes` | Equalize Panes | *(none)* |
| `increase-font-size` | Bigger | `cmd+=` |
| `decrease-font-size` | Smaller | `cmd+-` |
| `reset-font-size` | Actual Size | `cmd+0` |
| `find` | Find… | `cmd+f` |
| `copy` | Copy | `cmd+c` |
| `paste` | Paste | `cmd+v` |
| `select-all` | Select All | `cmd+a` |
| `scroll-page-up` | Scroll Page Up | `shift+pageup` |
| `scroll-page-down` | Scroll Page Down | `shift+pagedown` |
| `scroll-to-top` | Scroll to Top | `shift+home` |
| `scroll-to-bottom` | Scroll to Bottom | `shift+end` |
| `previous-failed-command` | Previous Failed Command | `shift+cmd+up` |
| `next-failed-command` | Next Failed Command | `shift+cmd+down` |
| `copy-last-command-output` | Copy Last Command Output | *(none)* |
| `snapshot-running-command-output` | Snapshot Running Command's Output | *(none)* |
| `export-text` | Export Text… | `shift+cmd+s` |
| `clear-screen` | Clear Screen | `cmd+k` |
| `clear-history` | Clear History | *(none)* |
| `reset-terminal` | Reset Terminal | *(none)* |
| `previous-command` | Previous Command | `cmd+up` |
| `next-command` | Next Command | `cmd+down` |
| `settings` | Settings… | `cmd+,` |
| `command-palette` | Command Palette… | `cmd+shift+p` |

`previous-command`, `next-command`, the two failed-command jumps,
`copy-last-command-output` and `snapshot-running-command-output` all need
shell integration (OSC 133) to have anything to work with; without it their
menu items are disabled rather than silent. `copy-last-command-output` takes
the rows between the last command's prompt and the next one — which is right
for a one-line prompt with the command typed on it, and takes one row too
much for a two-line prompt or a command continued across lines, because Corta
marks `OSC 133 ; A` but not `OSC 133 ; C`.

`snapshot-running-command-output` is `copy-last-command-output`'s answer for
a command that has not finished yet: `copy-last-command-output` needs the
`OSC 133 ; D` mark that only arrives at the end, so it finds nothing while
something is still building. This instead copies everything the running
command has printed so far, with a header naming when the snapshot was taken
— because what a build has printed at minute three is still worth reading,
and waiting for it to finish to read it would be Corta making the user wait
on itself.

`reopen-closed-pane` puts a closed pane back where it was — same split, same
side, same divider, same working directory. It restores the *arrangement*,
never the process: the child that was running is gone, and its scrollback with
it. The record is one pane deep, because the position of anything older is
described against a tree the first reopen has already changed.

`export-text` writes the selection — or, with nothing selected, the whole
scrollback and screen — to a text file. It is the same text ⌘C would put on
the clipboard, including how a soft-wrapped line is joined.

`zoom-pane` fills the window with the focused pane and the same key puts the
split back. It is temporary and changes nothing: no pane is closed, no child
process is disturbed, and the saved arrangement still describes the splits,
not the zoom. The menu item names whichever direction it will go next.

The three terminal-state commands are separate because no two terminals mean
the same thing by "clear", and each says what it discards:

| Command | Screen | Scrollback | Modes, colours, cursor |
| --- | --- | --- | --- |
| Clear Screen | erased | kept | kept |
| Clear History | kept | discarded | kept |
| Reset Terminal | erased | discarded | reset |

All three act on Corta's own grid, not on the program running in it: nothing
is written to the child's input, so a running job is undisturbed and redraws
on its next frame. `clear-history` and `reset-terminal` ship unbound — both
throw history away, and a key that discards a build log by accident is not a
default — and both ask before discarding, naming how many lines are at stake.
The question is skipped when the scrollback is empty, and suppressed entirely
by `confirm-close = false`, which is the existing key for "ask me before I
lose work".

Every command in this table is also in the command palette (⇧⌘P), which
lists the same table — so a command with no default binding is still one
search away.

---

## 6. What is deliberately not configurable

- **`TERM`.** Always `xterm-256color` (`DESIGN.md` §2.5).
- **Reading the clipboard from the terminal.** The OSC 52 read form is
  not implemented and will not be (`SECURITY.md` §6).
- **Title and colour *queries*.** Corta answers what it is; it does not
  report back things a program could use to read the screen or the
  clipboard.
- **Transparency, ligatures, and per-profile settings.** Not shipped —
  see `DESIGN.md` §6 for what is out of scope and why.

## 7. Where the values are applied

| Change | Takes effect |
| --- | --- |
| `theme`, `appearance`, `font-family`, `font-size` | Immediately, in every open pane. |
| `bell`, `option-as-meta`, `search-case-sensitive`, `search-regex`, `open-file-command`, `copy-on-select`, `link-activation`, `allow-clipboard-write`, `confirm-close`, notification keys | Immediately — they are read when the behaviour happens. |
| `bind.*` | Immediately: the menu key equivalents are re-applied on every file change. |
| `theme.*` | Immediately, if the live theme is the one you edited. |
| `columns`, `rows` | The next window opened. |
| `scrollback-lines` | Sessions started afterwards; a running shell keeps the history it has. |
| `restore-windows` | The next launch. |
| `update-auto-check` | Immediately — applied to the live Sparkle updater on every file change. |
| `suggest-applications-folder` | The next launch. |
