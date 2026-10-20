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
`.sha256` file published beside it. Keep both files in the download folder
and replace `x.y.z` with the version you downloaded:

```sh
shasum -a 256 -c Corta-x.y.z.dmg.sha256
```

A mismatch means download again. Every release package is checked against
its sidecar before it is published (`corta-release-check`), so a
mismatch is a reason to stop and download again. If the checksum matches,
check the image and copied app. Replace `x.y.z` with the downloaded
version in all commands, and run them from the download folder:

```sh
spctl -a -t open --context context:primary-signature -v Corta-x.y.z.dmg
xcrun stapler validate Corta-x.y.z.dmg
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
D08). Sharing that TERM value does not imply full xterm compatibility. Check
the remote environment with `printf '%s\n' "$TERM"` and compare a minimal
reproducer; [Conformance](CONFORMANCE.md#42-external-suites) records supported
sequences and the remaining failures.

### A glyph is drawn smaller than its neighbours

A character the chosen font lacks comes from PingFang SC or Apple Color
Emoji. A fallback glyph can be scaled to stay inside its terminal cells, so
its visible size can differ from neighbouring glyphs. Adjust the font size
in **Settings ▸ Appearance** and compare the preview. If a glyph is clipped
or misaligned, report its text, font, font size, display scale and a
screenshot.

### The font I set is not the one drawn

`font-family` names a family, not a face (`JetBrains Mono`, not
`JetBrainsMono-Regular`). Corta uses it only if it is installed and its
regular, bold and italic faces advance the same width across printable
ASCII; otherwise it draws System Monospaced and **Settings ▸ Appearance**
shows a Font Status row saying which check failed. A font installed while
Corta runs appears in the list straight away; Retry re-checks the
configured one.

Chinese, Japanese or Korean drawn in a different font from the one under
**CJK Font** (`font-family-cjk`) means that family is not installed or has
no CJK characters; the line under the menu says so, and the system
language's font draws instead. A character the chosen font lacks also
comes from the system language's font. The CJK font is unused while **Use
other fonts for missing characters** is off.

### Images from `kitten icat` do not show, or show in the wrong place

Corta implements the Kitty graphics protocol's direct (in-band)
transmission in RGB, RGBA and PNG. File-based transmission (`t=f`, `t=t`,
`t=s`), animation frames and Unicode-placeholder placement are not
implemented, and the file-based ones will not be: a remote stream naming
a local file to read is exactly what the threat model rejects
(`SECURITY.md` §1). Try `kitten icat --transfer-mode=stream picture.png`
to request direct transmission explicitly. An image must fit the 8192-pixel
per-side and 16-million-pixel limits; invalid or oversized images are refused.

### Empty Return draws a green or red command marker

An empty Return is not a command, and current integration hooks record
none. A startup-file block installed by an older Corta can still report
one: open **Settings ▸ Terminal ▸ Shell Integration**, choose **Update**,
then open a new shell. Existing shells keep the old functions until they
restart, and markers already drawn stay. Only the marked Corta block in the
startup file is updated. Standard local zsh sessions using the automatic
hooks get the bundled version when a new shell starts.

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

### A remote pane's badge says "Remote: host unknown", or a local `tmux` says "Remote?"

The badge names a host from the remote shell's own `OSC 7` report, or —
for a connection opened from the connect sheet — from the destination you
typed there. It never reads one from an `ssh` command line typed at a
prompt (aliases, `~/.ssh/config` names and jump-host chains all read back
wrong) or from the prompt text. Without either, an `ssh` pane says *host
unknown*, which is the truth. To get the host, put the shell integration block from Settings ▸
Terminal into the remote machine's `~/.zshrc` too; it emits the `OSC 7`
the badge reads. A `tmux` or `screen` in the foreground reads *Remote?*
because the session it is attached to may itself be on another machine
and nothing here can tell — it is uncertainty, not an accusation.

### Browse Remote Files… says authentication failed, but `ssh` works in the pane

The SFTP connection asks for a password or a key passphrase in a dialog
on its window; a refused or cancelled dialog ends as this error. Check the
user and port in the form — an alias's own `User` and `Port` apply only
when those fields are empty — and the key, if you chose one: a chosen key
is the only one offered. If no dialog appeared, the server refused every
method ssh could try; `ssh -v` with the same user, port and key in a
terminal shows which.

### Browse Remote Files… says a host key could not be verified

A host seen for the first time asks you to trust its key, in a dialog
that shows the fingerprint. This error means the key *changed* since you
trusted it — a reinstalled server, or someone in between. ssh refuses
that until its old line is removed from `~/.ssh/known_hosts`
(`ssh-keygen -R <host>`); ask the server's administrator first.

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
compressed cold history depends on the text and workload). A stored cell
is 16 bytes before compression, not a resident-memory estimate. A measured
100,000-line, 120-column workload added about 11 MiB of resident memory;
see [Performance](PERFORMANCE.md#56-numbers-by-release). Export output you
need to keep beyond the configured cap.

### Secure Keyboard Entry is on but my macro tool still works

The lock in the titlebar shows when it is *engaged*, which is only while a
Corta terminal window is key and Corta is the active application. In any
other application, and while Settings is key, keystrokes are delivered
normally — that is the point, and it is why the indicator follows the
engaged state rather than the setting.

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

---

## Appearance and the status bar

### The cursor does not blink

Blinking is off by default: turn on **Blink cursor** in Settings ▸
Appearance ▸ Cursor. It pauses while the pane is inactive, hidden or
scrolled back. A terminal program can change the shape or blinking for
itself with DECSCUSR; Reset Terminal returns to the configured style.

### The status bar shows no network rate, or the wrong one

Rates need two samples, so allow a few seconds after enabling the bar.
`auto` measures one primary interface; when a VPN or several adapters make
that the wrong one, enter the interface name in Settings ▸ Terminal. An
explicit interface that does not exist shows no rate. The bar always
reports the local Mac, also in an SSH pane, and thermal levels are macOS's
classifications, not degrees. A narrow window may truncate the bar; click
it for every selected value.

### The theme editor will not save

An invalid HEX colour disables Save. If the custom theme was changed in
the config file while the editor was open, close and reopen the editor
before saving, so it does not overwrite that edit.

### The interface is in the wrong language

Corta follows the language macOS chooses for it (System Settings ▸ General
▸ Language & Region ▸ Applications). Restart Corta after changing it.
Number formatting follows the region and can differ from the language.

---

## Updating

### Check for Updates… finds nothing

Corta compares **build numbers**, not version strings, against
`appcast.xml` on the `main` branch. A release that is tagged and drafted
but not yet published is not in the feed; once it is published, the
release pipeline signs and verifies the feed, opens a pull request, waits
for CI and squash-merges it or enables auto-merge. A failed or blocked feed
check can delay delivery, so allow a little while after the release appears
on GitHub. `update-auto-check = false` disables only the daily background
check; the menu item always works.

---

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

Then, if you are willing, open an issue with the
[**Went back to my old terminal**](https://github.com/noah-qin/Corta/issues/new?template=went_back.yml)
form and say what sent you back. It needs no reproduction. A missing feature, a
rendering bug and "it just felt slower" are all answers the project can
act on.
