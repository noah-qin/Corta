import Foundation
import Metal
import Testing

@testable import Corta
import CortaTerminal

/// P05 — image decoding lives off the frame path. The frame path
/// (`texture(for:)`, `draw`) is a pure cache lookup; `update(table:...)`
/// only *schedules* decodes onto an injected scheduler; reused image ids
/// invalidate the texture decoded from the old bytes; and pruning runs even
/// when the last placement disappears.
@Suite("Image decode pipeline (P05)")
struct ImageDecodePipelineTests {
    private static func makeDevice() -> MTLDevice? { MTLCreateSystemDefaultDevice() }

    /// Escaping closures mutate counters, so they need a reference — with a
    /// synchronous/captured scheduler nothing here actually races.
    private final class Counter: @unchecked Sendable {
        var value = 0
    }

    /// Transmits *and places* (`a=T`) a 2×2 RGBA image at the cursor, like
    /// `icat` does, and returns the terminal whose grid holds the table.
    private static func placeRGBA(
        _ terminal: inout Terminal, id: UInt32, byte: UInt8, control: String = ""
    ) {
        let payload = [UInt8](repeating: byte, count: 2 * 2 * 4)
        let suffix = control.isEmpty ? "" : ",\(control)"
        let command = "\u{1B}_Ga=T,i=\(id),f=32,s=2,v=2\(suffix);\(Data(payload).base64EncodedString())\u{1B}\\"
        terminal.feed(Array(command.utf8))
    }

    private static func table(of terminal: Terminal) -> ImagePlacementTable {
        terminal.grid.imagePlacements
    }

    private static func makeRenderer(
        device: MTLDevice,
        decodeCount: Counter,
        scheduled: @escaping (@escaping () -> Void) -> Void
    ) -> KittyImageRenderer {
        KittyImageRenderer(
            device: device,
            decodeImage: { data in
                decodeCount.value += 1
                return KittyImageRenderer.decode(data)
            },
            decodeScheduler: scheduled)
    }

    private let updateArgs = (rows: 10, cellWidth: Float(10), cellHeight: Float(20))

    @Test("the frame path never decodes: update schedules, lookups only read")
    func framePathNeverDecodes() throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let decodeCount = Counter()
        var work: [() -> Void] = []
        let renderer = Self.makeRenderer(device: device, decodeCount: decodeCount) { work.append($0) }
        var terminal = Terminal(rows: 10, columns: 40)
        Self.placeRGBA(&terminal, id: 1, byte: 0xFF)
        let id = KittyGraphics.ImageID(rawValue: 1)

        // One update: the decode is scheduled, not performed, and a
        // frame-path lookup finds nothing yet — without decoding anything.
        renderer.update(
            table: Self.table(of: terminal), rows: updateArgs.rows, offset: 0,
            scrollbackCount: 0, cellWidth: updateArgs.cellWidth, cellHeight: updateArgs.cellHeight)
        #expect(work.count == 1)
        #expect(decodeCount.value == 0)
        #expect(renderer.texture(for: id) == nil)
        #expect(decodeCount.value == 0, "a frame-path lookup must never decode")

        // The scheduled work runs (off the frame path in production):
        // exactly one decode, then the texture exists.
        for item in work { item() }
        #expect(decodeCount.value == 1)
        #expect(renderer.texture(for: id) != nil)

