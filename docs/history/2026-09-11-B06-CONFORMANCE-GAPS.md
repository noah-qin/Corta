# B06 conformance gaps — 2026-09-11

Moved from `DESIGN.md` §7.8 on 2026-09-27 (#117). This is the record as
it was written; `DESIGN.md` keeps the current state of the same topic.


`CSI s` / `CSI u` (SCOSC/SCORC) were not dispatched at all — a program
that saved and restored the cursor with the CSI form rather than
DECSC/DECRC (`ESC 7`/`ESC 8`) got nothing back. Corta has no DECLRMM
(left/right margins), so xterm's own behaviour without that mode is to
treat both forms as unconditional aliases; fixed by routing `0x73`/
`0x75` in `Performer+Cursor.performCursorControl` to the existing
`grid.saveCursor()`/`restoreCursor()`. The kitty keyboard protocol's
marker-based `CSI u` forms are intercepted earlier in `csiDispatch` and
never reach this switch, so the alias cannot shadow them —
`SaveRestoreCursorTests.bareCSIuDoesNotTouchKittyProtocol` asserts that
directly rather than by inspection.

OSC 4 (indexed-palette set/query) and OSC 104 (reset) were entirely
unimplemented — a program picking colour 137 by number, or resetting
its overrides on exit, got silence for the query and a no-op for the
set. Added `IndexedPalette` (mirrors `DynamicColors`'s shape: `defaults`
seeded once, a sparse `overrides` dictionary OSC 4 writes into and OSC
104 clears), wired through `PerformerState`/`Terminal`/
`TerminalSession` the same way `dynamicColors` already was, and seeded
`defaults` from `Theme.Variant.indexedPaletteDefaults` — ANSI 0–15 from
the active theme (so index 1 answers with *this* theme's red, not a
generic one), 16–255 from xterm's fixed 6×6×6 cube and 24-step
greyscale ramp, matching `TerminalColorPalette.swift`'s independent
render-side copy of the same formula. `oscDispatch` gained a
`parseOSCCode` helper because OSC 104 is the one code with a real
no-semicolon form (`OSC 104 ST`, which is what xterm itself sends) —
every other code needs a payload and was already unreachable without
one.

**OSC 5** ("special colours" — bold, underline, blink, reverse, italic
default colours) was implemented in a follow-up pass, once the exact
semantics were pinned down from xterm's own `ctlseqs.txt` (the
`Pc` values — 0 bold, 1 underline, 2 blink, 3 reverse, 4 italic — and
the OSC 105 reset pairing) rather than guessed: an *independently
documented* specification is what B06's original pass lacked access
to, not esctest specifically, and the two turned out not to be the
same requirement. Added `SpecialColors` — five fixed slots, no themed
default to seed (unlike `IndexedPalette`, an unset slot means Corta's
ordinary SGR-attribute rendering applies, not a placeholder colour),
with the query form answering black for an unset slot rather than
silence, matching OSC 4's own precedent for "always some numeric
answer." Its own render-path integration — a special colour actually
changing how bold/underline/blink/reverse/italic text paints — was
not attempted in that pass and remains open.

**OSC 4's render-path integration — done in a follow-up pass, measured
before and after.** `Theme.Variant.resolve(_:indexedOverrides:)` now checks a
session's OSC 4 overrides before falling through to the existing
ansi/cube/ramp arithmetic; `TerminalRenderer` carries the overrides and
an `overridesGeneration` counter (`IndexedPalette`'s own new field,
the identical shape `GlyphAtlas.generation`/`ScreenLines.generation`
already use) so a set/reset invalidates the render cache even for a
cell whose *content* never changed — an OSC 4 override is invisible to
the ordinary per-cell revision check, since it changes what an index
resolves to, not what any `Cell` stores. Verified with offscreen
pixel-sampled tests (`IndexedPaletteRenderTests.swift`), including the
specific case that proves the cache invalidation actually matters: a
cell painted before the override, then repainted with no content
change in between.

`CLAUDE.md`'s own rule ("measure the frame-CPU baseline after touching
the render loop") was followed with `CortaTests/FrameCPUBaselineTests`
— the same headless, scriptable tool the M6 render-loop regression
this rule itself documents was found and fixed with, not the
screen-capture/live-signpost route the first attempt at this pass assumed
was the only option (that route needs a real, focused GUI session;
this one does not). The first implementation *did* measure a real,
reproducible regression — about 5%, ~0.1 ms, isolated by A/B runs
against 11 samples per side after system-load noise alone had first
produced a misleading 21% swing between two same-code runs. The cause:
`indexedOverrides` was an always-passed, defaulted-to-empty
`Dictionary` parameter, and passing a `Dictionary` — even an empty one
— costs a retain/release pair Swift cannot elide across the call
boundary, paid twice a cell (foreground and background) across ~4800
cells a frame. Switched the parameter to `IndexedColorOverrides?`
(`nil` when a session has no overrides, computed once a frame rather
than re-checked per cell) — passing `nil` retains nothing — which
closed the gap back into noise (~1.6 ms both sides, matched runs
immediately before and after the fix). The regression-and-fix, not
just the final number, is the artifact worth keeping: it is a second,
independent instance of the exact failure mode this file's frame-CPU
rule was written to catch.

`BS`/`CUB` also did not reverse-wrap — a program editing at a wrap
boundary (`readline`'s own line editing among them) that expected
backspace to walk back onto the previous row instead saw the cursor
stick at column 0. The quality-plan record that first found this
named the blocker as needing "a behavioural decision" about which
reverse-wrap semantics to implement; xterm's own answer, `?45`
(reverse-wraparound mode, off by default — not DECBKM, which is the
separate `?67` backarrow-key mode) is the one every other terminal a
comparison would be made against also implements, so it is the one
Corta implements too rather than inventing a bespoke variant. Added
`Grid.reverseWraparoundEnabled` (mirrors `insertMode`'s
pattern: a Grid-owned flag a private-mode DECSET/DECRST toggles, with
a DECRQM case reporting it), and taught `moveCursorLeft`/`backspace`
to continue onto the row above's last column when the mode is on and
that row's own `wrapped` flag says the two rows are one logical line
— never across a hard newline, since `wrapped` is set only where
DECAWM's own auto-wrap actually happened (§2.1). `CUB`'s repeat count
can cross more than one wrapped row in a single call; `BS` is always
one step, matching its existing pending-wrap-disarm behaviour.

`exitAlternateScreen` restores the parked main screen wholesale
(`self = main`), the same mechanism `cursorStyle` already has to be
explicitly carried across for the identical reason: a private mode a
program set is terminal-wide state, not part of either screen's own
content, so the parked copy's stale value would otherwise silently
win. `reverseWraparoundEnabled` is now carried across the same way
`cursorStyle` already was — a real gap a review round caught, not
something reasoned out in advance.
