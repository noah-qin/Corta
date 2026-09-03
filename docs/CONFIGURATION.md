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
| `copy-on-select` | boolean | `true` | A finished selection goes straight to the clipboard, confirmed by a label in the corner of the pane. Set `false` for ⌘C only. |
| `link-activation` | `command`, `click` | `command` | `command` opens a link on ⌘-click. `click` opens it on a plain click and underlines the link under the pointer; dragging across a URL still selects it. |
| `allow-clipboard-write` | boolean | `false` | Whether OSC 52 may put text on the system clipboard — the only route from inside `tmux` or an `ssh` session. Off by default because *any* output could use it. The **read** direction does not exist under any setting (`SECURITY.md` §6). |

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
| `previous-command` | Previous Command | `cmd+up` |
| `next-command` | Next Command | `cmd+down` |
| `settings` | Settings… | `cmd+,` |
| `command-palette` | Command Palette… | `cmd+shift+p` |

`previous-command` and `next-command` need shell integration (OSC 133) to
have anything to jump between.

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
| `bell`, `copy-on-select`, `link-activation`, `allow-clipboard-write`, `confirm-close`, notification keys | Immediately — they are read when the behaviour happens. |
| `bind.*` | Immediately: the menu key equivalents are re-applied on every file change. |
| `theme.*` | Immediately, if the live theme is the one you edited. |
| `columns`, `rows` | The next window opened. |
| `scrollback-lines` | Sessions started afterwards; a running shell keeps the history it has. |
| `restore-windows` | The next launch. |
