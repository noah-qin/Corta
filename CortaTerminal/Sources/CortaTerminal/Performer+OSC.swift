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

/// OSC handling. Setters only; the title query is never implemented — a
/// command-injection vector (`SECURITY.md` §2.2). Payloads are already
/// capped by `Parser.maxStringLength`.
extension Performer {
    public mutating func oscDispatch(_ bytes: ArraySlice<UInt8>) {
        guard let separator = bytes.firstIndex(of: 0x3B) else {
            // A bare code: only OSC 104/105 ("reset everything") uses one — the
            // form xterm itself sends.
            if let code = Self.parseOSCCode(bytes) {
                if code == 104 {
                    resetIndexedColors(bytes[bytes.endIndex...])
                } else if code == 105 {
                    resetSpecialColors(bytes[bytes.endIndex...])
                }
            }
            return
        }

        guard let code = Self.parseOSCCode(bytes[..<separator]) else { return }
        let payload = bytes[bytes.index(after: separator)...]

        switch code {
        case 0, 2:
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
            handleIndexedColor(payload)
        case 104:
            resetIndexedColors(payload)
        case 5:
            // Implemented because xterm documents the `Pc` values (0 bold …
            // 4 italic), unlike the colour spaces OSC 10/11/12 refuse.
            handleSpecialColor(payload)
        case 105:
            resetSpecialColors(payload)
        case 10, 11, 12:
            // `?` queries; numeric state, so nothing the stream supplied is echoed.
            if payload.count == 1, payload.first == 0x3F {
                reportDynamicColor(code)
            } else {
                setDynamicColor(code, specification: payload)
            }
        default:
            break
        }
    }

    /// At most three digits, bounded before each multiply-add.
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

    /// OSC 8. `id=` is ignored: identical URLs intern to one id, which groups
    /// cells without trusting a stream-supplied identifier. An empty URI — or
    /// one the table cannot take — ends the link, failing closed.
    private mutating func setHyperlink(_ payload: ArraySlice<UInt8>) {
        guard let separator = payload.firstIndex(of: 0x3B) else {  // ';'
            grid.pen.hyperlink = .none
            return
        }
        let uri = String(decoding: payload[payload.index(after: separator)...], as: UTF8.self)
        // Through `Grid`: a full table gets a reference-safe sweep first.
        guard !uri.isEmpty, let id = grid.internHyperlink(uri) else {
            grid.pen.hyperlink = .none
            return
        }
        grid.pen.hyperlink = id
    }

    /// OSC 52, **write only**: the query form would let a remote host read the
    /// local clipboard (`SECURITY.md` §6). Writing is the only route from a
    /// remote pane to this Mac's pasteboard; `allow-clipboard-write = false`
    /// turns it off. Text is sanitised first — a stream chose it, sight unseen
    /// (`SECURITY.md` §2.5).
    private mutating func setClipboard(_ payload: ArraySlice<UInt8>) {
        guard let separator = payload.firstIndex(of: 0x3B) else { return }  // ';'
        let data = payload[payload.index(after: separator)...]
        // Query and "clear" are both declined: a stream may not blank the
        // clipboard either.
        guard !data.isEmpty, data.first != 0x3F else { return }
        guard let decoded = Self.decodeBase64(data) else { return }
        let text = Self.sanitiseClipboardText(decoded)
        guard !text.isEmpty else { return }
        state.pendingClipboardCopy = text
    }

    /// Strips bidi embeddings, overrides and isolates and the zero-width
    /// characters that hide content (ZWSP, word joiner, BOM) — what lets pasted
    /// text differ from how it displayed. Keeps ZWJ/ZWNJ and LRM/RLM, which real
    /// text needs.
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

    /// Strict base64 without a detour through `String`; data after padding is
    /// rejected. UTF-8 with replacement — refusing a paste over one byte helps
    /// nobody. Never written back to the child (`SECURITY.md` §2.1).
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

    /// OSC 7 (`file://host/path`). A local host sets `workingDirectory` and
    /// clears remote context; a remote one goes to `remoteContext`, kept apart
    /// because that path must never be `chdir`'d here, and leaves any accepted
    /// local directory in place.
    private mutating func setWorkingDirectory(_ payload: ArraySlice<UInt8>) {
        let string = String(decoding: payload, as: UTF8.self)
        guard let url = URL(string: string), url.scheme == "file" else { return }
        let host = url.host(percentEncoded: false) ?? ""
        let path = url.path(percentEncoded: false)
        guard !path.isEmpty else { return }
        if Self.isLocalHost(host) {
            state.workingDirectory = path
            state.remoteContext = nil
        } else {
            state.remoteContext = RemoteContext(
                host: Self.normalizeHostname(host), directory: path,
                provenance: .osc7, reportedAt: Date())
        }
    }

    /// Whether an OSC 7 host names this machine. Comparison is
    /// case-insensitive and ignores a trailing dot, so a shell reporting the
    /// FQDN form (`host.example.`) still matches the bare name.
    static func isLocalHost(_ host: String, localNames: Set<String> = localHostnames()) -> Bool {
        let normalized = normalizeHostname(host)
        return normalized.isEmpty || localNames.contains(normalized)
    }

    /// This machine's names, normalised: `localhost`, and the full and short
    /// (first-label) forms of the kernel's hostname — what a shell reports,
    /// since zsh's `$HOST` and `hostname` both read it, and a shell usually
    /// reports the short form even when the system keeps the `.local` one.
    ///
    /// `gethostname(3)` only, never `ProcessInfo.hostName` or `Host`: those
    /// resolve the name through DNS, blocking the caller until the lookup
    /// answers or times out. This runs on every OSC 7 report — on the PTY
    /// reader thread, once per prompt — and on a machine whose resolver is
    /// slow or unreachable the lookup took 36 seconds, during which the pane
    /// showed no output at all.
    static func localHostnames() -> Set<String> {
        var names: Set<String> = ["localhost"]
        var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return names }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let normalized = normalizeHostname(String(decoding: bytes, as: UTF8.self))
        guard !normalized.isEmpty else { return names }
        names.insert(normalized)
        if let dot = normalized.firstIndex(of: ".") {
            names.insert(String(normalized[..<dot]))
        }
        return names
    }

    static func normalizeHostname(_ host: String) -> String {
        var normalized = host.lowercased()
        while normalized.hasSuffix(".") { normalized.removeLast() }
        return normalized
    }
}
