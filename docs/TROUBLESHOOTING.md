# Troubleshooting

[Documentation index](README.md) · [Project overview](../README.md)

What to do when Corta will not install, will not start, or does something
your previous terminal did not. Each entry says what you will see, why,
and the fix — and the last section says how to go back to your old
terminal cleanly if none of it helps, because a report that says "I went
back, and here is why" is one of the most useful things you can file.

If an entry here is wrong or missing, open an issue with the
**Installation blocker** or **Went back to my old terminal** template:
<https://github.com/noah-qin/Corta/issues/new/choose>.

---

## Installing

### "Corta can't be opened because Apple cannot check it for malicious software"

Official releases are Developer ID signed and notarised. A source build
may not be. For a downloaded release, verify its checksum and the image
and app checks below, then report the exact message with the version.

### "Corta is damaged and can't be opened"

The disk image may be incomplete, altered or rejected by macOS signature
validation. First check it against the
`.sha256` file published beside it:

```sh
shasum -a 256 -c Corta-<version>.dmg.sha256
```

A mismatch means download again. Every release package is checked against
its sidecar before it is published (`corta-release-check`), so a
mismatch is a reason to stop and download again. If the checksum matches,
check the image and copied app:

```sh
spctl -a -t open --context context:primary-signature -v Corta-<version>.dmg
xcrun stapler validate Corta-<version>.dmg
spctl --assess --type exec /Applications/Corta.app
xcrun stapler validate /Applications/Corta.app
```

Include the release version, macOS error and these results in your report.
Do not bypass Gatekeeper to test a release. Versions through 1.1.8 retain
their original ZIP checksums; use the filename from that release.

### Corta offers to move itself to /Applications

Corta was launched from `~/Downloads` or another folder. It works from
anywhere; `/Applications` is where Sparkle updates and Spotlight expect it.
Say no and it stops asking — or set `suggest-applications-folder = false`
in `~/.config/corta/config`.

Opened straight from the disk image, macOS runs Corta from a
temporary read-only location, so it cannot move itself; it asks you to drag
it into Applications instead. If a newer Corta is already there, it offers
to open that one rather than replace it with the older copy.

### There are two Corta icons in the Dock

One of them is a development build. Finder calls it **Corta Dev**, the
menu bar calls it **CortaDev**, its icon has an orange background rather
than a blue one, and its bundle identifier is `dev.noahqin.Corta.dev`. It keeps its configuration and its
state in `~/Library/Application Support/Corta Dev/`, never in
`~/.config/corta/config` or `~/Library/Application Support/Corta/`, and it
has no "Check for Updates…" menu item — so the one with the blue icon is
the installed Corta, whatever order they appear in. Quitting or deleting
either leaves the other alone. Only someone building Corta from source
has one (`CONTRIBUTING.md`, "Developing Corta in Corta").

### "This version of Corta requires macOS 26.0 or later"

Corta's deployment target is macOS 26.0 and it uses Metal 4 and Core Text
APIs from that release. There is no build for
earlier systems, and the project does not plan one (`DESIGN.md` §6).

### "You can't open the application "Corta" because it is not supported on this type of Mac"

