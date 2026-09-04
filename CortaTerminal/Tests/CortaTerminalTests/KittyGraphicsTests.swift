import Foundation
import Testing

@testable import CortaTerminal

/// M10 — the Kitty graphics protocol subset `KittyGraphics.swift` documents:
/// direct (base64, in-band) transmission, placement and deletion. Driven
/// directly against `Terminal.feed`, the same way `HyperlinkTests` and
/// `OSCTests` exercise their protocols — real APC byte sequences in, the
/// core's resulting state out.
@Suite("Kitty graphics")
struct KittyGraphicsTests {
    /// One APC sequence: `ESC _ G <control>;<payload> ESC \`.
    private static func apc(_ control: String, payload: String = "") -> [UInt8] {
        Array("\u{1B}_G\(control);\(payload)\u{1B}\\".utf8)
    }

    private static func rgba(_ pixels: Int) -> Data {
        Data(repeating: 0xFF, count: pixels * 4)
    }

    @Test("a single-chunk RGBA transmit-and-display places an image at the cursor")
    func transmitAndDisplayPlacesAtCursor() {
        var terminal = Terminal(rows: 10, columns: 40)
        terminal.feed(Array("\u{1B}[3;4H".utf8))  // CUP, 1-indexed: row 2, column 3 (0-indexed)
        let payload = Self.rgba(4).base64EncodedString()  // 2x2 RGBA
        terminal.feed(Self.apc("a=T,i=1,f=32,s=2,v=2", payload: payload))

        let placements = terminal.grid.imagePlacements.orderedPlacements()
        #expect(placements.count == 1)
        #expect(placements.first?.row == 2)
        #expect(placements.first?.column == 3)
        #expect(placements.first?.imageID == KittyGraphics.ImageID(rawValue: 1))
        #expect(terminal.grid.imagePlacements.imageCount == 1)
    }

    @Test("a malformed RGBA payload (wrong byte count for its declared size) is dropped, not clamped")
    func mismatchedByteCountIsDropped() {
        var terminal = Terminal(rows: 10, columns: 40)
        // Declares 4x4 (64 bytes) but sends only a 1x1 (4-byte) payload.
        let payload = Self.rgba(1).base64EncodedString()
        terminal.feed(Self.apc("a=T,i=1,f=32,s=4,v=4", payload: payload))
        #expect(terminal.grid.imagePlacements.imageCount == 0)
        #expect(terminal.grid.imagePlacements.orderedPlacements().isEmpty)
    }

    @Test("a chunked transmission is only decoded once the final chunk arrives")
    func chunkedTransmissionWaitsForTheFinalChunk() {
        var terminal = Terminal(rows: 10, columns: 40)
        let whole = Self.rgba(4).base64EncodedString()  // 2x2 RGBA, 12 base64 chars
        let midpoint = whole.index(whole.startIndex, offsetBy: whole.count / 2)
        let firstHalf = String(whole[whole.startIndex..<midpoint])
        let secondHalf = String(whole[midpoint...])

        terminal.feed(Self.apc("a=T,i=7,f=32,s=2,v=2,m=1", payload: firstHalf))
        #expect(terminal.grid.imagePlacements.imageCount == 0, "must not decode before the last chunk")

        terminal.feed(Self.apc("i=7,m=0", payload: secondHalf))
        #expect(terminal.grid.imagePlacements.imageCount == 1)
        #expect(terminal.grid.imagePlacements.orderedPlacements().count == 1)
    }

    @Test("transmit without display (a=t) stores the image but places nothing")
    func transmitOnlyStoresWithoutPlacing() {
        var terminal = Terminal(rows: 10, columns: 40)
        let payload = Self.rgba(1).base64EncodedString()
        terminal.feed(Self.apc("a=t,i=9,f=32,s=1,v=1", payload: payload))
        #expect(terminal.grid.imagePlacements.imageCount == 1)
        #expect(terminal.grid.imagePlacements.orderedPlacements().isEmpty)
    }

    @Test("a=p places an already-transmitted image without re-sending its bytes")
    func bareDisplayPlacesAPreviouslyTransmittedImage() {
        var terminal = Terminal(rows: 10, columns: 40)
        let payload = Self.rgba(1).base64EncodedString()
        terminal.feed(Self.apc("a=t,i=3,f=32,s=1,v=1", payload: payload))
        terminal.feed(Array("\u{1B}[6;6H".utf8))  // CUP, 1-indexed: row 5, column 5 (0-indexed)
        terminal.feed(Self.apc("a=p,i=3"))

        let placements = terminal.grid.imagePlacements.orderedPlacements()
        #expect(placements.count == 1)
        #expect(placements.first?.row == 5)
        #expect(placements.first?.column == 5)
    }

