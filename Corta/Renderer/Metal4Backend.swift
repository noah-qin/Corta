import CoreGraphics
import Foundation
import Metal

/// A `TerminalRenderBackend` built on the Metal 4 command-submission API
/// (`MTL4CommandQueue`, `MTL4CommandBuffer`, `MTL4CommandAllocator`,
/// argument tables — `MTL4CommandQueue.h` et al.) instead of the traditional
/// `MTLCommandQueue`/`MTLRenderCommandEncoder` path `QuadRenderer` uses.
///
/// **What this actually does right now.** `isSupported(by:)` is a real,
/// accurate capability check (`MTLGPUFamily.metal4`, available macOS 26).
/// The type exists, conforms to `TerminalRenderBackend`, and
/// `TerminalRenderer.init` will select it over `QuadRenderer` when a caller
/// opts in (`CORTA_METAL4=1`, the same measurement-harness-env-var pattern
/// as `CORTA_MAX_DRAWABLES` — not a config key, `CLAUDE.md`) on hardware
/// that reports support. What it does *not* yet do is encode through the
/// `MTL4*` types at all: every draw call below builds and immediately
/// forwards to an internally owned `QuadRenderer`, so selecting this
/// backend today changes nothing about what actually renders.
///
/// **Why the seam exists before the implementation.** Corta's own workload
/// is two to three draw calls a frame — Metal 4's whole point is lowering
/// per-encode CPU/memory overhead, which only shows up with many more
/// encoded commands than that, so the honest expectation (stated in the
/// original request that led to this type) is "measure before trusting it
/// helps here." A correct `MTL4CommandQueue`/`MTL4CommandAllocator`/argument
/// table implementation is a substantial, unfamiliar API surface — 30-plus
/// headers, several with C-array-based methods that need careful,
/// individually-verified Swift bridging — and the risk of a wrong binding
/// or a missed barrier is silent GPU corruption or a driver-level hang, not
/// a compile error. Landing a real implementation nobody has run is a worse
/// outcome than landing the seam, the capability check, and an honest
/// pass-through, and following up with the actual encoder work as its own
/// change once it can be built against the compiler and measured against
/// `QuadRenderer` the way `RenderMetrics` (M9) is built to compare them.
nonisolated final class Metal4Backend: TerminalRenderBackend {
    private let legacy: QuadRenderer
    var device: MTLDevice { legacy.device }

    /// Whether `device` reports the Metal 4 GPU family. Does not by itself
    /// mean this backend does anything different yet — see the type's doc
    /// comment — only that it is safe to *select*.
    static func isSupported(by device: MTLDevice) -> Bool {
        device.supportsFamily(.metal4)
    }

    /// Opt-in, and only ever consulted alongside `isSupported(by:)` — see
    /// the type's doc comment on why this is not yet on by default for
    /// every capable device.
    static var isOptedIn: Bool {
        ProcessInfo.processInfo.environment["CORTA_METAL4"] == "1"
    }

    init(device: MTLDevice) throws {
        self.legacy = try QuadRenderer(device: device)
    }

    func drawSolidQuads(
        _ instances: [QuadInstance], rect: CGRect, drawableSize: CGSize,
        renderPassDescriptor: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer
    ) {
        legacy.drawSolidQuads(
            instances, rect: rect, drawableSize: drawableSize,
            renderPassDescriptor: renderPassDescriptor, commandBuffer: commandBuffer)
    }

    func drawGlyphQuads(
        _ instances: [QuadInstance], atlas: MTLTexture, rect: CGRect, drawableSize: CGSize,
        renderPassDescriptor: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer
    ) {
        legacy.drawGlyphQuads(
            instances, atlas: atlas, rect: rect, drawableSize: drawableSize,
            renderPassDescriptor: renderPassDescriptor, commandBuffer: commandBuffer)
    }

    func drawColorQuads(
        _ instances: [QuadInstance], atlas: MTLTexture, rect: CGRect, drawableSize: CGSize,
        renderPassDescriptor: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer
    ) {
        legacy.drawColorQuads(
            instances, atlas: atlas, rect: rect, drawableSize: drawableSize,
            renderPassDescriptor: renderPassDescriptor, commandBuffer: commandBuffer)
    }
}
