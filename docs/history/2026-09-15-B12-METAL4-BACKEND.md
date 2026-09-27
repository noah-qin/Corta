# B12 Metal 4 backend, measured against the MTL3 path — 2026-09-15

Moved from `PERFORMANCE.md` §8 on 2026-09-27 (#117). This is the record
as it was written; a bare `§n` below refers to `PERFORMANCE.md`, and
`PERFORMANCE.md` §5.6 keeps the current numbers.

**The forwarding `Metal4Backend` is replaced by a real MTL4 submission
backend** — `MTL4CommandQueue`, persistent per-slot `MTL4CommandBuffer`s,
per-slot `MTL4CommandAllocator`s, `MTL4RenderCommandEncoder`, one reused
`MTL4ArgumentTable` (address-bound instances/uniforms, resource-ID-bound
atlas), an `MTLResidencySet`, and drawable sequencing via
`waitForDrawable`/`signalDrawable` + `MTLDrawable.present`. Pipelines are
the classic `MTLRenderPipelineState` — that is the type MTL4's encoder
takes, not a gap. The MTL3-shaped base-protocol methods forward to a
lazily-built `QuadRenderer` so a stray caller still gets correct output.
Selection stays opt-in (`CORTA_METAL4=1` + `supportsFamily(.metal4)`),
falling back to `QuadRenderer` on any construction failure; the default
backend is unchanged. `TerminalRenderBackendTests` renders identical
instance arrays through both backends offscreen and compares pixels, so
the two paths cannot drift silently.

Two faults only the live drawable path could produce were found by
running the real app and fixed:

1. **Residency** — a texture bound by `gpuResourceID` through an argument
   table is neither retained nor kept resident by MTL4 (`.managed`
   storage included); the first live run faulted at launch with
   `kIOGPUCommandBufferCallbackErrorPageFault`. Every bound texture now
   enters the queue's residency set on first use and is retained until
   the last frame that bound it has completed — plus a 60-frame grace,
   because with the GPU keeping up an exact "last frame completed" rule
   evicted and re-added the atlas every single frame (two residency-set
   commits per frame per texture) for a texture bound every frame.
2. **Completion signalling** — a queue-signalled `MTLSharedEvent` never
   advanced against a live `CAMetalDisplayLink` drawable stream, so every
   `beginFrame` past the ring depth waited out its one-second timeout and
   the window rendered ~1 frame/s. The completion gate now rides the
   commit-feedback handler (the callback that demonstrably fires), and
   commit faults are logged (bounded) instead of failing silently; a
   queue whose work never completes stops encoding after three
   consecutive timeouts rather than stalling-and-reallocating per frame.

**A/B under an identical sustained `yes`-flood workload** (Release build,
real window, frontmost, `CORTA_RENDER_METRICS=1` rings, 600-frame dumps;
Mac17,3 / Apple M5, 32 GB, macOS 26.6.2 (25G83), Xcode 26.6, built-in
1470×956@2x 60 Hz, AC power, low-power off; numbers are the medians of
the per-dump p50/p99 across 5–7 dumps per config, plus the worst max):

| config | cpuFrame p50 | cpuFrame p99 | gpu p50 | gpu p99 | worst max (cpu) |
| --- | --- | --- | --- | --- | --- |
| MTL3 default | 2.17 ms | 9.49 ms | 0.53 ms | 3.93 ms | 16.84 ms |
| **Metal 4** | **1.79 ms** | 10.01 ms | 0.55 ms | 3.74 ms | 18.43 ms |
| `CORTA_MAX_DRAWABLES=2` | 1.15 ms | 7.55 ms | 0.53 ms | 3.80 ms | 14.91 ms |
| `CORTA_FRAME_LATENCY=2` | 1.29 ms | 9.16 ms | 0.53 ms | 3.79 ms | 36.83 ms |

`drawableWait` was 0.00 ms at every percentile in every config — the
pre-resolved display-link drawable never stalls this workload. Honest
reading: Metal 4 submission is functional and fault-free and its cpuFrame
p50 edge (2.17 → 1.79 ms) is within cross-run drift (the same MTL3 binary
measured 3.88–6.11 ms avg across earlier same-day runs), so **no
performance claim is made**; the backend exists as the real implementation
the roadmap requires, default stays MTL3, and the comparison is now
repeatable. The drawable-2 and latency-2 deltas are likewise within
run-to-run drift and change nothing: defaults stand, both env hooks stay
as measurement seams. The `preferredFrameLatency` follow-up named in
`RenderPolicy.swift` is now instrumented (`CORTA_FRAME_LATENCY`) but its
numbers here are flood-only; typing-latency judgment is §5.7's measure —
not judged.

**Re-measured after the residency grace (2026-09-15, review pass).**
Same shape of run — Release build, real window launched through
LaunchServices, `CORTA_RENDER_METRICS=1`, a 40 s `yes` flood through a
`SHELL=` script, one 600-frame dump per config — after bound textures
stopped leaving and re-entering the residency set every frame:

| config | cpuFrame p50 | cpuFrame p99 | gpu p50 | gpu p99 | commit faults |
| --- | --- | --- | --- | --- | --- |
| MTL3 default | 0.75 ms | 3.32 ms | 0.63 ms | 4.54 ms | — |
| Metal 4 | 0.73 ms | 2.77 ms | 0.59 ms | 1.33 ms | 0 |

Still within drift of each other; still no speedup claimed. The
hosted-XCTest frame-CPU baseline (`FrameCPUBaselineTests`, 120×40, Debug)
read 2.04–2.16 ms avg on this branch against 2.00–2.22 ms on `main` over
three runs each — no regression from the branch's render-loop changes.

**Cross-pane pipeline/sampler sharing — done.** `QuadPipelineCache`
(per-device, immutable-after-creation) holds the three pipeline states
and sampler both backends share; the M9 binary-archive warm-up moved into
the cache's creation path and now covers `Metal4Backend` too. Renderer
construction, n=8, hosted-XCTest Debug (archive reads disabled, so
"cold" is a real compile — an upper bound): before, p50 10.666 ms per
pane; after, pane 1 unchanged (9.9–11.6 ms cold) and panes 2…n pay
0.000–0.001 ms — a dictionary lookup. Atlas sharing was evaluated and not
done: a `GlyphAtlas` is single-threaded mutable state whose eviction
bumps a generation counter that full-rebuilds every consumer's instance
cache, so sharing couples every pane's damage tracking to the union of
all panes' glyph churn — a per-frame cost to buy ~20 MB/pane of memory.
The evaluation lives at `TerminalRenderer.init`.

**Bounded partial instance uploads — measured, reverted.** A full
experiment (dirty-range tracking + ranged ring writes) cut typing-scene
uploads 41× (224 520 → 5 464 B/frame) for a ~15 µs p50 frame-CPU win
against the 4 ms budget, while scroll-shift and full-rebuild — the cases
where upload volume is real — cannot win by construction and paid small
bookkeeping regressions (120×40 grid; typing 0.058→0.043 ms p50, scroll
0.066→0.076, rebuild 1.209→1.236). Not a clear win → reverted; the
benchmark harness (`InstanceUploadBenchmarkTests`) stays. The experiment
surfaced one real inefficiency, recorded for a later pass: the ring
allocates exact-fit buffers, so any growing array reallocates and
full-uploads every frame today.

**Render-pass/state audit.** `QuadRenderer.draw` now skips encoder
creation for a provably-empty pass under `.load` (pixel-identical; the
`.clear` first pass still always runs), and `Metal4Backend` dedupes
scissor/viewport/pipeline sets within its single per-frame encoder. The
largest finding is recorded but not done: the up-to-three MTL3 passes per
frame (plus one per Kitty placement) each cost a tile load/store round
trip; merging them into one encoder needs a scoped-pass API and is a
separate change.

**Energy.** `scripts/measure-energy.sh` now exists (idle / occluded /
background-flood / 2-window / kitty-image scenarios, §5.1 distributions,
§5.2 environment header), closing the §1.1 gap's tooling half. On this
machine `powermetrics` needs a sudo-capable session, which this pass did
not have: wattage sampling is **not run**, and the harness's degraded
top-based path has not been executed end-to-end either — the gap narrows
to "harness exists and is untested", stated plainly rather than closed.
Thermal and low-power scenarios are not forceable without changing
machine-wide state: not judged.
