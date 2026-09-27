# Keypress latency before 1.0.0 — M6 to 2026-09-09

Moved from `PERFORMANCE.md` §5 on 2026-09-27 (#117). This is the record
as it was written; a bare `§n` below refers to `PERFORMANCE.md`, and
`PERFORMANCE.md` §5.6 keeps the current numbers.

**M6 measurement:** external screen-capture tool against a Release
build, 200 characters, 150 ms delay, 50 ms period, 1,000 ms length,
synchronous mode:
45.5 ms average, 24.8 ms minimum, 56.4 ms maximum, 6.8 ms standard
deviation. The in-process write → PTY echo → parse → grid portion measured
separately at 0.005 ms average / 0.007 ms p95, placing essentially all of
the observed latency after the grid mutation.

**0.1.1 measurement (2026-09-09):** the same tool, same settings — 200
characters, 150 ms delay, 50 ms period, 1,000 ms length, synchronous, no
intermediate pauses — against the Release build at commit `12ac1b8`:
**57.8 ms average, 45.3 ms minimum, 78.9 ms maximum, 5.6 ms standard
deviation** over 200 samples.

The §5.2 table as held for this run: MacBook Air, Apple M5 (Mac17,3),
macOS 26.6.2; Release build; built-in Liquid Retina at 60 Hz, native 2x
(2940×1912 pixels, 1470×956 points); System Monospaced 12 pt, the default;
120×30, one pane, not full screen; mains power; nothing else in the
foreground; **test program `cat > /dev/null`**, so the tty echoes and no
shell line editor is between the keystroke and the screen.

**Against M6.12's 45.5 ms this is 12.3 ms worse, and the comparison is
weaker than it looks.** M6.12 recorded its capture settings and not its
test program, and neither run recorded the machine beyond "MacBook Air,
Apple silicon" — §5.2's own first row. So the two runs are known to differ
in at least one variable that was never written down, and possibly in the
machine. What can be said is that this run's environment *is* recorded, in
full, so the next one has something to be compared against.

This also closes what M9 owed. M9 measured 70.1 ms for the default
configuration in an environment §5.2's table was not held for, and flagged
that it could not be read against 45.5 ms. It still cannot; what exists now
is a properly held measurement of the same configuration, which is the
number future work should move.

**Those two rows are not §5.1-shaped.** The external tool reported
minimum, maximum, average and standard deviation — not p50, p95 and p99 —
which is exactly the shape §5.1 objects to. The in-app measure (§5.7)
reports the percentiles, and is why the tool is no longer used or
needed.
