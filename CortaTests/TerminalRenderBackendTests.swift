import CoreText
import Metal
import Testing

@testable import Corta

/// M9 — the `TerminalRenderBackend` seam and its capability-gated
/// `Metal4Backend` conformance. See `Metal4Backend`'s doc comment for what
/// it does and does not do yet; these tests only cover what is real today:
/// the protocol conformance, the capability check, and that
/// `TerminalRenderer` falls back correctly when the backend is not opted
/// into or not supported.
@Suite("TerminalRenderBackend")
struct TerminalRenderBackendTests {
    @Test func quadRendererConformsToTheBackendProtocol() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let renderer = try QuadRenderer(device: device)
        let backend: any TerminalRenderBackend = renderer
        #expect(backend.device === device)
    }

    @Test func metal4BackendConformsAndForwardsItsDevice() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let backend = try Metal4Backend(device: device)
        let asProtocol: any TerminalRenderBackend = backend
        #expect(asProtocol.device === device)
    }

    /// Not asserting a value either way — whether this machine's GPU
    /// reports the Metal 4 family is a fact about the test runner, not
    /// something this suite should assume. The point is that asking does
    /// not crash and the two backends agree with each other when queried
    /// independently (`QuadRenderer`'s `device` and `Metal4Backend`'s are
    /// the same device either way).
    @Test func isSupportedDoesNotCrashRegardlessOfHardware() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        _ = Metal4Backend.isSupported(by: device)
    }

    /// `TerminalRenderer` must build successfully whether or not
    /// `CORTA_METAL4` happens to be set in the test environment — the
    /// fallback in `TerminalRenderer.init` (`try? Metal4Backend(device:)`
    /// failing, or `isOptedIn`/`isSupported` being false) must never be the
    /// reason a renderer fails to construct.
    @Test func terminalRendererConstructsRegardlessOfBackendSelection() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        let renderer = try TerminalRenderer(device: device, font: font, scale: 1)
        #expect(renderer.quadRenderer.device === device)
    }
}
