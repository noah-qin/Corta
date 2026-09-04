import CoreGraphics
import Metal

/// The GPU-encoding seam `TerminalRenderer` draws through — everything
/// downstream of the CPU-side instance arrays (`QuadInstance`), which are
/// backend-agnostic: building them from a `Grid` never touches Metal at
/// all. `QuadRenderer` conforms to this today; `Metal4Backend` is a second,
/// capability-gated conformance — see that type's doc comment for what it
/// actually does right now and why.
///
/// Introduced (M9) for the same reason `TerminalRenderBackend` is always
/// introduced ahead of a second real implementation: so the *selection*
/// point (`TerminalRenderer.init` choosing which backend to build) exists
/// and is exercised before there is a second backend worth measuring against
/// the first, rather than retrofitting a protocol around one concrete type
/// later under time pressure.
nonisolated protocol TerminalRenderBackend: AnyObject {
    /// The device this backend's pipelines and buffers were created
    /// against — every backend has one, whichever GPU API it encodes
    /// through.
    var device: MTLDevice { get }

    /// Draws solid-colour `instances` into `rect` (pixels, relative to the
    /// render target's origin) of `renderPassDescriptor`.
    func drawSolidQuads(
        _ instances: [QuadInstance],
        rect: CGRect,
        drawableSize: CGSize,
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    )

    /// Draws `instances` sampled from `atlas` into `rect`.
    func drawGlyphQuads(
        _ instances: [QuadInstance],
        atlas: MTLTexture,
        rect: CGRect,
        drawableSize: CGSize,
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    )

    /// Draws `instances` sampled from the *color* atlas into `rect`.
    func drawColorQuads(
        _ instances: [QuadInstance],
        atlas: MTLTexture,
        rect: CGRect,
        drawableSize: CGSize,
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    )
}

nonisolated extension QuadRenderer: TerminalRenderBackend {}
