# Troubleshooting

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

You have a build that is not notarised: one you built yourself, or a
release the workflow produced without signing secrets (its release notes
carry a warning box saying so). The signed release from
<https://github.com/noah-qin/Corta/releases/latest> does not show this.

If you trust the build, clear the quarantine flag once:

```sh
xattr -dr com.apple.quarantine /Applications/Corta.app
```

### "Corta is damaged and can't be opened"

The archive was altered or truncated in transit. Check it against the
`.sha256` file published beside it:

```sh
shasum -a 256 -c Corta-<version>.zip.sha256
```

A mismatch means download again. Every release archive is checked against
its sidecar before it is published (`scripts/check-release.sh`), so a
mismatch is the download, not the release.

### Corta offers to move itself to /Applications

Corta was launched from `~/Downloads` or another folder. It works from
anywhere; `/Applications` is where Sparkle updates and Spotlight expect it.
Say no and it stops asking — or set `suggest-applications-folder = false`
in `~/.config/corta/config`.

### "This version of Corta requires macOS 26.0 or later"

Corta's deployment target is macOS 26.0 and it uses Metal 3 (optionally
Metal 4) and Core Text APIs from that release. There is no build for
earlier systems, and the project does not plan one (`DESIGN.md` §6).

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

---

## Typing and rendering

### Tab does nothing in Claude Code's slash-command menu

Fixed in the first release after 0.1.1 (B02). If it recurs, report it
with the Claude Code version: the fix is in how `insertTab(_:)` from a
candidate window reaches the child, and a new candidate UI could route it
differently.

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
holds the key: Settings ▸ General ▸ Quick Terminal says so, and
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
but whose archive has not yet been signed into the appcast
(`scripts/release.sh`, a maintainer step) is not visible to installed
copies yet. `update-auto-check = false` disables only the daily background
check; the menu item always works.

---

## Going back to your old terminal

Nothing Corta installs outlives it except what you asked for:

1. **Shell integration**, if you installed it from Settings ▸ Terminal:
   remove it there, or delete the block between
   `# >>> Corta shell integration >>>` and
   `# <<< Corta shell integration <<<` in `~/.zshrc`. Nothing else in
   that file is Corta's.
2. **Secure Keyboard Entry** releases itself when Corta quits. If Corta
   was force-quit while a window was key and typing elsewhere seems to be
   blocked, launch and quit Corta once; the counter is balanced on the way
   out.
3. **Settings and state**: `~/.config/corta/` (the config file) and
   `~/Library/Application Support/Corta/` (window arrangement, directory
   history). Delete both to leave nothing behind.
4. Move `Corta.app` to the Trash.

Then, if you are willing, open an issue with the **Went back to my old
terminal** template and say what sent you back. A missing feature, a
rendering bug and "it just felt slower" are all answers the project can
act on.
