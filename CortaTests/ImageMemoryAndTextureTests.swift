import CoreGraphics
import CoreText
import CortaTerminal
import Foundation
import Metal
import Testing

@testable import Corta

/// S02/S07 — the app-layer half of the image memory budgets: PNG dimension
/// inspection before decoding, per-pane and app-wide GPU texture byte
/// budgets, LRU eviction, and graceful degradation when Metal texture
/// allocation fails (both for image textures and the glyph atlas).
///
/// `.serialized`: the atlas tests build a `GlyphAtlas`, which is
/// single-threaded by design — see the type's comment.
@Suite(.serialized, .metalSerialized) struct ImageMemoryAndTextureTests {
    private static func makeDevice() -> MTLDevice? { MTLCreateSystemDefaultDevice() }

    /// Transmits `payload` over the wire exactly like a real client and
    /// pulls the stored `ImageData` back out of the table — the renderer's
    /// cache is driven with what the protocol layer actually accepted, not
    /// a hand-built stand-in.
    private static func transmit(_ control: String, payload: [UInt8], id: UInt32) -> KittyGraphics.ImageData? {
        var terminal = Terminal(rows: 10, columns: 40)
        let base64 = Data(payload).base64EncodedString()
        terminal.feed(Array("\u{1B}_G\(control);\(base64)\u{1B}\\".utf8))
        return terminal.grid.imagePlacements.image(KittyGraphics.ImageID(rawValue: id))
    }

    private static func rgbaImage(id: UInt32, width: Int, height: Int) -> KittyGraphics.ImageData? {
        transmit(
            "a=t,i=\(id),f=32,s=\(width),v=\(height)",
            payload: [UInt8](repeating: 0xFF, count: width * height * 4), id: id)
    }

    // MARK: - PNG dimension inspection before decoding (S02)

