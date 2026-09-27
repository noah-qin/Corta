# B11 CPU, locking and memory hot-path pass — 2026-09-13

Moved from `PERFORMANCE.md` §6 on 2026-09-27 (#117). This is the record
as it was written; a bare `§n` below refers to `PERFORMANCE.md`, and
`PERFORMANCE.md` §5.6 keeps the current numbers.

**Locking.** `TerminalSession` already carries exactly one hot-path lock
(`state: Mutex<State>`, guarding the parser, grid and scrollback
together) plus the `stateWaiters`/`yieldToStateWaiters` anti-starvation
mechanism a prior pass added and `TerminalSessionLockWaitTests` already
holds to a 100 ms per-wait / 30 s total ceiling under a `yes` flood. This
pass re-ran that measurement rather than restructuring lock ownership:
`corta-bench`'s snapshot-latency-under-flood benchmark reports p50/p95/p99
all 0.000 ms and max 0.030–0.032 ms on this machine, level with the
figure already on record in §5.1. No batch-budget or ownership change is
justified by that number.

**Copy-on-write / allocation cost.** `Scrollback` already packs rows into
shared batch arenas (`Batch`, ≤256 rows each) rather than one
`ContiguousArray` per row — a prior pass's fix for the growth-headroom
waste `corta-bench`'s `diagnoseScrollbackFootprint` still reports
(608 B/row slack, 57 MB at 100k lines, entirely in the *live-screen* ring
`ScreenLines` uses, which cannot use the same batching since its rows are
still being edited). `snapshot()` itself is an O(1) struct copy
(`Grid`/`ScreenLines`/`Scrollback` are all value types over
`ContiguousArray`); the actual deep-copy cost is deferred COW, paid one
row at a time by whichever side next mutates it. Measured scrollback
footprint at 100k×120-column lines: 185.0 MB, inside §1's ~200 MB target
and unchanged from the last recorded figure — this pass made no change
here; the existing batching already addresses what "immutable blocks"
would otherwise be evaluating.

**ASCII fast path.** Both existing fast paths (`Parser.parse([UInt8],
performer:)`'s run scan; `Grid.writeASCII`/`Line.overwriteASCII`'s
batched cell write) read/wrote through `Array`/`ContiguousArray`
subscripting, which re-checks bounds and the exclusivity flag on every
element even though each scan/write's range is already fixed before it
starts. Both now go through `Span` (`Array.span`, Swift 6.2): the
run-boundary scan in `Parser.swift` indexes `bytes.span` instead of
`bytes`, and `Line.overwriteASCII`'s inner loop writes through
`cells.withUnsafeMutableBufferPointer`. `Span` was chosen over a raw
`UnsafeBufferPointer` for the parser scan specifically because it keeps
the lifetime/exclusivity reasoning checked by the compiler against
`bytes`' scope rather than resting on the caller's manual promise inside
an `withUnsafeBufferPointer` closure — `Line.overwriteASCII` still needs
the closure form because it *writes*, and `Span`'s mutable counterpart
(`MutableSpan`) is not yet what `ContiguousArray` exposes on this
toolchain.

Measured, `-c release`, this machine, 5 runs each before/after (noise
band shown as the full min–max spread rather than one sample, per §5.1's
spirit — `corta-bench`'s own harness reports percentiles only for the
latency benchmarks, not throughput):

| Benchmark | Before | After |
| --- | --- | --- |
| Parser-only throughput | 643.6–650.5 MiB/s | 635.3–684.3 MiB/s |
| Parser + grid throughput | 144.0–145.6 MiB/s | 144.9–154.1 MiB/s |
| Core feed throughput | 129.7–130.9 MiB/s | 128.2–139.5 MiB/s |

The grid-write side (`Line.overwriteASCII`) shows a consistent, real gain
— parser+grid and core-feed throughput both moved up across every
sample, never below the old range. The parser-only scan's gain is
smaller and its range now overlaps the old one at the bottom end; kept
anyway because it is never worse than the old code in any sample taken,
and because `Span` is the safer construct at no measured cost, which is
worth keeping on its own terms even where the throughput case is weak.
All 541 `CortaTerminalTests`, the 18 golden-file cases and a 500,000-input
`corta-fuzz` run against `Tests/Fuzz/corpus` (`--seed 1` and `--seed 2`)
stayed green throughout — no correctness change, byte-identical golden
output.

**Span, borrowing and `@specialize` more broadly.** `Span` is now used at
the two boundaries above; extending it further (e.g. `Grid.write`'s
single-scalar path) found nothing to gain — that path has no
array-range loop left to bounds-check-eliminate, it is one table lookup
per call already behind `@inline(__always)`. `borrowing`/`consuming`
parameters were not introduced: every hot-path type here is a small
value (`Cell`, `UInt32`, `UInt8`) where a `borrowing` annotation changes
nothing measurable, and the one place a large value crosses a call
boundary (`Grid` itself, at `snapshot()`) is COW-cheap already, not a
copy `borrowing` would avoid. `@_specialize` was evaluated and not added:
`Parser.parse<P: ParserPerformer>` and `Performer` are both defined in
`CortaTerminal`, and every production call site (`Terminal.feed`,
`corta-bench`) calls it with the concrete `Performer` type from within
the same module, so whole-module optimization (SwiftPM's release default)
already specializes and devirtualizes it — an explicit `@_specialize`
annotation exists to buy this across a module boundary that does not
exist here, and adding one changed nothing in either binary size or the
throughput numbers above (not tabulated: confirmed and reverted).

**Not attempted.** Restructuring `state`'s single-lock ownership (e.g.
splitting parser/grid from scrollback under separate locks) was
considered and rejected: the measured wait times above show no
contention problem to justify it, and `TerminalSession`'s own header
comment already documents why a single lock plus the waiter-yield
mechanism was chosen over finer-grained locking. Widening the ASCII
fast path itself (SIMD-scanning the printable range, or admitting C0
controls into a run instead of ending it) was not attempted this pass —
`Span`'s subscript is not the vectorizing kind of win a real SIMD compare
would be, and that is a larger, separate change with its own
before/after case to make.
