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
        default:
            break
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
