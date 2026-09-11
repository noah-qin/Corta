import Foundation

/// OSC string handling — M2.8. Setters only: nothing here ever writes back
/// to the child, and the title *query* (`CSI 2 1 t`) is never implemented —
/// it is a command-injection vector (`SECURITY.md` §2.2).
///
/// The payload is already capped at `Parser.maxStringLength`; an overlong
/// string is discarded by the parser and never reaches this point.
extension Performer {
    public mutating func oscDispatch(_ bytes: ArraySlice<UInt8>) {
        guard let separator = bytes.firstIndex(of: 0x3B) else {
            // No `;`-separated payload at all. Every code but one needs
            // one to do anything and is unchanged by leaving it alone here;
            // OSC 104 with no arguments — "reset the whole indexed
            // palette" (B06) — is the one real use of a bare code, and it
            // is the most common real-world form of the reset (xterm
            // itself sends `OSC 104 ST` with nothing after it).
            if let code = Self.parseOSCCode(bytes), code == 104 {
                resetIndexedColors(bytes[bytes.endIndex...])
            }
            return
        }

        guard let code = Self.parseOSCCode(bytes[..<separator]) else { return }
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
        case 4:
            // The indexed palette (B06) — set/query, one or more `c ; spec`
            // pairs. OSC 5 (xterm's "special colours") is deliberately not
            // implemented: unlike OSC 4, its exact index semantics are not
            // independently documented anywhere Corta can verify against
            // without the esctest suite itself, and guessing wrong is worse
            // than not answering.
            handleIndexedColor(payload)
        case 104:
            resetIndexedColors(payload)
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

    /// A decimal OSC code, capped the way the wire format is: at most three
    /// digits. `nil` for anything else, including an empty span or an
    /// arbitrarily long run of digits — the bound is checked *before* each
    /// multiply-and-add, not after, so `code` never exceeds 999 regardless
    /// of how many digits a hostile payload supplies. The caller decides
    /// what "no code at all" means for an empty span.
    private static func parseOSCCode(_ bytes: ArraySlice<UInt8>) -> Int? {
        guard !bytes.isEmpty else { return nil }
        var code = 0
        for byte in bytes {
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            let digit = Int(byte - 0x30)
            guard code <= (999 - digit) / 10 else { return nil }
            code = code * 10 + digit
        }
        return code
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
        // `Grid.internHyperlink`, not the table directly: a full table gets
        // a reference-safe sweep and one retry before failing closed (P06).
        guard !uri.isEmpty, let id = grid.internHyperlink(uri) else {
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
    ///
    /// The decoded text passes through `sanitiseClipboardText` before it is
    /// recorded: bidi and zero-width control characters are stripped, because
    /// this is text a *stream* chose, sight unseen — there is no "copy what I
    /// selected" contract to honour, and a payload whose pasted form differs
    /// from what any display of it suggested is the Trojan Source class of
    /// attack (`SECURITY.md` §2.5).
    private mutating func setClipboard(_ payload: ArraySlice<UInt8>) {
        guard let separator = payload.firstIndex(of: 0x3B) else { return }  // ';'
        let data = payload[payload.index(after: separator)...]
        // The query form, and the "clear the selection" form (empty data),
        // are both declined: nothing is reported back to the child, and a
        // stream is not allowed to blank the user's clipboard either.
        guard !data.isEmpty, data.first != 0x3F else { return }
        guard let decoded = Self.decodeBase64(data) else { return }
        let text = Self.sanitiseClipboardText(decoded)
        guard !text.isEmpty else { return }
        state.pendingClipboardCopy = text
    }

    /// Removes the characters that let clipboard content lie about itself:
    /// bidi embeddings, overrides and isolates (U+202A–U+202E, U+2066–U+2069),
    /// which can reorder how the pasted text *displays* versus what it
    /// *is*, and the zero-width format characters (ZWSP U+200B, word joiner
    /// U+2060, ZWNBSP/BOM U+FEFF), which hide content outright. Kept:
    /// ZWJ and ZWNJ (emoji sequences and scripts that need them) and
    /// LRM/RLM, which are load-bearing in real bidi text and reorder nothing
    /// on their own.
    static func sanitiseClipboardText(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.filter { !isSpoofingScalar($0) })
        return String(scalars)
    }

    private static func isSpoofingScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x202A...0x202E, 0x2066...0x2069, 0x200B, 0x2060, 0xFEFF:
            return true
        default:
            return false
        }
    }

    /// Strict base64, decoded here rather than through `Data(base64Encoded:)`
    /// so the bytes never take a detour through `String` and a malformed
    /// payload is rejected rather than partially accepted — including data
    /// trailing the `=` padding, which is not a valid place for more data.
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
        var paddingSeen = false
        for byte in bytes {
            if byte == 0x3D {  // '=' padding ends the data
                paddingSeen = true
                continue
            }
            if byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 {
                // Whitespace inside a long payload is common enough to skip.
                continue
            }
            guard !paddingSeen, let value = base64Value(byte) else { return nil }
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
    ///
    /// The host part is checked, because a shell reached over `ssh` (or a
    /// pane inside `tmux` on one) reports a directory on *that* host with
    /// its hostname attached. The report feeds local spawns — new tabs,
    /// splits, session restore — so a remote path kept here would be `chdir`'d
    /// on this Mac, opening the new shell in a lookalike directory or an
    /// unrelated one that happens to exist. Only a local host (empty,
    /// `localhost`, or this machine's own names) is accepted; a remote
    /// report is dropped, which leaves the app its kernel-side fallback
    /// (`PTY.currentWorkingDirectory`).
    private mutating func setWorkingDirectory(_ payload: ArraySlice<UInt8>) {
        let string = String(decoding: payload, as: UTF8.self)
        guard let url = URL(string: string), url.scheme == "file" else { return }
        guard Self.isLocalHost(url.host(percentEncoded: false) ?? "") else { return }
        let path = url.path(percentEncoded: false)
        guard !path.isEmpty else { return }
        state.workingDirectory = path
    }

    /// Whether an OSC 7 host names this machine. Comparison is
    /// case-insensitive and ignores a trailing dot, so a shell reporting the
    /// FQDN form (`host.example.`) still matches the bare name.
    static func isLocalHost(_ host: String, localNames: Set<String> = localHostnames()) -> Bool {
        let normalized = normalizeHostname(host)
        return normalized.isEmpty || localNames.contains(normalized)
    }

    /// This machine's names, normalised: `localhost`, the full and short
    /// (first-label) forms of every name the system knows itself by — a
    /// shell usually reports `hostname`'s short answer even when the system
    /// keeps the `.local` form.
    static func localHostnames() -> Set<String> {
        var names: Set<String> = ["localhost"]
        let candidates = [
            ProcessInfo.processInfo.hostName, Host.current().name, Host.current().localizedName,
        ]
        for candidate in candidates {
            guard let candidate else { continue }
            let normalized = normalizeHostname(candidate)
            names.insert(normalized)
            if let dot = normalized.firstIndex(of: ".") {
                names.insert(String(normalized[..<dot]))
            }
        }
        return names
    }

    static func normalizeHostname(_ host: String) -> String {
        var normalized = host.lowercased()
        while normalized.hasSuffix(".") { normalized.removeLast() }
        return normalized
    }
}
