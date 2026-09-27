# B12 rendering diagnostics and a rejected prewarm — 2026-09-13

Moved from `PERFORMANCE.md` §7 on 2026-09-27 (#117). This is the record
as it was written; a bare `§n` below refers to `PERFORMANCE.md`, and
`PERFORMANCE.md` §5.6 keeps the current numbers.

**Metal/Instruments correlation labels.** `QuadRenderer`'s three render
command encoders (solid/glyph/color-glyph) and `ViewController`'s
per-pane command buffer now carry a `label` and, for the encoders, a
`pushDebugGroup`/`popDebugGroup` pair (`Corta.solid`, `Corta.glyph`,
`Corta.colorGlyph`, `Corta.frame.<pane>`). This is the B12 "platform
diagnostics/state labels that correlate terminal scenarios with
Instruments/Metal traces" scope item: a GPU frame capture or Metal
System Trace can now attribute a command buffer to a pane and an encoder
to which of the up-to-three passes it was. Purely additive — no draw
call, pipeline state or blend changed; `CortaTests` (529 tests, offscreen
only, no `CortaUITests`) stayed green.

**Cold-startup / first-frame measurement.** Added
`GlyphAtlasTests.measureColdStartupAndFirstFrameCost` (non-asserting,
same pattern as `FrameCPUBaselineTests`): times `GlyphAtlas.init` and a
simulated first screenful of ordinary text (120 columns × the printable
ASCII range, one style) against it, writing both numbers to
`CORTA_ATLAS_BASELINE_OUTPUT` (default `/tmp/corta-atlas-cold-startup-
baseline.txt`). This is the B12 "measure Core Text lookup/rasterization/
atlas alloc-eviction/cold startup" scope item.

**A bounded eager ASCII prewarm was built against that measurement and
rejected.** The idea (B12's "bounded prewarming instead of unlimited
growth" bullet): populate the ASCII atlas page for all four styles
(regular/bold/italic/bold-italic, 380 glyphs total) at `GlyphAtlas.init`
and on every `reset(font:)`, so the first frame never pays per-glyph
rasterization. Measured on this machine, `-c release`-equivalent
(Debug scheme, offscreen `CortaTests`, no UI):

| | Cold init | First simulated frame (1 style) |
| --- | --- | --- |
| Without prewarm | 0.29–0.79 ms | 3.28–3.53 ms |
| With prewarm (4 styles) | 5.48 ms | 2.35 ms |

Prewarming *does* make the first frame in the tested style faster (by
about 1.1–1.2 ms — the cost of rasterizing that style's 95 glyphs, paid
early instead of on demand), but a typical session uses one, maybe two
of the four styles on its first screen, and the prewarm pays for all
four regardless: cold init grew by roughly 4.7–5.2 ms to buy back at
most ~1.2 ms, a net loss against the very "Startup" target
(`PERFORMANCE.md` §1.1) it was meant to help, and pure waste for the two
or three styles a given session's first screen never uses at all. Not
kept. The measurement test stays as the harness for a narrower version
of the idea later — prewarming only the one style a fresh pane actually
starts in, say — which this pass did not attempt because that requires
plumbing which style is "the default" through to `GlyphAtlas.init`,
a larger change than this measurement pass's scope.

**Everything else in B12's scope was not attempted this pass**, for the
reason stated in `Metal4Backend.swift`'s own doc comment: replacing the
forwarding backend with a real `MTL4CommandQueue`/`MTL4CommandAllocator`
implementation risks silent GPU corruption or a driver-level hang on a
wrong binding, not a compile error, and this pass had no way to visually
verify a frame — no UI test, no Instruments capture against a running
window. Cross-pane resource sharing (atlas/pipeline/font across split
panes) was evaluated as a design (`B11/B12` research pass) and not
attempted for the same reason: it changes per-pane object lifetime in
`ViewController`/`SplitViewController`, which `CLAUDE.md`'s own working
rules flag as needing a live-app check offscreen tests cannot substitute
for. Display-link/drawable-depth comparison and redundant-render-pass
removal were reviewed against the existing M8/M9 measurements and found
already addressed (`§5.4`'s A/B, and `QuadRenderer.draw`'s one encoder
per pass with no repeated state sets) — no further change is justified
by anything measured here.
