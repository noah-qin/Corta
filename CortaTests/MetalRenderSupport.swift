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
        var safeWidth = width
        var safeHeight = height
        if !isValid(width) || !isValid(height) {
            Issue.record(
                """
                invalid render target \(width)x\(height): dimensions must be \
                between 1 and \(maximumDimension). Continuing on a 1x1 target \
                so the rest of the run still reports.
                """)
            safeWidth = min(max(width, 1), maximumDimension)
            safeHeight = min(max(height, 1), maximumDimension)
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: QuadRenderer.pixelFormat, width: safeWidth, height: safeHeight,
            mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            // A device that cannot allocate the target cannot render
            // anything, which is the same deliberate assertion `GlyphAtlas`
            // makes when even its minimum atlas fails to allocate.
            preconditionFailure("Metal device refused a \(safeWidth)x\(safeHeight) render target")
        }
        return texture
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
                #expect(texture.width > 0)
                #expect(texture.height > 0)
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
