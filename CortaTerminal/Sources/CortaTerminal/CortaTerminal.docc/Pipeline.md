# Where a byte goes

From the child's write to the cell the renderer reads, in five hand-offs.

## Overview

The hot path is `PTY read → parse → grid write → instance-buffer build`
(`docs/PERFORMANCE.md` §3). Everything on it is a `struct` or a
`ContiguousArray` over raw integers; nothing on it allocates per byte.
Outside it, the package is ordinary Swift.

### 1. The PTY reader

``TerminalSession`` spawns the child through `corta-exec` (a separate
executable so `posix_spawn` can launch it; `Spawn.swift` explains why
this replaced `fork()`) and owns a ``PTY``. A dedicated reader thread
blocks in `read(2)` and hands each chunk to the session's ``Terminal``.
Backpressure is explicit: the reader stops when the app has not drained
the grid, rather than buffering without bound.

### 2. The parser

``Parser`` is a state machine over `UInt8` — the VT500 diagram, with the
UTF-8 decoder (``UTF8Decoder``) folded into the ground state. It knows
nothing about a grid: it recognises a control, an escape, a CSI with its
``Parameters`` and ``Intermediates``, an OSC or DCS string, and calls the
``ParserPerformer`` it was given. Every accumulator has a cap, and an
overflowing string is discarded whole.

### 3. The performer

``Performer`` is the ``ParserPerformer`` that turns recognised sequences
into grid operations: cursor motion, erasing, scrolling regions, modes,
SGR into a ``Pen``, OSC 0/2/7/8/52/133 and the Kitty graphics commands.
Its state — ``PerformerState`` — is the terminal's, and it is where a
*reply* is decided. Replies never contain text the stream supplied
(`docs/SECURITY.md` §2.2).

### 4. The grid

``Grid`` is the screen plus ``Scrollback``: a ``Line`` is a variable-length
array of 16-byte ``Cell``s with a `wrapped` flag, and a complex grapheme
or a hyperlink spills to a side table (``GraphemeTable``,
``HyperlinkTable``) keyed by an id the cell carries. Reflow, selection,
search and export all consult the `wrapped` flag, which is why it has been
there since the first commit (`docs/DECISIONS.md` D03). Damage is tracked
per line so the renderer redraws only what changed.

### 5. Reading it back

The app reads the grid on the main thread under the session's lock, and
builds the instance buffer the renderer draws. The document-anchored
readers live here too so they can be tested without a window:
``Selection`` (rows counted from the screen boundary backwards into
scrollback), ``Search`` (budgeted, so a pattern that would never finish is
refused), ``LogicalLine`` (a wrapped line re-joined), and
``CommandRecordStore`` (OSC 133 command boundaries with their exit
status).

## Checking it by hand

`corta-dump` feeds stdin to a ``Terminal`` and prints the grid, so a real
program's output can be checked without a window:

```sh
swift build --package-path CortaTerminal -c release --product corta-dump
printf 'hello\e[1;31m world\e[0m\n' | CortaTerminal/.build/release/corta-dump
```

`corta-bench` measures parse throughput and scrollback memory, and
`corta-fuzz` replays the checked-in corpus or mutates against it
(`docs/CONFORMANCE.md` §4.3).
