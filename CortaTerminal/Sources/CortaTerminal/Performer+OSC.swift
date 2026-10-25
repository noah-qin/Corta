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
    mutating func oscDiscarded() {
        state.itermImage = nil
        state.clipboardTransfer = nil
    }

    public mutating func oscDispatch(_ bytes: ArraySlice<UInt8>) {
        if bytes.isEmpty { state.clipboardTransfer = nil }
        // A multipart image survives only its own parts/end; unrelated OSCs
        // cannot leave a large abandoned allocation behind.
        if !bytes.starts(with: Array("1337;FilePart=".utf8)),
            !bytes.elementsEqual(Array("1337;FileEnd".utf8)) {
            state.itermImage = nil
        }
        guard let separator = bytes.firstIndex(of: 0x3B) else {
            // A bare code: only OSC 104/105 ("reset everything") uses one — the
            // form xterm itself sends.
            if let code = Self.parseOSCCode(bytes) {
                if code == 104 {
                    resetIndexedColors(bytes[bytes.endIndex...])
                } else if [110, 111, 112, 117, 119].contains(code) {
                    resetDynamicColor(code)
                } else if code == 105 {
                    resetSpecialColors(bytes[bytes.endIndex...])
                }
            }
            return
        }

        guard let code = Self.parseOSCCode(bytes[..<separator]) else { return }
        let payload = bytes[bytes.index(after: separator)...]

        switch code {
        case 0:
            state.iconName = String(decoding: payload, as: UTF8.self)
            state.windowTitle = String(decoding: payload, as: UTF8.self)
        case 1:
            state.iconName = String(decoding: payload, as: UTF8.self)
        case 2:
            state.windowTitle = String(decoding: payload, as: UTF8.self)
        case 7:
            setWorkingDirectory(payload)
        case 7501:
            if payload.elementsEqual([0x3F]) {
                state.outputBuffer += [0x1B, 0x5D, 0x37, 0x35, 0x30, 0x31, 0x3B, 0x3F, 0x1B, 0x5C]
            } else { state.programSignals.status(String(decoding: payload, as: UTF8.self)) }
        case 9:
            if payload.elementsEqual(Array("12".utf8)) {
                shellIntegration([0x41][...])
            } else { state.programSignals.iterm(String(decoding: payload, as: UTF8.self)) }
        case 633:
            vscodeIntegration(payload)
        case 1337:
            itermExtension(payload)
        case 21:
            kittyColors(payload)
        case 22:
            pointerShape(payload)
        case 5522:
            extendedClipboard(payload)
        case 3, 6, 51, 106, 113, 114, 115, 116, 118, 3008:
            break // Accepted and ignored; see CONFORMANCE.md.
        case 46, 50, 5113:
            break // Refused: stream-selected files/fonts.
        case 66:
            break // Deferred until multi-cell glyph rendering is designed.
        case 777:
            let parts = String(decoding: payload, as: UTF8.self).split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count == 3, parts[0] == "notify" {
                var notice = DesktopNotification()
                notice.title = ProgramText.clean(String(parts[1]), limit: 192)
                notice.body = ProgramText.clean(String(parts[2]), limit: 2048)
                if !notice.title.isEmpty || !notice.body.isEmpty { state.programSignals.notification = notice }
            }
        case 99:
            state.outputBuffer += state.programSignals.kitty(String(decoding: payload, as: UTF8.self))
        case 21337:
            state.programSignals.tabStatus(String(decoding: payload, as: UTF8.self))
        case 52:
            setClipboard(payload)
        case 133:
            shellIntegration(payload)
        case 134:
            guard !grid.isAlternateScreenActive, !state.isCommandRunning,
                let token = directoryCompletionToken,
                let report = DirectoryCompletion.untokened(payload, expected: token) else { return }
            let text = String(decoding: report, as: UTF8.self)
            state.directoryCompletion = nil
            state.historySuggestion = nil
            if text.hasPrefix("h;") {
                if let suggestion = HistorySuggestion(payload: text), !suggestion.suffix.isEmpty {
                    state.historySuggestion = suggestion
                }
            } else {
                state.directoryCompletion = DirectoryCompletion(payload: text)
            }
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
        case 110, 111, 112, 117, 119:
            resetDynamicColor(code)
        case 13, 14, 15, 16, 18:
            break // Pointer/Tektronix colours have no corresponding surface.
        case 10, 11, 12, 17, 19:
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

    /// At most five digits, bounded before each multiply-add.
    private static func parseOSCCode(_ bytes: ArraySlice<UInt8>) -> Int? {
        guard !bytes.isEmpty else { return nil }
        var code = 0
        for byte in bytes {
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            let digit = Int(byte - 0x30)
            guard code <= (99999 - digit) / 10 else { return nil }
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
    mutating func setClipboard(_ payload: ArraySlice<UInt8>) {
        guard payload.count <= Parser.maxStringLength,
            let separator = payload.firstIndex(of: 0x3B) else { return }  // ';'
        let data = payload[payload.index(after: separator)...]
        // Query and "clear" are both declined: a stream may not blank the
        // clipboard either.
        guard !data.isEmpty, data.first != 0x3F else { return }
        guard let decoded = Self.decodeBase64(data) else { return }
        let text = Self.sanitiseClipboardText(decoded)
        guard !text.isEmpty else { return }
        state.pendingClipboardCopy = text
        state.clipboardNeedsAcknowledgement = false
    }

    /// Strips `ConcealingScalars` — what lets pasted text differ from how it
    /// displayed — and every control but tab, LF and CR. Corta's own paste
    /// strips controls again, but the pasteboard reaches other applications,
    /// and an ESC there can end another terminal's bracketed paste.
    static func sanitiseClipboardText(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        // The flag and tags kept so far, as the grid judges a cluster.
        var flag: [UInt32] = []
        for scalar in text.unicodeScalars {
            let value = scalar.value
            switch value {
            case 0x09, 0x0A, 0x0D: break
            case 0x00..<0x20, 0x7F...0x9F: continue
            default:
                if ConcealingScalars.isTag(value) {
                    guard ConcealingScalars.continuesFlag(flag, with: value) else { continue }
                } else if ConcealingScalars.contains(value) {
                    continue
                }
            }
            if ConcealingScalars.isTag(value) {
                flag.append(value)
            } else {
                flag = value == ConcealingScalars.flagBase ? [value] : []
            }
            scalars.append(scalar)
        }
        return String(scalars)
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
        // Also the names this machine had when the session began: a shell
        // fixes `$HOST` at startup, while the kernel's hostname follows the
        // network (DHCP, reverse DNS) when no HostName is set.
        if Self.isLocalHost(host, localNames: Self.localHostnames().union(state.hostnamesAtStart)) {
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
