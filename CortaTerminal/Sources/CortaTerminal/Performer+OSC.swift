import Foundation

/// OSC string handling — M2.8. Setters only: nothing here ever writes back
/// to the child, and the title *query* (`CSI 2 1 t`) is never implemented —
/// it is a command-injection vector (`SECURITY.md` §2.2).
///
/// The payload is already capped at `Parser.maxStringLength`; an overlong
/// string is discarded by the parser and never reaches this point.
extension Performer {
    public mutating func oscDispatch(_ bytes: ArraySlice<UInt8>) {
        guard let separator = bytes.firstIndex(of: 0x3B) else { return }  // ';'

        var code = 0
        for byte in bytes[..<separator] {
            guard byte >= 0x30, byte <= 0x39 else { return }
            code = code * 10 + Int(byte - 0x30)
            guard code <= 999 else { return }
        }
        let payload = bytes[bytes.index(after: separator)...]

        switch code {
        case 0, 2:
            // OSC 0 is icon-and-window title; Corta has no icon title, so
            // both set the window title.
            state.windowTitle = String(decoding: payload, as: UTF8.self)
        case 7:
            setWorkingDirectory(payload)
        case 52:
            setClipboard(payload)
        case 133:
            shellIntegration(payload)
        case 8:
            setHyperlink(payload)
        case 10, 11, 12:
            // The dynamic colours (M6.6). A payload of exactly `?` is the
            // query form; anything else is a colour specification to set.
            // Unlike the title, these are numeric state, so reporting them
            // echoes nothing the stream supplied (`SECURITY.md` §2.2).
            if payload.count == 1, payload.first == 0x3F {
                reportDynamicColor(code)
            } else {
                setDynamicColor(code, specification: payload)
            }
        default:
            break
        }
    }

    /// OSC 8 — `OSC 8 ; params ; URI ST` (M6.8).
    ///
    /// The parameters (`id=…`, and anything a future spec adds) are parsed
    /// and discarded: `id` exists so a terminal can treat two runs of cells
    /// as one link for hover highlighting, which Corta does by target
    /// instead — identical URLs intern to one id, which gives the same
    /// answer without trusting a stream-supplied identifier.
    ///
    /// An empty URI ends the current link, which is how a program stops
    /// linking. So does a URI the table cannot take (over-long, or the table
    /// is full): failing closed means the following text is unlinked rather
    /// than silently joined to whatever link came before.
    private mutating func setHyperlink(_ payload: ArraySlice<UInt8>) {
        guard let separator = payload.firstIndex(of: 0x3B) else {  // ';'
            grid.pen.hyperlink = .none
            return
        }
        let uri = String(decoding: payload[payload.index(after: separator)...], as: UTF8.self)
        guard !uri.isEmpty, let id = grid.hyperlinks.intern(uri) else {
            grid.pen.hyperlink = .none
            return
        }
        grid.pen.hyperlink = id
    }

    /// OSC 52 — `OSC 52 ; Pc ; Pd ST`, the clipboard (M7.11).
    ///
    /// **Write only.** `Pd` of `?` is the *query* form, which answers with the
    /// clipboard's contents — a remote host reading the local clipboard, which
    /// is a data-exfiltration primitive and one of the capabilities Corta
    /// deliberately does not have (`SECURITY.md` §6). It is ignored here and
    /// nowhere else implements it.
    ///
    /// The write half is why the sequence exists in practice: inside `tmux`
    /// or over `ssh` there is no other route from the remote pane to this
    /// Mac's pasteboard. The decoded text is handed to the app, which still
    /// gets to refuse — `allow-clipboard-write = false` turns the whole thing
    /// off.
    ///
    /// The payload is already bounded by `Parser.maxStringLength`, so the
    /// decode cannot be made to allocate without limit.
    private mutating func setClipboard(_ payload: ArraySlice<UInt8>) {
        guard let separator = payload.firstIndex(of: 0x3B) else { return }  // ';'
        let data = payload[payload.index(after: separator)...]
        // The query form, and the "clear the selection" form (empty data),
        // are both declined: nothing is reported back to the child, and a
        // stream is not allowed to blank the user's clipboard either.
        guard !data.isEmpty, data.first != 0x3F else { return }
        guard let text = Self.decodeBase64(data), !text.isEmpty else { return }
        state.pendingClipboardCopy = text
    }

    /// Strict base64, decoded here rather than through `Data(base64Encoded:)`
    /// so the bytes never take a detour through `String` and a malformed
    /// payload is rejected rather than partially accepted.
    ///
    /// The result is decoded as UTF-8 with replacement, not validated: this
    /// is text bound for a pasteboard, and refusing a clipboard copy because
    /// a byte was not valid UTF-8 helps nobody. It is never written back to
    /// the child under any circumstances (`SECURITY.md` §2.1).
    private static func decodeBase64(_ bytes: ArraySlice<UInt8>) -> String? {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count * 3 / 4)
        var accumulator: UInt32 = 0
        var bits = 0
        for byte in bytes {
            if byte == 0x3D { break }  // '=' padding ends the data
            guard let value = base64Value(byte) else {
                // Whitespace inside a long payload is common enough to skip.
                if byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 { continue }
                return nil
            }
            accumulator = (accumulator << 6) | UInt32(value)
            bits += 6
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((accumulator >> UInt32(bits)) & 0xFF))
            }
        }
        guard !output.isEmpty else { return nil }
        return String(decoding: output, as: UTF8.self)
    }

    private static func base64Value(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x41...0x5A: return byte - 0x41  // A-Z
        case 0x61...0x7A: return byte - 0x61 + 26  // a-z
        case 0x30...0x39: return byte - 0x30 + 52  // 0-9
        case 0x2B: return 62  // +
        case 0x2F: return 63  // /
        default: return nil
        }
    }

    /// OSC 7 — the payload is a `file://host/path` URL. Only `file` is
    /// meaningful for a local working directory; anything else is ignored.
    /// The hostname is deliberately not checked: the path is a hint for new
    /// tabs and splits, and a path that does not exist locally is the app
    /// layer's problem.
    private mutating func setWorkingDirectory(_ payload: ArraySlice<UInt8>) {
        let string = String(decoding: payload, as: UTF8.self)
        guard let url = URL(string: string), url.scheme == "file" else { return }
        let path = url.path(percentEncoded: false)
        guard !path.isEmpty else { return }
        state.workingDirectory = path
    }
}