    /// A valid PNG whose IHDR claims 100000×100000: the codestream is a
    /// real 1×1 image (built by ImageIO itself), with only the header's
    /// dimension fields and CRC rewritten. Rejecting it proves the
    /// dimensions were checked off the header — had the decode run, the
    /// 1×1 payload would have succeeded.
    @Test("a PNG whose header declares absurd dimensions is rejected before decoding")
    func pngWithAbsurdDeclaredDimensionsIsRejected() throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let renderer = KittyImageRenderer(device: device)
        let imageData = try #require(Self.transmit("a=t,i=1,f=100", payload: Self.oversizedHeaderPNG(), id: 1))
        #expect(renderer.texture(for: KittyGraphics.ImageID(rawValue: 1), data: imageData) == nil)
        #expect(renderer.textureCount == 0)
    }

    @Test("a corrupt or truncated PNG header fails the decode gracefully")
    func corruptPNGHeaderFailsGracefully() {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let renderer = KittyImageRenderer(device: device)
        for (index, payload) in [
            [UInt8](repeating: 0x00, count: 64),  // not a PNG at all
            [0x89, 0x50, 0x4E, 0x47],  // truncated signature
        ].enumerated() {
            let id = UInt32(index + 1)
            let imageData = Self.transmit("a=t,i=\(id),f=100", payload: payload, id: id)
            #expect(imageData != nil, "the core stores the bytes; validation is the renderer's job")
            if let imageData {
                #expect(renderer.texture(for: KittyGraphics.ImageID(rawValue: id), data: imageData) == nil)
            }
        }
        #expect(renderer.textureCount == 0)
    }

    // MARK: - Texture allocation failure (S07)

    @Test("a failing texture allocation degrades to no image instead of trapping")
    func textureAllocationFailureDegradesInsteadOfTrapping() throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let renderer = KittyImageRenderer(device: device) { _ in nil }
        let imageData = try #require(Self.rgbaImage(id: 1, width: 2, height: 2))
        let id = KittyGraphics.ImageID(rawValue: 1)
        #expect(renderer.texture(for: id, data: imageData) == nil)
        // Remembered as failed — a second ask does not retry the allocation
        // every frame, and the renderer itself is still usable.
        #expect(renderer.texture(for: id, data: imageData) == nil)
        #expect(renderer.textureCount == 0)
        #expect(renderer.cachedTextureBytes == 0)
    }

    @Test("the glyph atlas falls back to a smaller texture instead of trapping on allocation failure")
    func glyphAtlasFallsBackToASmallerTexture() throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        let atlas = GlyphAtlas(device: device, font: font, atlasPixelSize: 2048) { descriptor in
            descriptor.width > 512 ? nil : device.makeTexture(descriptor: descriptor)
        }
        #expect(atlas.isDegraded)
        #expect(atlas.atlasPixelSize == 512)
        // Degraded, not dead: glyphs still rasterise and cache.
        let glyph = try #require(atlas.glyph(forASCII: UInt32(0x41), bold: false))  // A
        #expect(glyph.size != .zero)
        #expect(atlas.fastPathHits > 0)
    }

    // MARK: - GPU byte budgets (S02)

    @Test("over the per-pane texture budget, the least-recently-used texture is evicted")
    func perPaneTextureBudgetEvictsLeastRecentlyUsed() throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        // 2×2 bgra = 16 bytes per texture; the budget holds exactly one.
        let renderer = KittyImageRenderer(device: device, textureByteBudget: 16)
        let first = try #require(Self.rgbaImage(id: 1, width: 2, height: 2))
        let second = try #require(Self.rgbaImage(id: 2, width: 2, height: 2))
        let id1 = KittyGraphics.ImageID(rawValue: 1)
        let id2 = KittyGraphics.ImageID(rawValue: 2)

        #expect(renderer.texture(for: id1, data: first) != nil)
        #expect(renderer.cachedTextureBytes == 16)
        #expect(renderer.texture(for: id2, data: second) != nil)
        #expect(renderer.textureCount == 1, "caching the second must evict the first")
        #expect(renderer.cachedTextureBytes == 16)

        // Re-asking for the evicted image re-decodes it and evicts the
        // other — the cache thrashes rather than crashing or growing.
        #expect(renderer.texture(for: id1, data: first) != nil)
        #expect(renderer.textureCount == 1)
        #expect(renderer.cachedTextureBytes == 16)
    }

    @Test("an image larger than the whole pane budget is never cached and fails permanently")
    func imageLargerThanThePaneBudgetIsNeverCached() throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let renderer = KittyImageRenderer(device: device, textureByteBudget: 16)
        let imageData = try #require(Self.rgbaImage(id: 1, width: 4, height: 4))  // 64 bytes decoded
        let id = KittyGraphics.ImageID(rawValue: 1)
        #expect(renderer.texture(for: id, data: imageData) == nil)
        #expect(renderer.texture(for: id, data: imageData) == nil, "a hopeless image is not retried every frame")
        #expect(renderer.textureCount == 0)
        #expect(renderer.cachedTextureBytes == 0)
    }

    @Test("the app-wide texture budget reserves and releases exactly")
    func globalTextureBudgetReservesAndReleases() {
        let budget = GlobalTextureBudget(limit: 100)
        #expect(budget.tryReserve(60))
        #expect(budget.tryReserve(50) == false, "60 + 50 would cross the limit")
        #expect(budget.tryReserve(40))
        #expect(budget.tryReserve(1) == false)
        budget.release(60)
        #expect(budget.tryReserve(60))
        budget.release(100)
        #expect(budget.tryReserve(100))
    }

    @Test("an image skipped on a full global budget retries once another pane frees space")
    func globalBudgetBlockedImageRetriesAfterExternalRelease() throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        // 2×2 bgra = 16 bytes per texture; the shared budget holds exactly
        // two panes' images.
        let global = GlobalTextureBudget(limit: 32)
        var rendererA: KittyImageRenderer? = KittyImageRenderer(
            device: device, textureByteBudget: 1024, globalBudget: global)
        let rendererB = KittyImageRenderer(device: device, textureByteBudget: 1024, globalBudget: global)
        let imageA = try #require(Self.rgbaImage(id: 1, width: 2, height: 2))
        let imageB1 = try #require(Self.rgbaImage(id: 3, width: 2, height: 2))
        let imageB2 = try #require(Self.rgbaImage(id: 4, width: 2, height: 2))
        let idB2 = KittyGraphics.ImageID(rawValue: 4)

        #expect(rendererA?.texture(for: KittyGraphics.ImageID(rawValue: 1), data: imageA) != nil)
        #expect(rendererB.texture(for: KittyGraphics.ImageID(rawValue: 3), data: imageB1) != nil)
        // The global budget is now full (32/32): B's second image is skipped.
        #expect(rendererB.texture(for: idB2, data: imageB2) == nil)
        #expect(
            rendererB.texture(for: idB2, data: imageB2) == nil,
            "nothing freed yet — the skip must not turn into a per-frame decode retry")

        // Pane A closes: its deinit returns its global reservation — a
        // release B cannot observe except through the budget's generation.
        rendererA = nil
        #expect(
            rendererB.texture(for: idB2, data: imageB2) != nil,
            "once another pane frees global space, the skipped image must be retried")
    }

    // MARK: - PNG crafting helpers

    /// CRC-32 (zlib polynomial), for rewriting the crafted PNG's IHDR CRC
    /// so ImageIO accepts the patched header.
    private static func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB8_8320 : 0)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// A real 1×1 PNG whose IHDR declares 100000×100000 — see the test
    /// above for why the codestream is deliberately left valid.
    private static func oversizedHeaderPNG() -> [UInt8] {
        // 1×1 8-bit RGB PNG, produced by ImageIO and captured verbatim.
        let base64 =
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        var bytes = [UInt8](Data(base64Encoded: base64)!)
        // IHDR: signature (8) + length (4) + "IHDR" (4), then width and
        // height as big-endian UInt32 at offsets 16 and 20; CRC over
        // "IHDR" + 13 data bytes lands at offset 29.
        bytes[16] = 0x00; bytes[17] = 0x01; bytes[18] = 0x86; bytes[19] = 0xA0  // 100000
        bytes[20] = 0x00; bytes[21] = 0x01; bytes[22] = 0x86; bytes[23] = 0xA0  // 100000
        let crc = crc32(bytes[12..<29])
        bytes[29] = UInt8(truncatingIfNeeded: crc >> 24)
        bytes[30] = UInt8(truncatingIfNeeded: crc >> 16)
        bytes[31] = UInt8(truncatingIfNeeded: crc >> 8)
        bytes[32] = UInt8(truncatingIfNeeded: crc)
        return bytes
    }
}
