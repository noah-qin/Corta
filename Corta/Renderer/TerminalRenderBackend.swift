import CoreGraphics
import Metal

/// The GPU-encoding seam `TerminalRenderer` draws through — everything
/// downstream of the CPU-side instance arrays (`QuadInstance`), which are
/// backend-agnostic: building them from a `Grid` never touches Metal at
/// all. `QuadRenderer` conforms to this today; `Metal4Backend` is a second,
/// capability-gated conformance — see that type's doc comment for what it
/// actually does right now and why.
///
/// Introduced for the same reason `TerminalRenderBackend` is always
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

/// The Metal 4 half of the backend seam: full-frame command
/// submission, owned end-to-end by the backend.
///
/// The base protocol's three `draw*Quads` methods are Metal-3-shaped: the
/// caller owns the `MTLCommandBuffer` and `MTLRenderPassDescriptor` and
/// hands them down per draw call. Metal 4 has no `MTLCommandBuffer` to hand
/// over — an `MTL4CommandQueue` commits `MTL4CommandBuffer`s the backend
/// itself began from an `MTL4CommandAllocator`, and drawable presentation
/// is a queue operation (`signalDrawable`) followed by `MTLDrawable.present`
/// — so a backend submitting through MTL4 conforms to this instead:
/// `beginFrame` opens the command buffer and the render pass (and so owns
/// the frame's clear), the draw calls encode into it in the same order the
/// MTL3 path uses, and `endFrame` ends, commits, signals and presents.
///
/// `TerminalRenderer.draw(through:...)` drives the sequence;
/// `ViewController.render(into:...)` selects it when the renderer's backend
/// conforms, leaving the MTL3 path — which remains the default — untouched.
nonisolated protocol Metal4FrameBackend: TerminalRenderBackend {
    /// Opens a frame targeting `target`, clearing it to `clearColor` on
    /// load — matching the clear pass the MTL3 path's first draw call runs,
    /// so a frame that draws nothing still clears. `label` becomes the
    /// command buffer's GPU-capture label (the MTL3 path's
    /// `Corta.frame.<pane>`).
    func beginFrame(target: MTLTexture, clearColor: MTLClearColor, label: String)

    /// The `TerminalRenderBackend.draw*Quads` trio without the Metal 3
    /// parameters: same instances, same rect/drawableSize semantics, encoded
    /// into the open frame.
    func drawSolidQuads(_ instances: [QuadInstance], rect: CGRect, drawableSize: CGSize)
    func drawGlyphQuads(
        _ instances: [QuadInstance], atlas: MTLTexture, rect: CGRect, drawableSize: CGSize)
    func drawColorQuads(
        _ instances: [QuadInstance], atlas: MTLTexture, rect: CGRect, drawableSize: CGSize)

    /// Ends the frame's encoding, commits it, and presents `drawable` (nil
    /// for offscreen renders, e.g. tests). `onCompleted` runs after the
    /// GPU finishes the frame — the counterpart of the MTL3 path's
    /// `addCompletedHandler`, feeding the same metrics — and carries the
    /// commit's error when one occurred: a faulted commit must surface,
    /// not silently render nothing.
    func endFrame(
        presenting drawable: (any MTLDrawable)?,
        onCompleted: (@Sendable ((any Error)?) -> Void)?)
}
