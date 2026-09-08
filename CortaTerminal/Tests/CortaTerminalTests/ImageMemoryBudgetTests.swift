import Foundation
import Testing

@testable import CortaTerminal

/// S02 — the per-pane image memory budgets `ImagePlacementTable` enforces
/// (`KittyGraphics.maximumPaneImageBytes`, `maximumImageDimension`,
/// `maximumImagePixels`). Driven at the table level rather than over the
/// wire: the protocol-sized budgets are hundreds of megabytes, so the
/// table's test-overridable `maximumStoredBytes` stands in for the real
/// cap. Wire-level store refusals (count cap → `ENOSPC`) are already
/// covered in `KittyGraphicsTests`.
@Suite("Image memory budgets (S02)")
struct ImageMemoryBudgetTests {
    private static func png(_ bytes: Int) -> KittyGraphics.ImageData {
        KittyGraphics.ImageData(
            format: .png, width: 0, height: 0, bytes: [UInt8](repeating: 0xAA, count: bytes))
    }

    @Test("a pane's stored image bytes are capped; the image that crosses the cap is refused")
    func paneByteBudgetRefusesTheImageThatCrossesIt() {
        var table = ImagePlacementTable()
        table.maximumStoredBytes = 1000
        let first = table.store(KittyGraphics.ImageID(rawValue: 1), data: Self.png(600))
        let crossing = table.store(KittyGraphics.ImageID(rawValue: 2), data: Self.png(500))
        let fits = table.store(KittyGraphics.ImageID(rawValue: 3), data: Self.png(400))
        #expect(first == nil)
        #expect(crossing == .byteBudgetExceeded)
        #expect(fits == nil)
        #expect(table.imageCount == 2)
    }

    @Test("re-transmitting an id at the cap succeeds, since the replacement nets out")
    func replacementAtTheCapNetsOut() {
        var table = ImagePlacementTable()
        table.maximumStoredBytes = 1000
        let initial = table.store(KittyGraphics.ImageID(rawValue: 1), data: Self.png(1000))
        let sameSize = table.store(KittyGraphics.ImageID(rawValue: 1), data: Self.png(1000))
        let larger = table.store(KittyGraphics.ImageID(rawValue: 1), data: Self.png(1001))
        #expect(initial == nil)
        #expect(sameSize == nil)
        #expect(larger == .byteBudgetExceeded)
        #expect(table.image(KittyGraphics.ImageID(rawValue: 1))?.bytes.count == 1000)
    }

    @Test("deleting an image frees its budget; deleting everything resets it")
    func deletionFreesTheBudget() {
        var table = ImagePlacementTable()
        table.maximumStoredBytes = 1000
        let first = table.store(KittyGraphics.ImageID(rawValue: 1), data: Self.png(600))
        let second = table.store(KittyGraphics.ImageID(rawValue: 2), data: Self.png(400))
        let overFull = table.store(KittyGraphics.ImageID(rawValue: 3), data: Self.png(1))
        #expect(first == nil)
        #expect(second == nil)
        #expect(overFull == .byteBudgetExceeded)

        table.delete(.image(KittyGraphics.ImageID(rawValue: 1)))
        let afterDelete = table.store(KittyGraphics.ImageID(rawValue: 3), data: Self.png(600))
        #expect(afterDelete == nil)

        table.delete(.all)
        let afterDeleteAll = table.store(KittyGraphics.ImageID(rawValue: 4), data: Self.png(1000))
        #expect(afterDeleteAll == nil)
    }

    @Test("a raw image past the decoded-pixel cap is refused at store time")
    func rawImagePastThePixelCapIsRefused() {
        var table = ImagePlacementTable()
        let overCap = KittyGraphics.ImageData(
            format: .rgba, width: 4097, height: 4096, bytes: [])  // 4097×4096 > maximumImagePixels
        let refused = table.store(KittyGraphics.ImageID(rawValue: 1), data: overCap)
        #expect(refused == .dimensionsExceedCaps)

        // Exactly at the cap (4096×4096 == maximumImagePixels) is accepted.
        let atCap = KittyGraphics.ImageData(format: .rgba, width: 4096, height: 4096, bytes: [])
        let accepted = table.store(KittyGraphics.ImageID(rawValue: 2), data: atCap)
        #expect(accepted == nil)
    }

    @Test("a raw image past the per-axis dimension cap is refused even when its pixels fit")
    func rawImagePastTheDimensionCapIsRefused() {
        var table = ImagePlacementTable()
        let tooWide = KittyGraphics.ImageData(
            format: .rgb, width: KittyGraphics.maximumImageDimension + 1, height: 1, bytes: [])
        let refused = table.store(KittyGraphics.ImageID(rawValue: 1), data: tooWide)
        #expect(refused == .dimensionsExceedCaps)
    }

    @Test("PNG dimension caps are not enforced in the core — the app layer owns ImageIO")
    func pngDimensionsAreNotCheckedInTheCore() {
        var table = ImagePlacementTable()
        // PNG dimensions live inside the payload (`KittyGraphics.swift`'s
        // doc comment), so the core cannot and must not guess them here;
        // `KittyImageRenderer` checks the header before decoding.
        let png = KittyGraphics.ImageData(format: .png, width: 0, height: 0, bytes: [0x89, 0x50])
        let stored = table.store(KittyGraphics.ImageID(rawValue: 1), data: png)
        #expect(stored == nil)
    }
}
