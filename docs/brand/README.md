# Corta brand assets

The name "Corta", the pangolin mascot and the application icon are **not**
covered by the Apache licence over the source code. See `NOTICE` at the
repository root.

## Files

| File                        | What it is                                                      |
| --------------------------- | --------------------------------------------------------------- |
| `../../AppIcon.icon`        | Production macOS Icon Composer bundle                            |
| `corta-pangolin-mascot.png` | Transparent mascot master, 1254 × 1254                           |
| `corta-pangolin-loop.gif`   | Looping README animation, 360 × 360                              |
| `screenshot.png`            | The README screenshot — light theme, a clean demo shell          |
| `social-preview.png`        | GitHub social preview card, 1280 × 640                            |
| `social-preview.swift`      | Renders the card above                                           |

## The README animation

```html
<p align="center">
  <img src="docs/brand/corta-pangolin-loop.gif" width="240" alt="Corta pangolin mascot breathing while its cursor-like tail tip blinks">
</p>
```

The loop is intentionally subtle: the curled pangolin breathes and floats by a
few pixels while the cyan cursor at the tip of its tail pulses. It is 360 x 360
pixels and designed to remain legible when displayed at 180–240 pixels wide.

## The social preview card

Rendered by a script rather than checked in from a design tool, so the wording
can change without reopening an editor. Pure AppKit and Core Text — nothing to
install. Run it from the repository root; the mascot is loaded by a relative
path.

```sh
swift docs/brand/social-preview.swift docs/brand/social-preview.png light
swift docs/brand/social-preview.swift /tmp/dark.png dark
```

The card is uploaded by hand: repository **Settings** ▸ **General** ▸
**Social preview**.

## Taking the screenshot

Never point the app at the machine's real shell for this — a prompt carries a
username and a hostname, and `launchctl setenv SHELL` would change the shell
for every application the user launches afterwards (`CLAUDE.md`). Pass the demo
shell in the environment of the one launch you control:

```sh
SHELL=/path/to/demo.zsh Corta.app/Contents/MacOS/Corta
```

The demo shell sets a neutral prompt (`corta ~/src/corta ❯`), starts `zsh -f`
so no rc file leaks aliases, and prints a colour, width and attribute sample.
Capture with ⌘⇧4, then space, then ⌥-click the window to drop the drop shadow.
