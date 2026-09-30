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

    /// `a=q`: from the header alone, nothing decoded or stored.
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
    /// carries just `i=`/`m=`.
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
        // Checked per chunk, so a stream cannot park just under the limit.
        let budget = KittyGraphics.maximumImageBytes / 3 * 4 + 4
        guard state.pendingImageTransmission!.base64.count + payloadBase64.count <= budget else {
            // Still acknowledged, with the pending header's `quiet` — a continuation
            // carries no `q=`, and re-parsing it would un-quiet the transmission.
            let pending = state.pendingImageTransmission!
            state.pendingImageTransmission = nil
            respond(
                imageID: pending.header.imageID, placementID: nil, quiet: pending.header.quiet,
                error: "EINVAL:too large")
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
        let format = pending.header.format ?? .rgba
        let width = pending.header.width ?? 0
        let height = pending.header.height ?? 0
        // Exactly `width * height * bytesPerPixel`, or dropped — never padded.
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
        let storedID: KittyGraphics.ImageID
        let refusal: ImagePlacementTable.StoreRefusal?
        if imageID.rawValue == 0 {
            (storedID, refusal) = grid.imagePlacements.storeAnonymous(data)
        } else {
            (storedID, refusal) = (imageID, grid.imagePlacements.store(imageID, data: data))
        }
        switch refusal {
        case nil:
            break
        case .dimensionsExceedCaps?:
            respond(imageID: imageID, placementID: nil, quiet: quiet, error: "EINVAL:image dimensions too large")
            return
        case .tooManyImages?:
            respond(imageID: imageID, placementID: nil, quiet: quiet, error: "ENOSPC:too many images")
            return
        case .byteBudgetExceeded?:
            respond(imageID: imageID, placementID: nil, quiet: quiet, error: "ENOSPC:image data too large")
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

    private mutating func placeAtCursor(_ display: KittyGraphics.DisplayHeader, respond respondFlag: Bool = true) {
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
            var remaining = row - grid.marginBottom
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