        // Later frames are pure cache hits: no reschedule, no re-decode.
        renderer.update(
            table: Self.table(of: terminal), rows: updateArgs.rows, offset: 0,
            scrollbackCount: 0, cellWidth: updateArgs.cellWidth, cellHeight: updateArgs.cellHeight)
        #expect(work.count == 1)
        #expect(renderer.texture(for: id) != nil)
        #expect(decodeCount.value == 1)
    }

    @Test("a reused image id invalidates the texture decoded from the old bytes")
    func reusedImageIDInvalidatesOldTexture() throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let decodeCount = Counter()
        let renderer = Self.makeRenderer(device: device, decodeCount: decodeCount) { $0() }
        var terminal = Terminal(rows: 10, columns: 40)
        let id = KittyGraphics.ImageID(rawValue: 1)

        Self.placeRGBA(&terminal, id: 1, byte: 0xFF)
        renderer.update(
            table: Self.table(of: terminal), rows: updateArgs.rows, offset: 0,
            scrollbackCount: 0, cellWidth: updateArgs.cellWidth, cellHeight: updateArgs.cellHeight)
        let first = try #require(renderer.texture(for: id))
        #expect(decodeCount.value == 1)

        // Same id, new transmission: the placement table's generation moved,
        // so the cached texture is stale and the image re-decodes once.
        Self.placeRGBA(&terminal, id: 1, byte: 0x7F)
        renderer.update(
            table: Self.table(of: terminal), rows: updateArgs.rows, offset: 0,
            scrollbackCount: 0, cellWidth: updateArgs.cellWidth, cellHeight: updateArgs.cellHeight)
        let second = try #require(renderer.texture(for: id))
        #expect(decodeCount.value == 2)
        #expect(first !== second)
    }

    @Test("deleting the last placement releases its texture and budget")
    func lastPlacementDisappearingReleasesTexture() throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let renderer = Self.makeRenderer(device: device, decodeCount: Counter()) { $0() }
        var terminal = Terminal(rows: 10, columns: 40)
        Self.placeRGBA(&terminal, id: 1, byte: 0xFF)
        renderer.update(
            table: Self.table(of: terminal), rows: updateArgs.rows, offset: 0,
            scrollbackCount: 0, cellWidth: updateArgs.cellWidth, cellHeight: updateArgs.cellHeight)
        #expect(renderer.textureCount == 1)
        #expect(renderer.cachedTextureBytes == 16)

        // a=d,d=i — the image and its placements go away. Pruning must run
        // even though the table is now empty (the pre-P05 prune bailed out
        // early on an empty placement list and leaked the texture).
        terminal.feed(Array("\u{1B}_Ga=d,d=i,i=1\u{1B}\\".utf8))
        renderer.update(
            table: Self.table(of: terminal), rows: updateArgs.rows, offset: 0,
            scrollbackCount: 0, cellWidth: updateArgs.cellWidth, cellHeight: updateArgs.cellHeight)
        #expect(renderer.textureCount == 0)
        #expect(renderer.cachedTextureBytes == 0)
    }

    @Test("a placement scrolled out of view is not decoded until it scrolls back")
    func offscreenPlacementIsNotDecoded() throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let decodeCount = Counter()
        let renderer = Self.makeRenderer(device: device, decodeCount: decodeCount) { $0() }
        var terminal = Terminal(rows: 10, columns: 40)
        Self.placeRGBA(&terminal, id: 1, byte: 0xFF, control: "c=2,r=1")
        // Scroll the placement far above the viewport.
        terminal.feed(Array(String(repeating: "\r\n", count: 30).utf8))
        let scrollbackCount = terminal.grid.scrollback.count
        #expect(scrollbackCount >= 20)

        renderer.update(
            table: Self.table(of: terminal), rows: updateArgs.rows, offset: 0,
            scrollbackCount: scrollbackCount, cellWidth: updateArgs.cellWidth,
            cellHeight: updateArgs.cellHeight)
        #expect(decodeCount.value == 0, "a provably offscreen placement must not decode")
        #expect(renderer.textureCount == 0)

        // Scrolled all the way up, the placement is visible again and the
        // decode happens then.
        renderer.update(
            table: Self.table(of: terminal), rows: updateArgs.rows, offset: scrollbackCount,
            scrollbackCount: scrollbackCount, cellWidth: updateArgs.cellWidth,
            cellHeight: updateArgs.cellHeight)
        #expect(decodeCount.value == 1)
        #expect(renderer.textureCount == 1)
    }

    @Test("a decode failure is not retried per frame, but a re-transmission is")
    func failureIsPerTransmissionNotPermanent() throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let decodeCount = Counter()
        let renderer = Self.makeRenderer(device: device, decodeCount: decodeCount) { $0() }
        var terminal = Terminal(rows: 10, columns: 40)
        // A corrupt PNG (f=100): stored by the core, fails the decode.
        terminal.feed(Array("\u{1B}_Ga=T,i=1,f=100;\(Data([UInt8](repeating: 0, count: 32)).base64EncodedString())\u{1B}\\".utf8))

        for _ in 0..<3 {
            renderer.update(
                table: Self.table(of: terminal), rows: updateArgs.rows, offset: 0,
                scrollbackCount: 0, cellWidth: updateArgs.cellWidth,
                cellHeight: updateArgs.cellHeight)
        }
        #expect(decodeCount.value == 1, "a failed image must not retry the decode every frame")
        #expect(renderer.textureCount == 0)

        // Same id, valid bytes this time: the failure was recorded per
        // transmission, so the re-transmission gets a fresh attempt.
        Self.placeRGBA(&terminal, id: 1, byte: 0xFF)
        renderer.update(
            table: Self.table(of: terminal), rows: updateArgs.rows, offset: 0,
            scrollbackCount: 0, cellWidth: updateArgs.cellWidth, cellHeight: updateArgs.cellHeight)
        #expect(decodeCount.value == 2)
        #expect(renderer.textureCount == 1)
    }

    @Test("a finished decode asks the shell for a frame")
    func decodeCompletionRequestsRedraw() throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let renderer = Self.makeRenderer(device: device, decodeCount: Counter()) { $0() }
        let notified = Counter()
        renderer.onImagesReady = { notified.value += 1 }
        var terminal = Terminal(rows: 10, columns: 40)
        Self.placeRGBA(&terminal, id: 1, byte: 0xFF)
        renderer.update(
            table: Self.table(of: terminal), rows: updateArgs.rows, offset: 0,
            scrollbackCount: 0, cellWidth: updateArgs.cellWidth, cellHeight: updateArgs.cellHeight)
        #expect(notified.value == 1)
        // A steady frame with nothing new does not notify again.
        renderer.update(
            table: Self.table(of: terminal), rows: updateArgs.rows, offset: 0,
            scrollbackCount: 0, cellWidth: updateArgs.cellWidth, cellHeight: updateArgs.cellHeight)
        #expect(notified.value == 1)
    }
}
