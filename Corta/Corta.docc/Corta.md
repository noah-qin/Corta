# ``Corta``

The macOS application: windows, panes, input, the Metal renderer and the
font stack around the terminal core.

## Overview

The app owns everything a person sees and touches. Each pane is a
`TerminalPaneViewController` with collaborators for focus, pointer, search, shell
integration and appearance; a `TerminalRenderer` turns the core's grid
into Metal 4 draws; settings come from the config file alone (D10). The
terminal itself — PTY, parser, grid — is `CortaTerminal`, and SFTP is
`CortaSFTP`. `docs/DESIGN.md` is the architecture; `docs/DECISIONS.md`
holds the settled choices.

## Source layout

`Window/` groups splits, tabs, command palette, command history and status
bar files by feature. `Remote/` groups connection, authentication, browser,
transfers and editing. `Settings/` separates configuration, pages, shared
components, previews, themes and shortcuts. Each type stays with its
extensions; these directories all remain in the app target.
