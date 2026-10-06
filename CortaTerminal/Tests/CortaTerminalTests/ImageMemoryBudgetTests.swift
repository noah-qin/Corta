// Copyright 2026 Noah Qin
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Synchronization
import Testing

@testable import CortaTerminal

/// The per-pane image memory budgets `ImagePlacementTable` enforces
/// (`KittyGraphics.maximumPaneImageBytes`, `maximumImageDimension`,
/// `maximumImagePixels`). Driven at the table level rather than over the
/// wire: the protocol-sized budgets are hundreds of megabytes, so the
/// table's test-overridable `maximumStoredBytes` stands in for the real
/// cap. Wire-level store refusals (count cap → `ENOSPC`) are already
/// covered in `KittyGraphicsTests`.
@Suite("Image memory budgets")
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

    // MARK: - Across screens, unfinished transmissions and panes

    /// A PNG transmission of `bytes` decoded bytes: the core stores PNG bytes
    /// undecoded, so the size on the wire is the size charged.
    private static func pngTransmission(id: Int, bytes: Int, more: Bool = false) -> [UInt8] {
        let payload = Data(repeating: 0xAA, count: bytes).base64EncodedString()
        return Array("\u{1B}_Ga=t,f=100,i=\(id),q=2\(more ? ",m=1" : "");\(payload)\u{1B}\\".utf8)
    }

    @Test("the alternate screen gets only what the parked main screen's images left")
    func alternateScreenSharesThePaneBudget() {
        var grid = Grid(rows: 4, columns: 10)
        grid.imagePlacements.maximumStoredBytes = 1000
        #expect(grid.imagePlacements.store(KittyGraphics.ImageID(rawValue: 1), data: Self.png(600)) == nil)
        grid.enterAlternateScreen()
        #expect(
            grid.imagePlacements.store(KittyGraphics.ImageID(rawValue: 2), data: Self.png(500))
                == .byteBudgetExceeded,
            "a table of its own would have taken another full budget")
        #expect(grid.imagePlacements.store(KittyGraphics.ImageID(rawValue: 3), data: Self.png(400)) == nil)
        #expect(grid.retainedImageBytes == 1000)
        grid.exitAlternateScreen()
        #expect(grid.retainedImageBytes == 600, "leaving the alternate screen frees its images")
        #expect(grid.imagePlacements.store(KittyGraphics.ImageID(rawValue: 4), data: Self.png(400)) == nil)
    }

    @Test("an unfinished transmission is charged as the image it would become")
    func unfinishedTransmissionCountsAgainstThePane() {
        var terminal = Terminal(rows: 4, columns: 10)
        terminal.grid.imagePlacements.maximumStoredBytes = 1000
        terminal.feed(Self.pngTransmission(id: 1, bytes: 600))
        #expect(terminal.grid.imagePlacements.imageCount == 1)

        // 300 bytes pending fit in the 400 left, and are counted while held.
        terminal.feed(Self.pngTransmission(id: 2, bytes: 300, more: true))
        #expect(terminal.retainedImageBytes == 900)
        // Another 300 would make 600 > 400: the transmission is abandoned.
        terminal.feed(Array("\u{1B}_Gm=1;\(Data(repeating: 0xAA, count: 300).base64EncodedString())\u{1B}\\".utf8))
        #expect(terminal.retainedImageBytes == 600, "the overflowing transmission is dropped, not held")
    }

    @Test("an allowance from a shared budget caps a terminal below its pane budget")
    func allowanceCapsTheTerminal() {
        var terminal = Terminal(rows: 4, columns: 10)
        terminal.imageByteAllowance = 500
        // Nor may it hold more than that pending.
        terminal.feed(Self.pngTransmission(id: 9, bytes: 600, more: true))
        #expect(terminal.retainedImageBytes == 0)
        terminal.feed(Self.pngTransmission(id: 1, bytes: 600))
        #expect(terminal.grid.imagePlacements.imageCount == 0)
        terminal.feed(Self.pngTransmission(id: 2, bytes: 400))
        #expect(terminal.grid.imagePlacements.imageCount == 1)
        #expect(terminal.retainedImageBytes == 400)
    }

    @Test("a terminal reset keeps the session's share of the shared budget")
    func resetKeepsTheAllowance() {
        var terminal = Terminal(rows: 4, columns: 10)
        terminal.imageByteAllowance = 500
        terminal.feed(Array("\u{1B}c".utf8) + Self.pngTransmission(id: 1, bytes: 600))
        #expect(terminal.imageByteAllowance == 500)
        #expect(terminal.grid.imagePlacements.imageCount == 0)
    }

    @Test("a full quota answers ENOSPC; only an image too large for any quota is EINVAL")
    func fullQuotaIsNoSpace() {
        var terminal = Terminal(rows: 4, columns: 10)
        terminal.imageByteAllowance = 500
        let payload = Data(repeating: 0xAA, count: 600).base64EncodedString()
        terminal.feed(Array("\u{1B}_Ga=t,f=100,i=1,m=1;\(payload)\u{1B}\\".utf8))
        #expect(String(decoding: terminal.takeOutput(), as: UTF8.self).contains("ENOSPC"))
    }

    @Test("a shared budget gives each owner what the others leave, and forgets a released one")
    func sharedBudgetAllowances() {
        let budget = ImageMemoryBudget(limit: 1000)
        // Held, or the second object can reuse the first one's address.
        let owners = (NSObject(), NSObject())
        let a = ObjectIdentifier(owners.0)
        let b = ObjectIdentifier(owners.1)
        budget.report(700, for: a)
        #expect(budget.allowance(for: a) == 1000)
        #expect(budget.allowance(for: b) == 300)
        budget.report(300, for: b)
        #expect(budget.totalBytes == 1000)
        budget.release(a)
        #expect(budget.allowance(for: b) == 1000)
        #expect(budget.totalBytes == 300)
        withExtendedLifetime(owners) {}
    }

    @Test("a session charges the shared budget for its images and releases it when stopped")
    func sessionChargesAndReleasesTheSharedBudget() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-image-budget-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: path) }
        try Data(Self.pngTransmission(id: 1, bytes: 600)).write(to: path)

        let budget = ImageMemoryBudget(limit: 10_000)
        let session = try TerminalSession(executable: "/bin/cat", arguments: [path.path], imageBudget: budget)
        session.start()
        let deadline = Date().addingTimeInterval(testTimeoutInterval(10))
        while budget.totalBytes == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(budget.totalBytes == 600)
        session.stop()
        #expect(budget.totalBytes == 0, "a closed pane's images no longer count against the others")
    }

    @Test("a session refuses images past what the other sessions left it")
    func sessionRefusesPastTheSharedBudget() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-image-budget-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: path) }
        try Data(Self.pngTransmission(id: 1, bytes: 600)).write(to: path)

        let budget = ImageMemoryBudget(limit: 1000)
        let otherOwner = NSObject()
        let other = ObjectIdentifier(otherOwner)
        budget.report(500, for: other)
        let session = try TerminalSession(executable: "/bin/cat", arguments: [path.path], imageBudget: budget)
        defer { session.stop() }
        // The exit callback runs after the reader drained the pipe.
        let exited = Mutex(false)
        session.onChildExit = { _ in exited.withLock { $0 = true } }
        session.start()
        let deadline = Date().addingTimeInterval(testTimeoutInterval(10))
        while !exited.withLock({ $0 }), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(exited.withLock { $0 })
        #expect(session.snapshot().imagePlacements.imageCount == 0)
        #expect(budget.totalBytes == 500)
        withExtendedLifetime(otherOwner) {}
    }
}