From 1.1.0, Corta is built for Apple silicon only — a Mac with an M1 or
later chip (`DECISIONS.md` D21). An Intel Mac cannot run it. **1.0.1** is
the last version for Intel Macs, and it stays available on the
[1.0.1 release page](https://github.com/noah-qin/Corta/releases/tag/v1.0.1):
download `Corta-1.0.1.zip`, verify it and replace the copy in
`/Applications`. An Intel Mac already running 1.0.x is not offered 1.1.0
by **Check for Updates…**, so it keeps working where it is; this message
appears only when a newer archive was downloaded and opened by hand.

To check which chip a Mac has, choose Apple menu ▸ About This Mac: the *Chip* line
names an Apple chip (M1, M2, …) on Apple silicon, and a *Processor* line
names an Intel one.

---

## Starting

### The window opens blank, or opens and closes

Launch from Terminal.app to see why:

```sh
/Applications/Corta.app/Contents/MacOS/Corta
```

A pane that cannot spawn its shell shows a failure view with a **Retry**
button rather than a blank canvas; if you see a blank canvas with no
failure view, that is a rendering bug worth a report with the console
output.

### The shell is not the one I expected, or has no PATH

Corta spawns `$SHELL` from the environment it was launched with (else
`/bin/zsh`) as a login shell (`-l`), so `~/.zprofile` and `~/.zshrc` both
run. A `$SHELL` that no longer exists falls back to `/bin/zsh`, then
`/bin/sh`, with a notice in the pane saying which rung was taken. If
commands that work in Terminal.app are "not found" in Corta, check what
`SHELL` is in the environment *GUI applications* are launched with
(`launchctl getenv SHELL`): a value set there applies to every app and
outlives the session that set it. `launchctl unsetenv SHELL` and relaunch.

A **preset** (Shell ▸ New Pane with Preset) or `preset.<name>.shell` in
the config file overrides this per pane.

### Corta restored yesterday's windows and I did not want them

`restore-windows = false` in `~/.config/corta/config`, or uncheck it in
Settings ▸ General. A restore that crashed the app is not retried: the
saved arrangement is dropped and one fresh window opens.

### Settings says it can't read the config file

`~/.config/corta/config` exists but is not UTF-8 text — usually a byte
saved by an editor in another encoding — or you cannot read it. Corta keeps
the settings it has and refuses to write the file, because writing would
replace everything in it. Re-save the file as UTF-8 (or remove the bad
line); Corta picks it up as soon as it reads again. Shell integration does
the same for an rc file it cannot read: it reports it and leaves it alone.

---

## Typing and rendering

### Tab does nothing in Claude Code's slash-command menu

Fixed in 1.0.0 (B02); v0.1.1 has the bug. If it recurs
on a newer build, report it with the Claude Code version: the fix is in how
`insertTab(_:)` from a candidate window reaches the child, and a new
candidate UI could route it differently.

### ⌥ types `é`, `ø`, `–` instead of acting as Meta

That is the macOS default and Corta keeps it. Set `option-as-meta = true`
to make ⌥ send `ESC` + key, the way a PC keyboard's Alt does. Special
keys (arrows, function keys) carry ⌥ as the xterm modifier either way.

### Colours or `TERM` look wrong over ssh

Corta announces `TERM=xterm-256color` deliberately (`docs/DECISIONS.md`
D08). If a remote program misbehaves, it misbehaves the same way in
xterm; `CONFORMANCE.md` §4.2 has the esctest pass rate and the list of
sequences that are not implemented yet.

### A glyph is drawn smaller than its neighbours

A font whose bold or italic face advances wider than its regular face
would otherwise paint into the next cell. Corta measures every ASCII
printable across all four faces before using a family, and scales an
overwide glyph into its cell rather than letting it overlap. Settings ▸
Appearance ▸ Font status says whether the configured family passed. The
system monospaced font (`font-family = system`) always does.

### Images from `kitten icat` do not show, or show in the wrong place

Corta implements the Kitty graphics protocol's direct (in-band)
transmission in RGB, RGBA and PNG. File-based transmission (`t=f`, `t=t`,
`t=s`), animation frames and Unicode-placeholder placement are not
implemented, and the file-based ones will not be: a remote stream naming
a local file to read is exactly what the threat model rejects
(`SECURITY.md` §1).

---

## Behaviour that differs from other terminals

### Copying happens as soon as I finish selecting

`copy-on-select` is on by default and confirms with a label in the pane's
corner. Set it to `false` for ⌘C only.

### A program said it copied to my clipboard, and nothing was copied

OSC 52 *write* is off by default: any program output at all could put text
on the clipboard for you to paste later. `allow-clipboard-write = true`
turns it on, which is what `tmux` and a remote `ssh` session need. The
*read* direction does not exist under any setting.

### Closing a window asks whether I am sure

Something in that window still has a foreground job. `confirm-close =
false` turns the question off everywhere.

### The Quick Terminal hotkey does nothing

Three possibilities, in order. `quick-terminal` is `false` (the default):
no key is claimed until you set it to `true`. Another application already
holds the key: Settings ▸ Quick Terminal says so, and
`quick-terminal-key` takes any other combination with at least one
modifier. Or the key is one Corta cannot map to a key position (`é`, a
two-character spelling): the line is preserved in the config file
unchanged and the default applies. View ▸ Quick Terminal and the *Toggle
Quick Terminal* Shortcuts action open the panel regardless.

### A remote pane's badge says "host unknown", or a local `tmux` says "remote?"

The badge names a host only from the remote shell's own `OSC 7` report —
never from the `ssh` command line (aliases, `~/.ssh/config` names and
jump-host chains all read back wrong) and never from the prompt text.
Without that report an `ssh` pane says *host unknown*, which is the
truth. To get the host, put the shell integration block from Settings ▸
Terminal into the remote machine's `~/.zshrc` too; it emits the `OSC 7`
the badge reads. A `tmux` or `screen` in the foreground reads *remote?*
because the session it is attached to may itself be on another machine
and nothing here can tell — it is uncertainty, not an accusation.

### Browse Remote Files… says authentication failed, but `ssh` works in the pane

The SFTP channel has no terminal, so `ssh` cannot ask for a password or a
passphrase there. It works when a key is held by `ssh-agent` or the
keychain, or when `ControlMaster` in `~/.ssh/config` lets it reuse the
connection the pane already opened. A host that only takes a password
cannot be browsed; the error says so rather than hanging.

### Command History shows "(command text no longer in scrollback)"

The command's text is recovered from the grid, not stored: once its
prompt line has scrolled past `scrollback-lines`, the record keeps its
time, status and directory but the text is gone, and Fill and Run are
not offered for it. Raise `scrollback-lines` if that happens often.

### I cannot scroll back to the beginning of a long run

`scrollback-lines` (default 10,000) is a per-session cap, and it counts
*physical* rows — a 200-column line wrapped at 100 columns is two. Output
older than the cap is discarded as it arrives; the pill at the top says
how far back the viewport is. Raise the cap (up to 1,000,000; memory is
about 16 bytes per stored cell) or export as you go.

### Secure Keyboard Entry is on but my macro tool still works

The lock in the titlebar shows when it is *engaged*, which is only while a
Corta terminal window is key and Corta is the active application. In any
other application, and while Settings is key, keystrokes are delivered
normally — that is the point, and it is why the indicator follows the
engaged state rather than the setting.

---

## Updating

### Check for Updates… finds nothing

Corta compares **build numbers**, not version strings, against
`appcast.xml` on the `main` branch. A release that is tagged and drafted
but not yet published is not in the feed; once it is published, the
update-feed workflow signs it in through a pull request that the
maintainer approves, so allow a little while after the release appears
on GitHub. `update-auto-check = false` disables only the daily background
check; the menu item always works.

---

## Empty Return draws a green or red command marker

Corta 1.1.1 fixes empty Return being reported as a completed command by the
zsh, bash and legacy fish integration. If it still happens after updating,
open **Settings ▸ Terminal ▸ Shell Integration**, choose **Update**, then
open a new shell. Existing shells keep the old functions until restarted;
old markers already drawn are not removed. Only the marked Corta block in
the startup file is updated.

## Going back to your old terminal

Quit Corta before removing its files. Review managed remote-edit copies
for unsaved work before deleting application data:

1. **Shell integration**, if you installed it from Settings ▸ Terminal:
   remove it there, or delete the block between
   `# >>> Corta shell integration >>>` and
   `# <<< Corta shell integration <<<` in your shell's startup file —
   `~/.zshrc`; for bash in `~/.bashrc` and `~/.bash_profile` (or
   `~/.bash_login` / `~/.profile`); or `~/.config/fish/config.fish`. Nothing else
   in that file is Corta's.
2. **Secure Keyboard Entry** releases itself when Corta quits. If Corta
   was force-quit while a window was key and typing elsewhere seems to be
   blocked, launch and quit Corta once; the counter is balanced on the way
   out.
3. **Settings and state**: `~/.config/corta/` (the config file) and
   `~/Library/Application Support/Corta/` (window arrangement, directory
   history and managed remote-edit copies). Delete these only after keeping
   any local edits you still need. The renderer also keeps disposable cache
   files under `~/Library/Caches/dev.noahqin.Corta/`; these can be removed.
4. Move `Corta.app` to the Trash.

Then, if you are willing, open an issue with the **Went back to my old
terminal** template and say what sent you back. A missing feature, a
rendering bug and "it just felt slower" are all answers the project can
act on.

### A directory proxy icon is missing on a network mount

Corta checks the reported local directory in the background. If the mount is
slow or two checks are already waiting, it leaves the proxy icon absent so
output and keyboard interaction can continue. Check the mount independently;
changing directory after it recovers requests a new check.

### A pane opens in the home folder instead of a network directory

A new pane, or a window restored at launch, starts in the directory it was
asked for only if that directory answers within a short limit. A network
volume that has stopped answering counts as missing, so the pane opens in
the home folder rather than freezing Corta. The same limit applies to
⌘-clicking or hovering a `path:line` reference there: it is not offered as
a link. Reconnect the volume, then `cd` to it or open a new pane there.

### Remote editing asks again after an upload prompt

The local file changed after the version shown by the original prompt.
Approve the new edit explicitly. An older managed entry without a remote
content digest also needs a conflict decision once. A content comparison
can identify remote changes even when file size and timestamp are unchanged.

## Cursor, system status and theme editor

These features arrived in 1.1.5. In Settings
(⌘,) → Appearance → Cursor, select a shape and enable Blink cursor separately.
The default is a nonblinking block. Blinking pauses while the pane is inactive,
hidden or scrolled back; a terminal program can temporarily override the setting
with DECSCUSR. Reset Terminal restores the configured style.

The bottom status bar is disabled by default. Enable it and choose metrics in
Settings → Terminal. View → Local host details… works even when the bar is off.
Rates need two samples, so allow a few seconds. Network auto measures one
primary interface: choose an explicit interface when a VPN or multiple adapters
makes that choice unsuitable. SSH panes still report the local Mac. Thermal
levels are macOS classifications, not Celsius readings. Narrow windows may
truncate the bar; click it for the complete selected values.

View → Theme editor… opens color editing directly; Appearance settings also
has Create theme and, for custom themes, Edit theme. Invalid HEX colors disable
Save. If the config was edited elsewhere, reopen the editor to avoid overwriting
that edit. System Monospaced is the only primary font; old family names migrate
to it, and font size remains configurable.

The interface follows macOS’s language choice for Corta. Restart after changing
that app-language preference. Nine translations ship; language and numeric
region formatting can differ. See the [tutorial](USER-GUIDE.md#personalizing-the-terminal).
