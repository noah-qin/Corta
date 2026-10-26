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

struct ITermImageTransfer: Sendable {
    var options: [String: String]
    var base64: [UInt8] = []
}

extension Performer {
    mutating func receiveITermImage(key: String, value: ArraySlice<UInt8>) {
        switch key {
        case "File", "MultipartFile":
            let colon = value.firstIndex(of: 58)
            let header = colon.map { value[..<$0] } ?? value
            guard header.count <= Parser.maxStringLength else { return }
            var options: [String: String] = [:]
            for field in String(decoding: header, as: UTF8.self).split(separator: ";") {
                let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if pair.count == 2 { options[String(pair[0])] = String(pair[1]) }
            }
            guard options["inline"] == "1" else { return }
            if let raw = options["size"] {
                guard let size = Int(raw), size > 0, size <= KittyGraphics.maximumImageBytes else { return }
            }
            state.itermImage = ITermImageTransfer(options: options)
            if key == "File" {
                guard let colon else { state.itermImage = nil; return }
                appendITermPart(value[value.index(after: colon)...])
                finishITermImage()
            }
        case "FilePart": appendITermPart(value)
        case "FileEnd": finishITermImage()
        default: break
        }
    }

    /// The base64 an image may still take, from the per-pane and process
    /// budgets as they stand now.
    private mutating func inlineImageBase64Limit() -> Int {
        if let imageAllowanceProvider { state.imageByteAllowance = imageAllowanceProvider() }
        applyImageAllowance()
        let available = grid.imagePlacements.availableBytes(for: .init(rawValue: 0))
        return min(KittyGraphics.maximumImageBytes, available) / 3 * 4 + 4
    }

    /// The legacy single-sequence form carries its header and the whole
    /// image in one OSC; cap the parser's buffer at what could be accepted.
    mutating func inlineImageStringLimit() -> Int {
        min(Parser.maxInlineImageStringLength, inlineImageBase64Limit() + 4096)
    }

    private mutating func appendITermPart(_ value: ArraySlice<UInt8>) {
        guard state.itermImage != nil else { return }
        let limit = inlineImageBase64Limit()
        guard state.itermImage!.base64.count + value.count <= limit else {
            state.itermImage = nil; return
        }
        state.itermImage!.base64.append(contentsOf: value)
    }

    private mutating func finishITermImage() {
        guard let transfer = state.itermImage else { return }
        state.itermImage = nil
        let header = KittyGraphics.TransmitHeader(imageID: .init(rawValue: 0), format: .png, quiet: 2)
        finishTransmission(PendingImageTransmission(header: header, display: nil,
            base64: transfer.base64, itermOptions: transfer.options))
    }

    static let maximumImageCells = 4096

    mutating func placeITermImage(_ received: KittyGraphics.ImageData, options: [String: String]) {
        let bytes = received.bytes
        if let raw = options["size"], Int(raw) != bytes.count { return }
        guard let dimensions = KittyGraphics.encodedDimensions(bytes),
            KittyGraphics.dimensionsFit(width: dimensions.width, height: dimensions.height) else { return }
        let cw = max(1, grid.cellPixelWidth), ch = max(1, grid.cellPixelHeight)
        func pixels(_ raw: String?, cell: Int, count: Int) -> Double? {
            guard let raw, raw != "auto" else { return nil }
            let unit = raw.hasSuffix("px") ? 2 : raw.hasSuffix("%") ? 1 : 0
            let number = unit == 0 ? raw : String(raw.dropLast(unit))
            guard let n = Double(number), n.isFinite, n > 0, n <= 1_000_000 else { return nil }
            return unit == 2 ? n : unit == 1 ? n / 100 * Double(count * cell) : n * Double(cell)
        }
        let w = pixels(options["width"], cell: cw, count: grid.columns)
        let h = pixels(options["height"], cell: ch, count: grid.rows)
        let naturalW = Double(dimensions.width), naturalH = Double(dimensions.height)
        var width = w ?? naturalW, height = h ?? naturalH
        if options["preserveAspectRatio"] != "0" {
            let scale: Double
            if let w, let h { scale = min(w / naturalW, h / naturalH) }
            else if let w { scale = w / naturalW }
            else if let h { scale = h / naturalH }
            else { scale = min(1, Double(grid.columns * cw) / naturalW) }
            width = naturalW * scale; height = naturalH * scale
        }
        guard width.isFinite, height.isFinite, width > 0, height > 0,
            width <= 1_000_000, height <= 1_000_000 else { return }
        // The same 4096-cell extent kitty's `c=`/`r=` are clamped to.
        let maxWidth = Double(Self.maximumImageCells * cw), maxHeight = Double(Self.maximumImageCells * ch)
        if width > maxWidth || height > maxHeight {
            if options["preserveAspectRatio"] != "0" {
                let fit = min(maxWidth / width, maxHeight / height)
                width *= fit; height *= fit
            } else {
                width = min(width, maxWidth); height = min(height, maxHeight)
            }
        }
        let data = KittyGraphics.ImageData(format: bytes.first == 0x47 ? .gif : .png,
            width: 0, height: 0, bytes: bytes)
        guard let id = try? store(data, as: .init(rawValue: 0)) else { return }
        let display = KittyGraphics.DisplayHeader(imageID: id, placementID: .init(rawValue: id.rawValue),
            columns: max(1, Int(ceil(width / Double(cw)))), rows: max(1, Int(ceil(height / Double(ch)))),
            zIndex: 0, quiet: 2, displayPixelWidth: max(1, Int(width.rounded())),
            displayPixelHeight: max(1, Int(height.rounded())))
        placeAtCursor(display, respond: false)
    }
}
