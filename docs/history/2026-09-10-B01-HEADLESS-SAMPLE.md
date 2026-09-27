# B01 headless core sample — 2026-09-10

Moved from `PERFORMANCE.md` §5.1 on 2026-09-27 (#117). This is the record as
it was written; a bare `§n` below refers to `PERFORMANCE.md`, and
`PERFORMANCE.md` §5.6 keeps the current numbers.

**A fresh headless sample (B01, 2026-09-10, this machine — see §5.2's
toolchain table below).**

```sh
swift build --package-path CortaTerminal -c release --product corta-bench
CortaTerminal/.build/release/corta-bench
```

| Benchmark | p50 | p95 | p99 | max | n |
| --- | --- | --- | --- | --- | --- |
| keypress → grid latency | 0.009 ms | 0.012 ms | 0.013 ms | 0.020 ms | 2,000 |
| keypress → grid latency, flooding neighbour | 0.009 ms | 0.012 ms | 0.015 ms | 0.046 ms | 2,000 |
| snapshot latency under flood | 0.000 ms | 0.000 ms | 0.000 ms | 0.032 ms | 2,000 |
| search response, 100k-line scrollback (warm) † | 27.6 ms | 29.4 ms | 30.1 ms | 30.1 ms | 50 |
| search response, 100k-line non-ASCII scrollback, ASCII query † | 455.4 ms | 475.6 ms | 494.7 ms | 494.7 ms | 50 |

**† Search, before and after the ASCII path (#115).** These two rows were
taken on 2026-09-25 under Xcode 27.0 / Swift 6.4, not the 2026-09-10 /
Xcode 26.6 identity §5.2 names for every other row in this table. §5.2's
rule applies: they are a different measurement, and only the ratios below
are like-for-like, because each pair was taken back to back in one session
on one machine.

Matching ASCII queries against the cells, instead of building a `String`
and a per-character position table for every logical line, takes the warm
figure from 399.8 ms to 27.6 ms — a factor of about 14. (The 385.1 ms this
table carried before was the 2026-09-10 measurement; 399.8 ms is the same
benchmark re-run immediately before the change.)

The second row is the case the fast path cannot take and *does* make
slightly worse: an ASCII query over non-ASCII lines, where the byte walk
is attempted and rejected on every line before the `String` path runs
anyway. The fixture puts the non-ASCII character at the end of the line on
purpose — a log line terminated by a status glyph — so the walk traverses
the whole chain before rejecting it and the row is walked twice. Three
runs each side, p50: 450.7 / 447.0 / 447.7 ms without the fast path,
447.5 / 455.4 / 469.0 ms with it. That is roughly **2% slower** on the
searches that cannot use the fast path, for a factor of 14 on the ones
that can. An earlier fixture with the non-ASCII character near the front
of the line made this look free, which it is not.

Parser-only throughput 628.3 MiB/s, parser+grid 141.1 MiB/s, core feed
130.0 MiB/s — all above §1's 100 MB/s target. Scrollback at 100k lines:
185.0 MB resident, inside §1's ~200 MB target. Full raw output, including
the resize-delivery, spawn-decomposition and multi-pane-fixed-cost
benchmarks not tabulated above, is reproducible with the command above; it
is headless and scripted, so — unlike the M6/0.1.1 end-to-end rows above — this
much of §5.2's table is trivially held exactly by running it again. This is
core-side only; it says nothing about the AppKit/render stages §5.3 and
§5.4 cover, which is exactly the boundary `scripts/measure-app-baseline.sh` and
`CORTA_RENDER_METRICS` exist to close.
