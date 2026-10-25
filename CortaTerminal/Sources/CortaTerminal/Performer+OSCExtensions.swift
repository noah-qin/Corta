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

public enum ProgramAttention: Sendable { case once, continuous, cancel }

/// Drained atomically; the app acknowledges a kitty write only after its
/// permission check and a successful pasteboard write.
public struct ClipboardCopyRequest: Sendable {
    public let text: String
    public let acknowledgement: [UInt8]
}

extension Performer {
    mutating func vscodeIntegration(_ payload: ArraySlice<UInt8>) {
        if payload.starts(with: Array("P;Cwd=".utf8)) {
            if let path = Self.vscodeProperty(payload.dropFirst(6)) { reportedDirectory(path) }
        } else if let first = payload.first, [65, 66, 67, 68].contains(first),
            payload.count == 1 || payload.dropFirst().first == 59 {
            shellIntegration(payload)
        }
        // E command text/nonce and other P properties have no consumer.
    }

    private static func vscodeProperty(_ bytes: ArraySlice<UInt8>) -> String? {
        let input = Array(bytes)
        var output: [UInt8] = []
        var i = 0
        while i < input.count {
            if input[i] != 92 { output.append(input[i]); i += 1; continue }
            guard i + 1 < input.count else { return nil }
            if input[i + 1] == 92 { output.append(92); i += 2; continue }
            guard i + 3 < input.count, input[i + 1] == 120,
                let value = UInt8(String(decoding: input[(i + 2)...(i + 3)], as: UTF8.self), radix: 16) else { return nil }
            output.append(value); i += 4
        }
        return String(bytes: output, encoding: .utf8)
    }

    /// Hostless reports cannot turn a remote path into a local spawn target.
    mutating func reportedDirectory(_ path: String) {
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return }
        if let remote = state.remoteContext {
            state.remoteContext = RemoteContext(host: remote.host, directory: path,
                provenance: remote.provenance, reportedAt: Date())
        } else { state.workingDirectory = path }
    }

    mutating func itermExtension(_ payload: ArraySlice<UInt8>) {
        for key in ["File", "MultipartFile", "FilePart"] {
            let prefix = Array((key + "=").utf8)
            if payload.starts(with: prefix) {
                receiveITermImage(key: key, value: payload.dropFirst(prefix.count))
                return
            }
        }
        if payload.elementsEqual(Array("FileEnd".utf8)) {
            receiveITermImage(key: "FileEnd", value: [])
            return
        }
        let text = String(decoding: payload, as: UTF8.self)
        let pair = text.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let key = String(pair[0])
        let value = pair.count == 2 ? String(pair[1]) : ""
        switch key {
        case "CurrentDir": reportedDirectory(value)
        case "RemoteHost":
            let host = String(value.split(separator: "@", omittingEmptySubsequences: false).last ?? "")
            guard !host.isEmpty, host.utf8.count <= 255,
                host.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,58].contains($0) }) else { return }
            if Self.isLocalHost(host, localNames: Self.localHostnames().union(state.hostnamesAtStart)) {
                state.remoteContext = nil
            } else {
                state.remoteContext = RemoteContext(host: Self.normalizeHostname(host), directory: "",
                    provenance: .osc7, reportedAt: Date())
            }
        case "SetMark":
            guard !grid.isAlternateScreenActive else { return }
            grid.setMark(.prompt, atAbsoluteRow: grid.absoluteRow(ofScreenRow: grid.cursor.row))
        case "ClearScrollback": grid.clearScrollback()
        case "CursorShape":
            switch value {
            case "0": grid.cursorStyle = .block
            case "1": grid.cursorStyle = .bar
            case "2": grid.cursorStyle = .underline
            default: return
            }
            grid.cursorStyleIsExplicit = true
        case "RequestAttention":
            switch value {
            case "yes": state.attention = .continuous
            case "once", "fireworks": state.attention = .once
            case "no": state.attention = .cancel
            default: break
            }
        case "ReportCellSize":
            let scale = grid.backingScale
            guard grid.cellPixelHeight > 0, grid.cellPixelWidth > 0, scale.isFinite, scale > 0 else { return }
            let report = "\u{1B}]1337;ReportCellSize=\(Double(grid.cellPixelHeight) / scale);\(Double(grid.cellPixelWidth) / scale);\(scale)\u{1B}\\"
            state.outputBuffer += Array(report.utf8)
        case "Copy":
            guard value.hasPrefix(":") else { return }
            setClipboard(Array(("c;" + value.dropFirst()).utf8)[...])
        case "SetUserVar", "ShellIntegrationVersion", "HighlightCursorLine", "UnicodeVersion",
            "SetKeyLabel", "PushKeyLabels", "PopKeyLabels", "ClearCapturedOutput": break
        case "StealFocus", "SetProfile", "SetBadgeFormat", "ReportVariable", "Custom": break
        default: break
        }
    }

    /// OSC 5522 is a transaction: publish once at the terminator. This text
    /// subset deliberately keeps OSC 52's smaller cap rather than advertising
    /// the full protocol's 64 MiB minimum or MIME/paste-event support.
    mutating func extendedClipboard(_ payload: ArraySlice<UInt8>) {
        let parts = payload.split(separator: 59, maxSplits: 1, omittingEmptySubsequences: false)
        let metadata = ProgramSignals.fields(String(decoding: parts[0], as: UTF8.self))
        switch metadata["type"] {
        case "write":
            state.clipboardTransfer = metadata["loc"] == nil || metadata["loc"] == "clipboard" ? [] : nil
        case "wdata":
            guard state.clipboardTransfer != nil else { return }
            if metadata["mime"] == nil, parts.count == 1 {
                let base64 = state.clipboardTransfer!
                state.clipboardTransfer = nil
                guard base64.count % 4 == 0,
                    let bytes = Data(base64Encoded: Data(base64)) else { return }
                let text = Self.sanitiseClipboardText(String(decoding: bytes, as: UTF8.self))
                if !text.isEmpty {
                    state.pendingClipboardCopy = text
                    state.clipboardNeedsAcknowledgement = true
                }
                return
            }
            guard metadata["mime"] == "dGV4dC9wbGFpbg==", parts.count == 2,
                state.clipboardTransfer!.count + parts[1].count <= Parser.maxStringLength,
                parts[1].allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                    || (48...57).contains($0) || [43, 47, 61].contains($0) })
            else { state.clipboardTransfer = nil; return }
            state.clipboardTransfer!.append(contentsOf: parts[1])
        default:
            state.clipboardTransfer = nil // reads, aliases and non-text refused silently
        }
    }
}
