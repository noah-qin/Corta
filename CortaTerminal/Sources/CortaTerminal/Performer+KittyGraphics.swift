import Foundation

/// M10 — the Kitty graphics protocol's APC dispatch. See `KittyGraphics.swift`
/// for the wire-format types and what subset of the real protocol this
/// implements, and `ImagePlacementTable.swift` for where the settled state
/// (as opposed to this file's in-progress transmission) lives.
extension Performer {
    public mutating func apcDispatch(_ bytes: ArraySlice<UInt8>) {
        guard let command = KittyGraphicsParser.parse(bytes) else { return }
        switch command {
        case .transmit(let header, let payloadBase64, let moreChunks, let display):
            receiveChunk(header: header, display: display, payloadBase64: payloadBase64, moreChunks: moreChunks)
        case .display(let display):
            placeAtCursor(display)
        case .delete(let target):
            grid.imagePlacements.delete(target)
        case .query(let header):
            respondToQuery(header)
        }
    }

    /// `a=q` — answered from the header alone, never touching
    /// `ImagePlacementTable`: the real protocol requires a query to check
    /// only whether the terminal *could* display something shaped like
    /// this, not to decode or store whatever payload rides along with it.
    /// This is the response `kitten icat` and every other real client
    /// sends before ever transmitting an actual image, and refuses outright
    /// without.
    private mutating func respondToQuery(_ header: KittyGraphics.TransmitHeader) {
        let format = header.format ?? .rgba
        let ok: Bool
        switch format {
        case .png:
            ok = true
        case .rgb, .rgba:
            ok = (header.width ?? 0) > 0 && (header.height ?? 0) > 0
        }
        respond(
            imageID: header.imageID, placementID: nil, quiet: header.quiet,
            error: ok ? nil : "EINVAL:bad dimensions")
    }

    /// The `<ESC>_G ... <ESC>\` acknowledgment every non-quiet command gets —
    /// `SECURITY.md` §2.1/§2.2's fixed-format rule applies here exactly as it
    /// does to DA1/DSR/OSC 10-12: `imageID`/`placementID` are numbers this
    /// implementation already validated, `error` is always one of this
    /// file's own constant strings, and nothing from the input stream is
    /// ever echoed back. `quiet` 0 (the default) responds to both success
    /// and error, 1 suppresses only the `OK`, 2 suppresses everything.
    private mutating func respond(
        imageID: KittyGraphics.ImageID, placementID: KittyGraphics.PlacementID?, quiet: Int,
        error: String?
    ) {
        guard quiet < 2, error != nil || quiet < 1 else { return }
        var body = "i=\(imageID.rawValue)"
        if let placementID { body += ",p=\(placementID.rawValue)" }
        body += ";" + (error ?? "OK")
        state.outputBuffer.append(contentsOf: Array("\u{1B}_G\(body)\u{1B}\\".utf8))
    }

    /// Appends one chunk to the transmission in progress, starting a new one
    /// if this is the first chunk (`state.pendingImageTransmission` is
    /// `nil`, or belongs to a different image id — a client starting a new
    /// transmission before finishing the last one abandons the old one,
    /// which is the same "the newest wins" rule OSC title-setting already
    /// follows). Finalises and decodes once `moreChunks` is false.
    ///
    /// `header.format`/`.width`/`.height` are resolved (defaulted where
    /// absent) only when *starting* a transmission — a continuation
    /// chunk's header carries just `i=`/`m=` (`KittyGraphicsParser`'s doc
    /// comment) and must not overwrite what the first chunk already
    /// established.
    private mutating func receiveChunk(
        header: KittyGraphics.TransmitHeader, display: KittyGraphics.DisplayHeader?,
        payloadBase64: ArraySlice<UInt8>, moreChunks: Bool
    ) {
        if state.pendingImageTransmission?.header.imageID != header.imageID {
            var resolved = header
            resolved.format = header.format ?? .rgba
            resolved.width = header.width ?? 0
            resolved.height = header.height ?? 0
            state.pendingImageTransmission = PendingImageTransmission(
                header: resolved, display: display, base64: [])
        }
        // Roughly the base64 expansion of `maximumImageBytes` — checked on
        // every chunk, not only at the end, so a hostile stream cannot
        // stall the accumulator at just-under-the-limit forever by sending
        // one enormous "still more chunks" transmission
        // (`SECURITY.md` §3).
        let budget = KittyGraphics.maximumImageBytes / 3 * 4 + 4
        guard state.pendingImageTransmission!.base64.count + payloadBase64.count <= budget else {
            state.pendingImageTransmission = nil
            return
        }
        state.pendingImageTransmission!.base64.append(contentsOf: payloadBase64)
        guard !moreChunks else { return }

        let pending = state.pendingImageTransmission!
        state.pendingImageTransmission = nil
        finishTransmission(pending)
    }