    /// Real `kitten icat` sends exactly this shape for a plain (non-`--place`,
    /// non-reused) display — `a=T,q=2,f=100,s=64,v=64;<payload>`, no `i=` at
    /// all — captured from an actual `--transfer-mode=stream` run against a
    /// Release build during M10's real-client verification pass. Requiring a
    /// positive id silently dropped the whole command; this is the
    /// regression test for that.
    @Test("a transmit-and-display with no i= at all (a real client's common shape) still places")
    func transmitAndDisplayWithNoImageIDStillPlaces() {
        var terminal = Terminal(rows: 10, columns: 40)
        let payload = Self.rgba(1).base64EncodedString()
        terminal.feed(Self.apc("a=T,q=2,f=32,s=1,v=1", payload: payload))
        let placements = terminal.grid.imagePlacements.orderedPlacements()
        #expect(placements.count == 1)
        #expect(placements.first?.imageID == KittyGraphics.ImageID(rawValue: 0))
        #expect(terminal.grid.imagePlacements.imageCount == 1)
    }

    @Test("a=p for an image that was never transmitted places nothing")
    func bareDisplayOfAnUnknownImageDoesNothing() {
        var terminal = Terminal(rows: 10, columns: 40)
        terminal.feed(Self.apc("a=p,i=42"))
        #expect(terminal.grid.imagePlacements.orderedPlacements().isEmpty)
    }

    @Test("deleting by image id removes every placement of that image and the image itself")
    func deleteByImageRemovesItsPlacements() {
        var terminal = Terminal(rows: 10, columns: 40)
        let payload = Self.rgba(1).base64EncodedString()
        terminal.feed(Self.apc("a=t,i=5,f=32,s=1,v=1", payload: payload))
        terminal.feed(Self.apc("a=p,i=5,p=1"))
        terminal.feed(Self.apc("a=p,i=5,p=2"))
        #expect(terminal.grid.imagePlacements.orderedPlacements().count == 2)

        terminal.feed(Self.apc("a=d,d=i,i=5"))
        #expect(terminal.grid.imagePlacements.orderedPlacements().isEmpty)
        #expect(terminal.grid.imagePlacements.imageCount == 0)
    }

