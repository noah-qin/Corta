# ``CortaTerminal``

The terminal core: a PTY, a hand-written VT parser, a grid with
scrollback, and the selection, search and shell-integration rules that
read it. No AppKit, no Metal, no main actor.

## Overview

`CortaTerminal` is the half of Corta that does not know it has a window.
It owns everything from the child process to the cells the renderer
reads, and nothing about how those cells are drawn. The package is a
local SwiftPM dependency of the app with default actor isolation
disabled, because the reader thread, the parser and the grid run off the
main thread (`docs/DECISIONS.md` D04).

Every byte from the child is hostile (`docs/SECURITY.md` §1). The parser
caps every input it accumulates, drops unknown sequences cleanly, and
never writes stream-supplied text back to the child. The fuzz harness
(`corta-fuzz`) and the golden-file tests hold that line.

Start with <doc:Pipeline> to see where a byte goes, then read the symbols
in the order the pipeline names them.

## Try the core

Create a terminal, feed bytes, and inspect its grid without starting a child
process or opening a window:

```swift
import CortaTerminal

var terminal = Terminal(rows: 4, columns: 20)
terminal.feed(Array("Hello, Corta!\r\n".utf8))
print(terminal.dump())
```

Keep the same value across chunks: a UTF-8 character or escape sequence can
span several reads. Use ``TerminalSession`` when a real PTY and child process
are needed. Sharing mutable terminal state requires synchronization; the
core's lack of actor isolation does not make concurrent mutation safe.

From the repository root, run `swift test --package-path CortaTerminal` to
exercise the core. The repository's `docs/TESTING.md` explains golden fixtures,
fuzzing and app-level verification.

## Topics

### The pipeline

- <doc:Pipeline>
- ``TerminalSession``
- ``PTY``
- ``Terminal``
- ``Parser``
- ``Performer``

### The grid

- ``Grid``
- ``Line``
- ``Cell``
- ``CellAttributes``
- ``Scrollback``
- ``GraphemeTable``
- ``HyperlinkTable``
- ``ImagePlacementTable``

### Reading the grid

- ``Selection``
- ``SelectionRange``
- ``Search``
- ``ScrollbackCoordinates``
- ``LogicalLine``
- ``CommandRecordStore``
- ``RemoteContext``

### Colours and modes

- ``Color``
- ``IndexedPalette``
- ``SpecialColors``
- ``DynamicColors``
- ``KeyboardProtocolStack``
- ``KittyGraphics``

### Processes

- ``ChildEnvironment``
- ``ChildExit``
- ``PTYError``
- ``TerminalSize``