    private mutating func finishTransmission(_ pending: PendingImageTransmission) {
        let imageID = pending.header.imageID
        let quiet = pending.header.quiet
        guard let decoded = Data(base64Encoded: Data(Self.padded(pending.base64))) else {
            respond(imageID: imageID, placementID: nil, quiet: quiet, error: "EINVAL:bad base64")
            return
        }
        let bytes = [UInt8](decoded)
        guard bytes.count <= KittyGraphics.maximumImageBytes else {
            respond(imageID: imageID, placementID: nil, quiet: quiet, error: "EINVAL:too large")
            return
        }
        // Resolved to non-optional in `receiveChunk` when the transmission
        // started; defaulted again here purely as a second line of defence,
        // never actually relied on.
        let format = pending.header.format ?? .rgba
        let width = pending.header.width ?? 0
        let height = pending.header.height ?? 0
        // Raw formats are exactly `width * height * bytesPerPixel` — a
        // mismatch is a malformed or truncated transmission, not something
        // to clamp or pad into shape (`SECURITY.md` §3).
        switch format {
        case .rgb:
            guard bytes.count == width * height * 3 else {
                respond(imageID: imageID, placementID: nil, quiet: quiet, error: "EINVAL:bad size")
                return
            }
        case .rgba:
            guard bytes.count == width * height * 4 else {
                respond(imageID: imageID, placementID: nil, quiet: quiet, error: "EINVAL:bad size")
                return
            }
        case .png:
            break  // Decoded (and validated) by the app layer, which owns ImageIO.
        }
        let data = KittyGraphics.ImageData(format: format, width: width, height: height, bytes: bytes)
        guard grid.imagePlacements.store(imageID, data: data) else {
            respond(imageID: imageID, placementID: nil, quiet: quiet, error: "ENOSPC:too many images")
            return
        }
        // The combined `a=T` gets one response for the whole command, not a
        // second one from the placement it bundles — `respond: false` here,
        // with the bare `a=p` path below still getting its own.
        if let display = pending.display {
            placeAtCursor(display, respond: false)
        }
        respond(imageID: imageID, placementID: nil, quiet: quiet, error: nil)
    }

    /// Places an image at the cursor's current document position — what
    /// both `a=T` (transmit-and-display) and a bare `a=p` do. Advances the
    /// cursor past the image's footprint only when the placement gave an
    /// explicit cell size (`c=`/`r=`): without one, sizing is deferred to
    /// the app layer's cell metrics (see `KittyGraphics.Placement`'s doc
    /// comment), which this method has no access to, so the cursor is left
    /// where it is rather than guessed at.
    private mutating func placeAtCursor(_ display: KittyGraphics.DisplayHeader, respond respondFlag: Bool = true) {
        let placed = grid.imagePlacements.place(
            display, row: grid.cursor.row, column: grid.cursor.column,
            baseScrollbackTotal: grid.scrollback.totalPushed)
        if respondFlag {
            respond(
                imageID: display.imageID, placementID: display.placementID, quiet: display.quiet,
                error: placed ? nil : "ENOSPC:too many placements")
        }
        guard placed, let columns = display.columns, let rows = display.rows, rows > 0 else { return }
        if rows == 1 {
            grid.moveCursor(row: grid.cursor.row, column: grid.cursor.column + columns)
        } else {
            // A multi-row placement's cursor lands at the start of the row
            // below its last one, mirroring how the reference client's own
            // multi-line placements are documented to leave the cursor.
            grid.moveCursor(row: grid.cursor.row + rows, column: 0)
        }
    }

    /// `Data(base64Encoded:)` requires `=` padding out to a multiple of 4 and
    /// simply fails, silently, on anything short of that — but RFC 4648
    /// §3.2 makes padding optional for a decoder that already knows where
    /// the data ends (which a length-prefixed accumulator like this one
    /// does), and real `kitten icat` sends unpadded base64 in practice. A
    /// real-client verification pass (`KittyGraphics.swift`'s doc comment)
    /// found every such transmission was being dropped as "bad base64" —
    /// this app's own hand-written tests never caught it because
    /// `Data.base64EncodedString()` always emits correctly padded output.
    /// Already-padded input is unaffected: the remainder is 0, so nothing is
    /// appended.
    private static func padded(_ base64: [UInt8]) -> [UInt8] {
        let remainder = base64.count % 4
        guard remainder != 0 else { return base64 }
        return base64 + Array(repeating: UInt8(ascii: "="), count: 4 - remainder)
    }
}