    @Test("deleting a specific placement leaves the image and its other placements")
    func deleteByPlacementLeavesTheImageAndOtherPlacements() {
        var terminal = Terminal(rows: 10, columns: 40)
        let payload = Self.rgba(1).base64EncodedString()
        terminal.feed(Self.apc("a=t,i=6,f=32,s=1,v=1", payload: payload))
        terminal.feed(Self.apc("a=p,i=6,p=1"))
        terminal.feed(Self.apc("a=p,i=6,p=2"))
        #expect(terminal.grid.imagePlacements.orderedPlacements().count == 2)

        terminal.feed(Self.apc("a=d,d=i,i=6,p=1"))
        let remaining = terminal.grid.imagePlacements.orderedPlacements()
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == KittyGraphics.PlacementID(rawValue: 2))
        #expect(terminal.grid.imagePlacements.imageCount == 1)
    }

    @Test("a=d,d=a deletes everything")
    func deleteAllClearsEverything() {
        var terminal = Terminal(rows: 10, columns: 40)
        let payload = Self.rgba(1).base64EncodedString()
        terminal.feed(Self.apc("a=T,i=1,f=32,s=1,v=1", payload: payload))
        terminal.feed(Self.apc("a=T,i=2,f=32,s=1,v=1", payload: payload))
        #expect(terminal.grid.imagePlacements.imageCount == 2)

        terminal.feed(Self.apc("a=d"))  // `d=` absent defaults to "a".
        #expect(terminal.grid.imagePlacements.imageCount == 0)
        #expect(terminal.grid.imagePlacements.orderedPlacements().isEmpty)
    }

    @Test("an unrecognised delete target (by-position) deletes nothing")
    func unrecognisedDeleteTargetDeletesNothing() {
        var terminal = Terminal(rows: 10, columns: 40)
        let payload = Self.rgba(1).base64EncodedString()
        terminal.feed(Self.apc("a=T,i=1,f=32,s=1,v=1", payload: payload))
        terminal.feed(Self.apc("a=d,d=p,x=1,y=1"))  // by-position: not implemented.
        #expect(terminal.grid.imagePlacements.orderedPlacements().count == 1)
    }

    @Test("a column resize (reflow) drops every placement but not the transmitted image")
    func columnResizeDropsPlacementsNotImages() {
        var terminal = Terminal(rows: 10, columns: 40)
        let payload = Self.rgba(1).base64EncodedString()
        terminal.feed(Self.apc("a=T,i=1,f=32,s=1,v=1", payload: payload))
        #expect(terminal.grid.imagePlacements.orderedPlacements().count == 1)

        terminal.grid.resize(rows: 10, columns: 30)
        #expect(terminal.grid.imagePlacements.orderedPlacements().isEmpty, "a column change must drop placements")
        #expect(terminal.grid.imagePlacements.imageCount == 1, "the transmitted image itself must survive")

        // A bare re-placement (no re-transmission) works after the resize.
        terminal.feed(Self.apc("a=p,i=1"))
        #expect(terminal.grid.imagePlacements.orderedPlacements().count == 1)
    }

    @Test("a row-only resize keeps placements")
    func rowOnlyResizeKeepsPlacements() {
        var terminal = Terminal(rows: 10, columns: 40)
        let payload = Self.rgba(1).base64EncodedString()
        terminal.feed(Self.apc("a=T,i=1,f=32,s=1,v=1", payload: payload))
        terminal.grid.resize(rows: 20, columns: 40)
        #expect(terminal.grid.imagePlacements.orderedPlacements().count == 1)
    }

    @Test("entering the alternate screen clears placements; exiting restores the main screen's")
    func alternateScreenParksAndRestoresPlacements() {
        var terminal = Terminal(rows: 10, columns: 40)
        let payload = Self.rgba(1).base64EncodedString()
        terminal.feed(Self.apc("a=T,i=1,f=32,s=1,v=1", payload: payload))
        #expect(terminal.grid.imagePlacements.orderedPlacements().count == 1)

        terminal.feed(Array("\u{1B}[?1049h".utf8))
        #expect(terminal.grid.imagePlacements.orderedPlacements().isEmpty)

        terminal.feed(Array("\u{1B}[?1049l".utf8))
        #expect(terminal.grid.imagePlacements.orderedPlacements().count == 1)
    }

    @Test("a declared size with no matching payload is rejected rather than allocated for")
    func declaredSizeWithoutAMatchingPayloadIsRejected() {
        var terminal = Terminal(rows: 10, columns: 40)
        // `s=`/`v=` are clamped to 8192 by the parser regardless of what a
        // stream asks for, and the *declared* width/height then has to
        // match the *actual* decoded byte count exactly — a huge claimed
        // size backed by a handful of real bytes is refused at that check,
        // never used to size an allocation before the bytes are trusted
        // (`SECURITY.md` §3).
        let hugeSide = 8200
        terminal.feed(Self.apc("a=T,i=1,f=32,s=\(hugeSide),v=\(hugeSide)", payload: "AAAA"))
        #expect(terminal.grid.imagePlacements.imageCount == 0)
    }

    /// The exact bytes a real `kitten icat --transfer-mode=stream` sent
    /// against a Release build (M10's real-client verification pass) —
    /// captured with `script(1)` off the pty, not synthesised. Two things
    /// about this specific capture matter and are exactly why it is kept
    /// verbatim rather than reduced to a minimal case: no `i=` (covered
    /// separately above) and, more consequentially, **unpadded base64** —
    /// 211 base64 characters, one short of a multiple of 4. `Foundation`'s
    /// `Data(base64Encoded:)` rejects that outright, and every one of this
    /// suite's *other* payloads is built with `Data.base64EncodedString()`,
    /// which always pads — so this is the one case in the file that would
    /// have shipped broken without a real client's own bytes to test
    /// against (`Performer+KittyGraphics.swift`'s `padded(_:)`).
    @Test("a real, unpadded-base64 capture from kitten icat decodes and places")
    func realCapturedUnpaddedTransmissionDecodesAndPlaces() {
        var terminal = Terminal(rows: 10, columns: 120)
        let control = "a=T,q=2,f=100,s=64,v=64"
        let payload =
            "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAZUlEQVR42u3SMQ0AMAwDQSMxf1AF06goGukGSz96uJy2b0sjq99PZPX7WRBCCCGEEEIIIYQQQgghhBBCCCGEEEIIIYQQQgghhBBCCCGEEEIIIYQQQgghhBBCCCGEEEIIIYQQ+j8u7zaBAC9w5vsAAAAASUVORK5CYII"
        #expect(payload.count % 4 != 0, "this capture is the unpadded case on purpose")

        terminal.feed(Self.apc(control, payload: payload))

        let placements = terminal.grid.imagePlacements.orderedPlacements()
        #expect(placements.count == 1)
        #expect(placements.first?.imageID == KittyGraphics.ImageID(rawValue: 0))
        #expect(terminal.grid.imagePlacements.imageCount == 1)
        let image = terminal.grid.imagePlacements.image(KittyGraphics.ImageID(rawValue: 0))
        #expect(image?.format == .png)
        #expect(image?.bytes.count == 158, "the correctly-decoded PNG's real byte count")
        #expect(image?.bytes.prefix(8).elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) == true)
    }

    // MARK: - Responses (`a=q` and the OK/error acknowledgment)

    /// A real client verification pass against `kitten icat` found this
    /// implementation never answered anything: `icat` sends `a=q` before
    /// ever transmitting a real image and refuses outright when nothing
    /// answers it (`KittyGraphics.swift`'s doc comment).
    @Test("a=q answers OK for a plausible header without storing or displaying anything")
    func queryAnswersOKWithoutStoringAnything() {
        var terminal = Terminal(rows: 10, columns: 40)
        terminal.feed(Self.apc("a=q,i=1,f=32,s=2,v=2"))
        #expect(terminal.takeOutput() == Array("\u{1B}_Gi=1;OK\u{1B}\\".utf8))
        #expect(terminal.grid.imagePlacements.imageCount == 0)
        #expect(terminal.grid.imagePlacements.orderedPlacements().isEmpty)
    }

    @Test("a=q for a PNG header with no declared size still answers OK")
    func queryAnswersOKForPNGWithNoDeclaredSize() {
        var terminal = Terminal(rows: 10, columns: 40)
        terminal.feed(Self.apc("a=q,i=2,f=100"))
        #expect(terminal.takeOutput() == Array("\u{1B}_Gi=2;OK\u{1B}\\".utf8))
    }

    @Test("a=q for a zero-sized raw header answers an error")
    func queryAnswersAnErrorForAZeroSizedRawHeader() {
        var terminal = Terminal(rows: 10, columns: 40)
        terminal.feed(Self.apc("a=q,i=3,f=32"))  // f=32 (RGBA) with no s=/v=.
        #expect(terminal.takeOutput() == Array("\u{1B}_Gi=3;EINVAL:bad dimensions\u{1B}\\".utf8))
    }

    @Test("a successful transmit-and-display answers once, for the transmit, not twice")
    func successfulTransmitAndDisplayAnswersOnce() {
        var terminal = Terminal(rows: 10, columns: 40)
        let payload = Self.rgba(1).base64EncodedString()
        terminal.feed(Self.apc("a=T,i=11,f=32,s=1,v=1", payload: payload))
        #expect(terminal.takeOutput() == Array("\u{1B}_Gi=11;OK\u{1B}\\".utf8))
    }

    @Test("a malformed payload answers an error instead of silence")
    func malformedPayloadAnswersAnError() {
        var terminal = Terminal(rows: 10, columns: 40)
        // Declares 4x4 (64 bytes) but sends only a 1x1 (4-byte) payload —
        // the same shape `mismatchedByteCountIsDropped` above covers, now
        // asserting the response side of the same failure.
        let payload = Self.rgba(1).base64EncodedString()
        terminal.feed(Self.apc("a=T,i=12,f=32,s=4,v=4", payload: payload))
        #expect(terminal.takeOutput() == Array("\u{1B}_Gi=12;EINVAL:bad size\u{1B}\\".utf8))
    }

    /// A PR review caught this: the per-chunk budget guard in
    /// `receiveChunk` used to drop the pending transmission and return with
    /// no response at all, contradicting `respond`'s own doc comment that
    /// every non-quiet command is acknowledged — a real client would be
    /// left waiting on an OK/error that never comes.
    @Test("a chunked transmission that overflows the byte budget still answers, not silence")
    func oversizedChunkedTransmissionStillAnswers() {
        var terminal = Terminal(rows: 10, columns: 40)
        let budget = KittyGraphics.maximumImageBytes / 3 * 4 + 4
        // Each wire chunk is itself capped at Parser.maxAPCStringLength
        // (6144), so crossing the accumulator's ~85 MB budget takes many
        // legitimate-sized chunks, not one large one — chosen well under
        // that cap to leave room for the control-data prefix.
        let chunkPayload = String(repeating: "A", count: 6000)
        let continuationChunk = Self.apc("i=15,m=1", payload: chunkPayload)

        var stream = Self.apc("a=T,i=15,f=32,s=2,v=2,m=1", payload: chunkPayload)
        var accumulated = chunkPayload.utf8.count
        // Stop as soon as one more chunk would cross the budget, then send
        // exactly that one chunk — the stream ends there, so the response
        // it triggers is the only one in the output.
        while accumulated + chunkPayload.utf8.count <= budget {
            stream += continuationChunk
            accumulated += chunkPayload.utf8.count
        }
        stream += continuationChunk

        terminal.feed(stream)
        #expect(terminal.takeOutput() == Array("\u{1B}_Gi=15;EINVAL:too large\u{1B}\\".utf8))
        #expect(terminal.grid.imagePlacements.imageCount == 0)
    }

    @Test("a bare a=p answers with both the image and placement ids")
    func bareDisplayAnswersWithImageAndPlacementIDs() {
        var terminal = Terminal(rows: 10, columns: 40)
        let payload = Self.rgba(1).base64EncodedString()
        terminal.feed(Self.apc("a=t,i=13,f=32,s=1,v=1", payload: payload))
        #expect(terminal.takeOutput() == Array("\u{1B}_Gi=13;OK\u{1B}\\".utf8), "the bare transmit (a=t) responds too")

        terminal.feed(Self.apc("a=p,i=13,p=7"))
        #expect(terminal.takeOutput() == Array("\u{1B}_Gi=13,p=7;OK\u{1B}\\".utf8))
    }

    @Test("q=1 suppresses the OK response but not an error")
    func quiet1SuppressesOKButNotError() {
        var terminal = Terminal(rows: 10, columns: 40)
        let payload = Self.rgba(1).base64EncodedString()
        terminal.feed(Self.apc("a=T,i=14,f=32,s=1,v=1,q=1", payload: payload))
        #expect(terminal.takeOutput().isEmpty)

        let badPayload = Self.rgba(1).base64EncodedString()
        terminal.feed(Self.apc("a=T,i=15,f=32,s=4,v=4,q=1", payload: badPayload))
        #expect(!terminal.takeOutput().isEmpty, "an error still answers under q=1")
    }

    @Test("q=2 suppresses every response, success or error")
    func quiet2SuppressesEveryResponse() {
        var terminal = Terminal(rows: 10, columns: 40)
        let payload = Self.rgba(1).base64EncodedString()
        terminal.feed(Self.apc("a=T,i=16,f=32,s=1,v=1,q=2", payload: payload))
        #expect(terminal.takeOutput().isEmpty)

        let badPayload = Self.rgba(1).base64EncodedString()
        terminal.feed(Self.apc("a=T,i=17,f=32,s=4,v=4,q=2", payload: badPayload))
        #expect(terminal.takeOutput().isEmpty, "an error is suppressed too under q=2")
    }

    @Test("a chunked transmission answers once, after the final chunk, using the first chunk's q=")
    func chunkedTransmissionAnswersOnceAfterTheFinalChunk() {
        var terminal = Terminal(rows: 10, columns: 40)
        let whole = Self.rgba(4).base64EncodedString()
        let midpoint = whole.index(whole.startIndex, offsetBy: whole.count / 2)
        let firstHalf = String(whole[whole.startIndex..<midpoint])
        let secondHalf = String(whole[midpoint...])

        terminal.feed(Self.apc("a=T,i=18,f=32,s=2,v=2,m=1", payload: firstHalf))
        #expect(terminal.takeOutput().isEmpty, "no response before the transmission finishes")

        terminal.feed(Self.apc("i=18,m=0", payload: secondHalf))
        #expect(terminal.takeOutput() == Array("\u{1B}_Gi=18;OK\u{1B}\\".utf8))
    }

    @Test("running out of tracked placements answers ENOSPC")
    func runningOutOfPlacementsAnswersENOSPC() {
        var terminal = Terminal(rows: 10, columns: 40)
        let payload = Self.rgba(1).base64EncodedString()
        terminal.feed(Self.apc("a=t,i=19,f=32,s=1,v=1,q=2", payload: payload))

        for placementID in 1...KittyGraphics.maximumTrackedPlacements {
            terminal.feed(Self.apc("a=p,i=19,p=\(placementID),q=2"))
        }
        #expect(terminal.grid.imagePlacements.orderedPlacements().count == KittyGraphics.maximumTrackedPlacements)

        terminal.feed(
            Self.apc("a=p,i=19,p=\(KittyGraphics.maximumTrackedPlacements + 1)")
        )
        let response = String(decoding: terminal.takeOutput(), as: UTF8.self)
        #expect(response.contains("ENOSPC"))
    }
}
