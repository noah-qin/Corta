import Foundation
import Metal
import Testing

@testable import Corta

/// The one render target every Metal suite draws into.
///
/// It exists because each suite used to build its own and force-unwrap
/// `makeTexture`: a descriptor Metal refused aborted the whole test runner
/// inside `-[MTLTextureDescriptorInternal validateWithDevice:]`, taking four
/// hundred unrelated tests with it, and the crash report carries no
/// dimensions — so the next run learned nothing about what was wrong (T07).
/// The size is checked here, and a bad one fails its own test with the
/// numbers in the message.
enum MetalRenderTarget {

    /// The largest 2D texture any Metal GPU family in the deployment target
    /// supports. A descriptor past it is a test computing a size wrongly,
    /// not a device this project has to accommodate.
    static let maximumDimension = 16384

    /// A colour render target of exactly `width` x `height`, in the format
    /// and storage mode every render suite here uses.
    ///
    /// A degenerate or absurd size fails the test that asked for it — with
    /// the numbers in the message — and the run continues on a 1x1 stand-in.
    /// Handing the numbers straight to Metal instead ends the process.
    static func make(device: MTLDevice, width: Int, height: Int) -> MTLTexture {
        // A 1x1 stand-in, not a clamp. Clamping an absurd request down to
        // the maximum would still allocate a 16384-wide texture to satisfy a
        // test that has already been told it asked for the wrong thing — and
        // on a device that refuses that allocation it would end the process,
        // which is the failure mode this type exists to remove.
        if !isValid(width) || !isValid(height) {
            Issue.record(
                """
                invalid render target \(width)x\(height): dimensions must be \
                between 1 and \(maximumDimension). Continuing on a 1x1 target \
                so the rest of the run still reports.
                """)
            return standIn(device: device)
        }
        guard let texture = texture(device: device, width: width, height: height) else {
            // Valid but unallocatable — a size past what this particular
            // device will give out. Reported the same way and continued the
            // same way, since the run has more to say than this one texture.
            Issue.record("the device refused a \(width)x\(height) render target")
            return standIn(device: device)
        }
        return texture
    }

    private static func standIn(device: MTLDevice) -> MTLTexture {
        guard let texture = texture(device: device, width: 1, height: 1) else {
            // A device that cannot allocate one pixel cannot render anything,
            // which is the same deliberate assertion `GlyphAtlas` makes when
            // even its minimum atlas fails.
            preconditionFailure("Metal device refused a 1x1 render target")
        }
        return texture
    }

    private static func texture(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: QuadRenderer.pixelFormat, width: width, height: height,
            mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed
        return device.makeTexture(descriptor: descriptor)
    }

    private static func isValid(_ dimension: Int) -> Bool {
        dimension > 0 && dimension <= maximumDimension
    }
}

/// The guard itself, since everything else in `CortaTests` now depends on it
/// to fail rather than to abort.
@Suite(.serialized, .metalSerialized) struct MetalRenderTargetTests {

    @Test("a degenerate size fails its own test instead of the whole run")
    func degenerateSizeIsRecordedNotFatal() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        for (width, height) in [(0, 10), (10, 0), (-4, 10), (MetalRenderTarget.maximumDimension + 1, 10)] {
            withKnownIssue("the size is reported, and the run continues") {
                let texture = MetalRenderTarget.make(device: device, width: width, height: height)
                // A stand-in, not a clamp: an absurd request must not turn
                // into an enormous allocation.
                #expect(texture.width == 1)
                #expect(texture.height == 1)
            }
        }
    }

    @Test("a valid size is passed through unchanged")
    func validSizeIsNotClamped() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let texture = MetalRenderTarget.make(device: device, width: 64, height: 32)
        #expect(texture.width == 64)
        #expect(texture.height == 32)
        #expect(texture.pixelFormat == QuadRenderer.pixelFormat)
    }
}
