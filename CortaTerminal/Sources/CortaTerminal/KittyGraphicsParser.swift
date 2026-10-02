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

/// Parses an APC payload — `key=value,…;base64` — into a
/// `KittyGraphics.Command`. Unknown keys are ignored, not rejected
/// (`SECURITY.md` §3): a newer client may send one.
enum KittyGraphicsParser {
    /// `nil`: nothing recognisable, ignored like any unknown sequence.
    static func parse(_ apcBytes: ArraySlice<UInt8>) -> KittyGraphics.Command? {
        // Kitty's APC starts with `G`; anything else is not this protocol.
        guard apcBytes.first == UInt8(ascii: "G") else { return nil }
        let bytes = apcBytes[apcBytes.index(after: apcBytes.startIndex)...]
        guard let semicolon = bytes.firstIndex(of: UInt8(ascii: ";")) else {
            // No payload: still a valid delete or display.
            return command(from: parseKeyValues(bytes), payload: bytes[bytes.endIndex..<bytes.endIndex])
        }
        let controlData = bytes[bytes.startIndex..<semicolon]
        let payload = bytes[bytes.index(after: semicolon)...]
        return command(from: parseKeyValues(controlData), payload: payload)
    }

    private static func parseKeyValues(_ bytes: ArraySlice<UInt8>) -> [UInt8: ArraySlice<UInt8>] {
        var result: [UInt8: ArraySlice<UInt8>] = [:]
        var index = bytes.startIndex
        while index < bytes.endIndex {
            guard let equals = bytes[index...].firstIndex(of: UInt8(ascii: "=")) else { break }
            guard bytes.distance(from: index, to: equals) == 1 else { break }
            let key = bytes[index]
            let valueStart = bytes.index(after: equals)
            let comma = bytes[valueStart...].firstIndex(of: UInt8(ascii: ",")) ?? bytes.endIndex
            result[key] = bytes[valueStart..<comma]
            index = comma < bytes.endIndex ? bytes.index(after: comma) : bytes.endIndex
        }
        return result
    }

    private static func intValue(_ fields: [UInt8: ArraySlice<UInt8>], _ key: Character) -> Int? {
        guard let raw = fields[key.asciiValue!] else { return nil }
        return Int(String(decoding: raw, as: UTF8.self))
    }

    /// Checked: an unchecked conversion of a negative or huge id is a
    /// release-build trap on hostile input. `nil` ignores the command.
    private static func uint32ID(_ value: Int?) -> UInt32? {
        value.flatMap(UInt32.init(exactly:))
    }

    private static func command(
        from fields: [UInt8: ArraySlice<UInt8>], payload: ArraySlice<UInt8>
    ) -> KittyGraphics.Command? {
        let action = fields[UInt8(ascii: "a")].map { String(decoding: $0, as: UTF8.self) } ?? "t"
        switch action {
        case "t", "T":
            guard let header = transmitHeader(fields) else { return nil }
            let moreChunks = intValue(fields, "m") == 1
            // A bad `p=` rejects the transmit too: half a command stores an image
            // the client cannot reference as it asked.
            if action == "T" {
                guard let display = displayHeader(fields, imageID: header.imageID) else { return nil }
                return .transmit(header, payloadBase64: payload, moreChunks: moreChunks, display: display)
            }
            return .transmit(header, payloadBase64: payload, moreChunks: moreChunks, display: nil)
        case "p":
            guard let rawImageID = uint32ID(intValue(fields, "i")) else { return nil }
            let imageID = KittyGraphics.ImageID(rawValue: rawImageID)
            guard let display = displayHeader(fields, imageID: imageID) else { return nil }
            return .display(display)
        case "d":
            return .delete(deleteTarget(fields))
        case "q":
            guard let header = transmitHeader(fields) else { return nil }
            return .query(header)
        default:
            // Animation and other unknown actions: ignored.
            return nil
        }
    }

    private static func transmitHeader(_ fields: [UInt8: ArraySlice<UInt8>]) -> KittyGraphics.TransmitHeader? {
        // Only direct transmission (see `KittyGraphics`); absent means `d`.
        let medium = fields[UInt8(ascii: "t")].map { String(decoding: $0, as: UTF8.self) } ?? "d"
        guard medium == "d" else { return nil }
        // Absent `i=` is 0: `kitten icat` omits it for a one-shot display, and
        // requiring one dropped every such command.
        guard let rawImageID = uint32ID(intValue(fields, "i") ?? 0) else { return nil }
        // First chunk only; `Performer.receiveChunk` applies the defaults.
        let format = intValue(fields, "f").flatMap(KittyGraphics.PixelFormat.init(code:))
        // Clamped: they size an allocation before a byte is trusted.
        let width = intValue(fields, "s").map { min(max(0, $0), 8192) }
        let height = intValue(fields, "v").map { min(max(0, $0), 8192) }
        let quiet = min(max(0, intValue(fields, "q") ?? 0), 2)
        // `o=z` is the one compression the protocol defines. Any other value
        // names an encoding this terminal cannot read, and bytes taken as
        // pixels when they are not would be garbage at best: refused whole.
        var compressed = false
        if let compression = fields[UInt8(ascii: "o")] {
            guard compression.elementsEqual("z".utf8) else { return nil }
            compressed = true
        }
        return KittyGraphics.TransmitHeader(
            imageID: KittyGraphics.ImageID(rawValue: rawImageID), format: format, width: width,
            height: height, quiet: quiet, compressed: compressed)
    }

    private static func displayHeader(
        _ fields: [UInt8: ArraySlice<UInt8>], imageID: KittyGraphics.ImageID
    ) -> KittyGraphics.DisplayHeader? {
        let placementID: KittyGraphics.PlacementID
        if let rawPlacement = intValue(fields, "p") {
            guard let placement = uint32ID(rawPlacement) else { return nil }
            placementID = KittyGraphics.PlacementID(rawValue: placement)
        } else {
            placementID = KittyGraphics.PlacementID(rawValue: imageID.rawValue)
        }
        let columns = intValue(fields, "c").map { min(max(0, $0), 4096) }
        let rows = intValue(fields, "r").map { min(max(0, $0), 4096) }
        let zIndex = intValue(fields, "z") ?? 0
        let quiet = min(max(0, intValue(fields, "q") ?? 0), 2)
        return KittyGraphics.DisplayHeader(
            imageID: imageID, placementID: placementID,
            columns: (columns ?? 0) > 0 ? columns : nil, rows: (rows ?? 0) > 0 ? rows : nil,
            zIndex: zIndex, quiet: quiet, movesCursor: intValue(fields, "C") != 1)
    }

    private static func deleteTarget(_ fields: [UInt8: ArraySlice<UInt8>]) -> KittyGraphics.DeleteTarget {
        let what = fields[UInt8(ascii: "d")].map { String(decoding: $0, as: UTF8.self) } ?? "a"
        // Both cases parse; both drop the image, since ids are never recycled.
        switch what.lowercased() {
        case "a":
            return .all
        case "i":
            guard let rawImageID = uint32ID(intValue(fields, "i")) else { return .unrecognised }
            let imageID = KittyGraphics.ImageID(rawValue: rawImageID)
            if let rawPlacement = intValue(fields, "p") {
                // An invalid `p=` must not widen to the whole image.
                guard let placement = uint32ID(rawPlacement) else { return .unrecognised }
                if placement > 0 {
                    return .placement(imageID, KittyGraphics.PlacementID(rawValue: placement))
                }
            }
            return .image(imageID)
        default:
            // By-position and by-range deletes: recognised, not honoured.
            return .unrecognised
        }
    }
}
