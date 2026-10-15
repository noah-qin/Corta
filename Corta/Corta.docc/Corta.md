# ``Corta``

The macOS application: windows, panes, input, the Metal renderer and the
font stack around the terminal core.

## Overview

The app owns everything a person sees and touches. Each pane is a
`ViewController` with collaborators for focus, pointer, search, shell
integration and appearance; a `TerminalRenderer` turns the core's grid
into Metal 4 draws; settings come from the config file alone (D10). The
terminal itself — PTY, parser, grid — is `CortaTerminal`, and SFTP is
`CortaSFTP`. `docs/DESIGN.md` is the architecture; `docs/DECISIONS.md`
holds the settled choices.
