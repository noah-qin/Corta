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

/// Kitty graphics dispatch; settled state lives in `ImagePlacementTable`.
extension Performer {
    public mutating func apcDispatch(_ bytes: ArraySlice<UInt8>) {
        state.itermImage = nil
        guard let command = KittyGraphicsParser.parse(bytes) else { return }
        if let imageAllowanceProvider { state.imageByteAllowance = imageAllowanceProvider() }
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

    /// `a=q`: from the header alone, nothing decoded or stored.
    private mutating func respondToQuery(_ header: KittyGraphics.TransmitHeader) {
        let format = header.format ?? .rgba
        let ok: Bool
        switch format {
        case .png, .gif:
            ok = true
        case .rgb, .rgba:
            ok = (header.width ?? 0) > 0 && (header.height ?? 0) > 0
        }
        respond(
            imageID: header.imageID, placementID: nil, quiet: header.quiet,
            error: ok ? nil : "EINVAL:bad dimensions")
    }

    /// Fixed-format (`SECURITY.md` §2.1/§2.2): validated numbers and this file's
    /// own error strings. `quiet` 1 suppresses `OK`, 2 everything.
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

    /// A new image id abandons an unfinished transmission — newest wins. Format
    /// and size are resolved only when starting: a continuation's header
    /// carries just `m=` — the protocol's form, which `timg`, `chafa` and
    /// image previewers send after an `i=` on the first chunk — or repeats
    /// the first chunk's `i=`.
    private mutating func receiveChunk(
        header: KittyGraphics.TransmitHeader, display: KittyGraphics.DisplayHeader?,
        payloadBase64: ArraySlice<UInt8>, moreChunks: Bool
    ) {
        let continues = state.pendingImageTransmission.map {
            !header.namesImage || $0.header.imageID == header.imageID
        } ?? false
        if !continues {
            var resolved = header
            resolved.format = header.format ?? .rgba
            resolved.width = header.width ?? 0
            resolved.height = header.height ?? 0
            state.pendingImageTransmission = PendingImageTransmission(
                header: resolved, display: display, base64: [])
        }
        // Checked per chunk, so a stream cannot park just under the limit. The
        // text is charged to the pane as the image it will become: held until
        // another transmission replaces it, it was ~89 MB outside every budget.
        applyImageAllowance()
        let room = min(
            KittyGraphics.maximumImageBytes,
            grid.imagePlacements.availableBytes(for: state.pendingImageTransmission!.header.imageID))
        let budget = room / 3 * 4 + 4
        let held = state.pendingImageTransmission!.base64.count + payloadBase64.count
        guard held <= budget else {
            // Still acknowledged, with the pending header's `quiet` — a continuation
            // carries no `q=`, and re-parsing it would un-quiet the transmission.
            // Too large for any image is the client's error; too large for the
            // room left is a full quota, which a client may free and retry.
            let pending = state.pendingImageTransmission!
            state.pendingImageTransmission = nil
            let anyImage = KittyGraphics.maximumImageBytes / 3 * 4 + 4
            respond(
                imageID: pending.header.imageID, placementID: nil, quiet: pending.header.quiet,
                error: held > anyImage ? "EINVAL:too large" : "ENOSPC:image data too large")
            return
        }
        state.pendingImageTransmission!.base64.append(contentsOf: payloadBase64)
        guard !moreChunks else { return }

        let pending = state.pendingImageTransmission!
        state.pendingImageTransmission = nil
        finishTransmission(pending)
    }

    /// Decodes inline, or — for a large transmission when the session asks
    /// (`defersLargeImageDecoding`) — parks it for a decode outside the
    /// session's lock: base64 and zlib over up to 64 MiB held every frame's
    /// snapshot for ~100 ms at 4K. The parse stops right after this
    /// dispatch, so nothing later in the stream is applied before
    /// `completeDeferredImage` stores and places it.
    mutating func finishTransmission(_ pending: PendingImageTransmission) {
        let deferred = DeferredImageTransmission(pending: pending, resetCount: resetCount)
        if defersLargeImageDecoding, pending.base64.count >= KittyGraphics.deferredDecodeThreshold {
            state.deferredImage = deferred
            return
        }
        let decoded = deferred.decode()
        completeTransmission(decoded.pending, decoded: decoded.result)
    }

    /// Stores and places a transmission decoded outside the parse. One from
    /// before a RIS is answered, as an inline decode answered before the
    /// RIS cleared it, but not stored: its screen is gone.
    mutating func completeDeferredImage(_ decoded: DecodedImageTransmission) {
        state.decodingImageBytes = 0
        guard decoded.resetCount == resetCount else {
            let header = decoded.pending.header
            respond(
                imageID: header.imageID, placementID: nil, quiet: header.quiet,
                error: decoded.result.failure?.message)
            return
        }
        if let imageAllowanceProvider { state.imageByteAllowance = imageAllowanceProvider() }
        completeTransmission(decoded.pending, decoded: decoded.result)
    }

    private mutating func completeTransmission(
        _ pending: PendingImageTransmission,
        decoded: Result<KittyGraphics.ImageData, TransmissionRefusal>
    ) {
        if let options = pending.itermOptions {
            if case .success(let data) = decoded { placeITermImage(data, options: options) }
            return
        }
        let imageID = pending.header.imageID
        let quiet = pending.header.quiet
        let storedID: KittyGraphics.ImageID
        do throws(TransmissionRefusal) {
            let data = try decoded.get()
            storedID = try store(data, as: imageID)
        } catch {
            respond(imageID: imageID, placementID: nil, quiet: quiet, error: error.message)
            return
        }
        // One response for `a=T`, not a second from its placement.
        if var display = pending.display {
            if display.imageID.rawValue == 0 {
                display.imageID = storedID
                if display.placementID.rawValue == 0 {
                    display.placementID = KittyGraphics.PlacementID(rawValue: storedID.rawValue)
                }
            }
            placeAtCursor(display, respond: false)
        }
        respond(imageID: imageID, placementID: nil, quiet: quiet, error: nil)
    }

    /// Why a transmission was not stored, in the protocol's `CODE:text` form.
    struct TransmissionRefusal: Error {
        let message: String
    }

    /// The transmitted pixels, decoded, inflated and checked against their
    /// declared size: exactly `width * height * bytesPerPixel`, or refused —
    /// never padded. A PNG is decoded (and validated) by the app layer,
    /// which owns ImageIO.
    static func transmittedImage(
        _ pending: PendingImageTransmission
    ) throws(TransmissionRefusal) -> KittyGraphics.ImageData {
        let base64 = pending.itermOptions == nil ? padded(pending.base64) : pending.base64
        guard let decoded = Data(base64Encoded: Data(base64)) else {
            throw TransmissionRefusal(message: "EINVAL:bad base64")
        }
        var bytes = [UInt8](decoded)
        guard bytes.count <= KittyGraphics.maximumImageBytes else {
            throw TransmissionRefusal(message: "EINVAL:too large")
        }
        let format = pending.header.format ?? .rgba
        let width = pending.header.width ?? 0
        let height = pending.header.height ?? 0
        let bytesPerPixel: Int? =
            switch format {
            case .rgb: 3
            case .rgba: 4
            case .png, .gif: nil
            }
        if pending.header.compressed {
            // Pixels inflate to exactly their declared size, so that is the
            // ceiling; a PNG's size is unknown until decoded, so it gets the
            // per-image cap. Either way the expansion stops at the ceiling.
            let limit = bytesPerPixel.map { width * height * $0 } ?? KittyGraphics.maximumImageBytes
            guard limit > 0, limit <= KittyGraphics.maximumImageBytes,
                let inflated = KittyGraphics.inflateZlib(bytes, limit: limit)
            else { throw TransmissionRefusal(message: "EINVAL:bad compressed data") }
            bytes = inflated
        }
        if let bytesPerPixel, bytes.count != width * height * bytesPerPixel {
            throw TransmissionRefusal(message: "EINVAL:bad size")
        }
        var data = KittyGraphics.ImageData(format: format, width: width, height: height, bytes: bytes)
        data.receivedAt = ProcessInfo.processInfo.systemUptime
        return data
    }

    /// Stores `data` under `imageID`, or under a fresh id when it is 0.
    mutating func store(
        _ data: KittyGraphics.ImageData, as imageID: KittyGraphics.ImageID
    ) throws(TransmissionRefusal) -> KittyGraphics.ImageID {
        let storedID: KittyGraphics.ImageID
        let refusal: ImagePlacementTable.StoreRefusal?
        if imageID.rawValue == 0 {
            (storedID, refusal) = grid.imagePlacements.storeAnonymous(data)
        } else {
            (storedID, refusal) = (imageID, grid.imagePlacements.store(imageID, data: data))
        }
        switch refusal {
        case nil: return storedID
        case .dimensionsExceedCaps?: throw TransmissionRefusal(message: "EINVAL:image dimensions too large")
        case .tooManyImages?: throw TransmissionRefusal(message: "ENOSPC:too many images")
        case .byteBudgetExceeded?: throw TransmissionRefusal(message: "ENOSPC:image data too large")
        }
    }

    /// What the process-wide budget leaves this terminal, less what the
    /// parked screen holds, is all the live table may hold.
    mutating func applyImageAllowance() {
        let allowance = state.imageByteAllowance
        guard allowance != .max else {
            grid.imagePlacements.externalLimit = .max
            return
        }
        let parked = grid.retainedImageBytes - grid.imagePlacements.storedBytes
        grid.imagePlacements.externalLimit = max(0, allowance - parked)
    }

    mutating func placeAtCursor(_ display: KittyGraphics.DisplayHeader, respond respondFlag: Bool = true) {
        let placed = grid.imagePlacements.place(
            display, row: grid.cursor.row, column: grid.cursor.column,
            baseScrollbackTotal: grid.scrollback.totalPushed)
        if respondFlag {
            respond(
                imageID: display.imageID, placementID: display.placementID, quiet: display.quiet,
                error: placed ? nil : "ENOSPC:too many placements")
        }
        guard placed, display.movesCursor, let extent = cellExtent(of: display) else { return }
        moveCursorPast(columns: extent.columns, rows: extent.rows)
    }

    /// The cells a placement covers: `c=`/`r=`, else the image's pixel size
    /// over the pty's cell size, rounded up — what the renderer draws. Nil
    /// when either is unknown (no pixel size reported, or an undecodable
    /// PNG); the cursor is then not guessed at.
    private func cellExtent(of display: KittyGraphics.DisplayHeader) -> (columns: Int, rows: Int)? {
        let image = grid.imagePlacements.image(display.imageID)
        func cells(_ explicit: Int?, pixels: Int?, perCell: Int) -> Int? {
            if let explicit { return explicit }
            guard let pixels, perCell > 0 else { return nil }
            return max(1, (pixels + perCell - 1) / perCell)
        }
        guard
            let columns = cells(display.columns, pixels: image?.pixelWidth, perCell: grid.cellPixelWidth),
            let rows = cells(display.rows, pixels: image?.pixelHeight, perCell: grid.cellPixelHeight)
        else { return nil }
        return (columns, rows)
    }

    /// Kitty's rule (`graphics.c` `create_ref`, `screen.c`
    /// `screen_handle_graphics_command`): right by the columns, down to the
    /// image's last row; past the right edge, the start of the next row; past
    /// the bottom margin, the region scrolls — so the image goes up with the
    /// text, and the next line starts below it rather than on top of it.
    /// `kitten icat` ends with a newline that relies on exactly this. A cursor
    /// already below the region only clamps: scrolling a region it is not in
    /// would move text it never touched.
    ///
    /// The scroll is capped at a region plus a screen: `a=p,r=4096` is twenty
    /// bytes, and uncapped it pushed 4096 lines under the session lock — a
    /// few kilobytes of it froze the pane for seconds. A real image taller
    /// than that (icat fits images to the screen) leaves its excess below
    /// the cursor.
    private mutating func moveCursorPast(columns: Int, rows: Int) {
        var column = grid.cursor.column + columns
        var row = grid.cursor.row + rows - 1
        if column >= grid.columns {
            column = 0
            row += 1
        }
        if grid.cursor.row <= grid.marginBottom, row > grid.marginBottom {
            // The whole distance, as kitty's `screen_scroll` does: `scrollUp`
            // stops at one region's height, which would leave the cursor
            // inside an image taller than the screen.
            let regionHeight = grid.marginBottom - grid.marginTop + 1
            var remaining = min(row - grid.marginBottom, regionHeight + grid.rows)
            while remaining > 0 {
                let step = min(remaining, regionHeight)
                grid.scrollUp(step)
                remaining -= step
            }
            row = grid.marginBottom
        }
        grid.moveCursor(row: row, column: column)
    }

    /// Pads to a multiple of 4: `Data(base64Encoded:)` rejects unpadded input,
    /// which RFC 4648 §3.2 allows and `kitten icat` sends.
    private static func padded(_ base64: [UInt8]) -> [UInt8] {
        let remainder = base64.count % 4
        guard remainder != 0 else { return base64 }
        return base64 + Array(repeating: UInt8(ascii: "="), count: 4 - remainder)
    }
}

/// A finished transmission whose decode runs outside the session's lock:
/// pure work on its own bytes, safe on any thread.
struct DeferredImageTransmission: Sendable {
    let pending: PendingImageTransmission
    let resetCount: Int

    /// The bytes the decode will hold, charged to the image budget while it
    /// runs (`Terminal.retainedImageBytes`).
    var decodedByteEstimate: Int { pending.base64.count / 4 * 3 }

    func decode() -> DecodedImageTransmission {
        let result: Result<KittyGraphics.ImageData, Performer.TransmissionRefusal>
        do throws(Performer.TransmissionRefusal) {
            result = .success(try Performer.transmittedImage(pending))
        } catch {
            result = .failure(error)
        }
        // Completion needs the header and display alone; the base64 (up to
        // ~85 MiB) goes now, not after another lock round trip.
        var settled = pending
        settled.base64 = []
        return DecodedImageTransmission(pending: settled, resetCount: resetCount, result: result)
    }
}

extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

/// `DeferredImageTransmission.decode()`'s result, for `Terminal.completeDeferredImage`.
struct DecodedImageTransmission: Sendable {
    let pending: PendingImageTransmission
    let resetCount: Int
    let result: Result<KittyGraphics.ImageData, Performer.TransmissionRefusal>
}
