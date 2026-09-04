import Foundation

/// Parses one APC payload's control-data prefix (`key=value,key=value,...`)
/// plus everything after the first unescaped `;`, which is the base64
/// payload — into a `KittyGraphics.Command`. Fed by `Parser`'s
/// `.apcString` state via `Performer.apcDispatch(_:)`.
///
/// The wire format itself (<https://sw.kovidgoyal.net/kitty/graphics-protocol/>)
/// is comma-separated `letter=value` pairs ending at `;`, then raw payload
/// bytes to the terminator. Unknown keys are ignored, not rejected — the
/// same "unknown sequences are safely ignored" rule the CSI/OSC parsers
/// already follow (`SECURITY.md` §3), since a newer client may send a key
/// this implementation has no use for.
enum KittyGraphicsParser {
    /// `nil` means the payload was too malformed to act on at all (no
    /// recognisable action) — silently ignored by the caller, the same as
    /// any other escape sequence Corta does not implement.
    static func parse(_ apcBytes: ArraySlice<UInt8>) -> KittyGraphics.Command? {
        // APC is a generic mechanism; kitty marks its own use of it with a
        // leading `G` (`ESC _ G <control data> ; <payload> ESC \`) so a
        // future user of APC for something else is not misread as a
        // graphics command. An APC string that does not start with it is
        // not this protocol at all — ignored, not an error.
        guard apcBytes.first == UInt8(ascii: "G") else { return nil }
        let bytes = apcBytes[apcBytes.index(after: apcBytes.startIndex)...]
        guard let semicolon = bytes.firstIndex(of: UInt8(ascii: ";")) else {
            // No payload section at all — still potentially a valid
            // control-only command (delete, or a bare display of an
            // already-transmitted image).
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
            // A single-byte key, per the spec — every key the protocol
            // defines is one ASCII letter.
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

    private static func command(
        from fields: [UInt8: ArraySlice<UInt8>], payload: ArraySlice<UInt8>
    ) -> KittyGraphics.Command? {
        let action = fields[UInt8(ascii: "a")].map { String(decoding: $0, as: UTF8.self) } ?? "t"
        switch action {
        case "t", "T":
            guard let header = transmitHeader(fields) else { return nil }
            let moreChunks = intValue(fields, "m") == 1
            let display = action == "T" ? displayHeader(fields, imageID: header.imageID) : nil
            return .transmit(header, payloadBase64: payload, moreChunks: moreChunks, display: display)
        case "p":
            guard let imageID = intValue(fields, "i").map({ KittyGraphics.ImageID(rawValue: UInt32($0)) })
            else { return nil }
            return .display(displayHeader(fields, imageID: imageID))
        case "d":
            return .delete(deleteTarget(fields))
        case "q":
            // The support-detection probe: answered from the header alone
            // (`Performer.respondToQuery`), never storing or displaying —
            // reuses `transmitHeader` since a query carries the same
            // `i=`/`f=`/`s=`/`v=` fields a transmission's first chunk does.
            guard let header = transmitHeader(fields) else { return nil }
            return .query(header)
        default:
            // An action this implementation does not know — an animation
            // frame (`a=f`/`a=a`), a transmit-and-frame combination.
            // Ignored cleanly, per the same "unknown sequences do nothing"
            // rule as everywhere else.
            return nil
        }
    }

    private static func transmitHeader(_ fields: [UInt8: ArraySlice<UInt8>]) -> KittyGraphics.TransmitHeader? {
        // `t=` is the transmission medium; only `d` (direct, the payload
        // itself) is implemented — see `KittyGraphics`'s doc comment on why
        // file/temp-file/shared-memory are refused rather than honoured.
        // Absent defaults to `d`, per the spec.
        let medium = fields[UInt8(ascii: "t")].map { String(decoding: $0, as: UTF8.self) } ?? "d"
        guard medium == "d" else { return nil }
        // Absent `i=` defaults to 0 — a real client's most common shape, not
        // a malformed one: a one-shot `a=T` that will never be referenced
        // again (no later `a=p` re-display, no chunked follow-up) has no
        // reason to mint an id, and real `kitten icat` omits it exactly this
        // way for a plain, non-`--place` display. Requiring a positive id
        // here silently dropped every such command — found by a real-client
        // verification pass, the same one that found the missing response
        // protocol (`KittyGraphics.swift`'s doc comment). Only a *negative*
        // or oversized value is refused; those cannot be an id under any
        // reading of the spec.
        let imageID = intValue(fields, "i") ?? 0
        guard imageID >= 0, imageID <= Int(UInt32.max) else { return nil }
        // `f=`/`s=`/`v=` are only meaningful on the *first* chunk of a
        // transmission — a continuation chunk (`m=1` on the previous one)
        // carries only `i=` and the next slice of payload, per the
        // protocol, so these come back `nil` rather than defaulted here.
        // `Performer.receiveChunk` applies the real defaults, and only for
        // a transmission's first chunk — see its doc comment.
        let format = intValue(fields, "f").flatMap(KittyGraphics.PixelFormat.init(code:))
        // Clamped hard regardless: these numbers size an allocation before
        // a single payload byte is trusted (`SECURITY.md` §3).
        let width = intValue(fields, "s").map { min(max(0, $0), 8192) }
        let height = intValue(fields, "v").map { min(max(0, $0), 8192) }
        let quiet = min(max(0, intValue(fields, "q") ?? 0), 2)
        return KittyGraphics.TransmitHeader(
            imageID: KittyGraphics.ImageID(rawValue: UInt32(imageID)), format: format, width: width,
            height: height, quiet: quiet)
    }

    private static func displayHeader(
        _ fields: [UInt8: ArraySlice<UInt8>], imageID: KittyGraphics.ImageID
    ) -> KittyGraphics.DisplayHeader {
        let placementID =
            intValue(fields, "p").map { KittyGraphics.PlacementID(rawValue: UInt32(max(0, $0))) }
            ?? KittyGraphics.PlacementID(rawValue: imageID.rawValue)
        // Requested cell span, clamped to something no real terminal window
        // would exceed — the same defensive-clamp reasoning as the pixel
        // dimensions above.
        let columns = intValue(fields, "c").map { min(max(0, $0), 4096) }
        let rows = intValue(fields, "r").map { min(max(0, $0), 4096) }
        let zIndex = intValue(fields, "z") ?? 0
        let quiet = min(max(0, intValue(fields, "q") ?? 0), 2)
        return KittyGraphics.DisplayHeader(
            imageID: imageID, placementID: placementID,
            columns: (columns ?? 0) > 0 ? columns : nil, rows: (rows ?? 0) > 0 ? rows : nil,
            zIndex: zIndex, quiet: quiet)
    }

    private static func deleteTarget(_ fields: [UInt8: ArraySlice<UInt8>]) -> KittyGraphics.DeleteTarget {
        let what = fields[UInt8(ascii: "d")].map { String(decoding: $0, as: UTF8.self) } ?? "a"
        // Lowercase deletes only the placement, leaving the transmitted
        // image around for reuse; uppercase also frees the image itself.
        // This implementation does not distinguish the two once deleted —
        // both drop the image from the store, since nothing here recycles
        // freed image ids — but still parses both spellings so a client
        // using either does not fall through to "unrecognised".
        switch what.lowercased() {
        case "a":
            return .all
        case "i":
            guard let imageID = intValue(fields, "i") else { return .unrecognised }
            if let placementID = intValue(fields, "p"), placementID > 0 {
                return .placement(
                    KittyGraphics.ImageID(rawValue: UInt32(imageID)),
                    KittyGraphics.PlacementID(rawValue: UInt32(placementID)))
            }
            return .image(KittyGraphics.ImageID(rawValue: UInt32(imageID)))
        default:
            // `d`, `c`, `r`, `z`, `p`, `q`, `x`, `y` — by-position and
            // by-range deletes. Recognised as delete requests, not
            // misread as something else, but not honoured — see the type's
            // doc comment on why an unrecognised delete never deletes
            // something else instead.
            return .unrecognised
        }
    }
}
