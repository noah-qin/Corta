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

/// Bounded, untrusted text. The app owns the notification's actual title.
public struct DesktopNotification: Sendable, Equatable {
    public enum Occasion: String, Sendable { case always, unfocused, invisible }
    public var id: String = ""
    public var title: String = ""
    public var body: String = ""
    public var occasion: Occasion = .invisible
    public var urgency = 1
    public var focus = true
    public var expiryMilliseconds = -1
    public var sound = false
    public var close = false
    public init() {}
}

/// One coalesced event per pane; at most eight incomplete kitty messages,
/// each <= 4 KiB total, including chunked input. Reset with the terminal.
struct ProgramSignals: Sendable {
    static let chunkLimit = 4096
    var statuses: [String: ProgramStatus] = [:]
    var tabMetadata: ProgramStatus?
    var progress: ProgramProgress?
    var notification: DesktopNotification?
    /// kitty `p=close` ids, apart from `notification`: closing one message
    /// must not overwrite another id's notice still waiting to be read.
    var closedIDs: [String] = []
    var blocked: ProgramStatus.Kind??
    var blockedID: String?
    var blockedEpisode = 0
    var chunks: [String: DesktopNotification] = [:]
    /// Oldest first, so a ninth incomplete message replaces the stalest one
    /// rather than shutting out every later notice.
    var chunkOrder: [String] = []
    var chunkBytes: [String: Int] = [:]

    mutating func status(_ payload: String) {
        let fields = Self.fields(payload)
        if let id = fields["id"], !ProgramText.validID(id) { return }
        let id = fields["id"] ?? ""
        if fields["state"] == "clear" {
            if fields["id"] == nil { statuses.removeAll() } else { statuses[id] = nil }
            if fields["id"] == nil || blockedID == id { blocked = nil; blockedID = nil }
            return
        }
        // `unknown` is Corta's fallback when no task state was reported,
        // not a state in the OSC 7501 sender's vocabulary.
        guard let raw = fields["state"], let state = ProgramStatus.State(rawValue: raw),
              state != .unknown else { return }
        if let kind = fields["kind"], ProgramStatus.Kind(rawValue: kind) == nil { return }
        guard id.isEmpty || statuses[id] != nil
            || statuses.keys.filter({ !$0.isEmpty }).count < ProgramStatus.maximumSubtasks else { return }
        let wasBlocked = statuses.values.contains { $0.state == .blocked }
        let kind = state == .blocked ? fields["kind"].flatMap(ProgramStatus.Kind.init(rawValue:)) : nil
        let title = fields["title"].flatMap { ProgramText.decoded($0, limit: 192) } ?? ""
        let message = fields["msg"].flatMap { ProgramText.decoded($0, limit: 2048) } ?? ""
        if state == .blocked, statuses[id]?.state != .blocked || statuses[id]?.kind != kind {
            blocked = .some(kind)
            blockedID = id
        } else if state != .blocked, blockedID == id {
            blocked = nil; blockedID = nil
        }
        if state == .blocked && !wasBlocked { blockedEpisode += 1 }
        statuses[id] = ProgramStatus(state: state, kind: kind,
            app: ProgramText.clean(fields["app"] ?? "", limit: 80), title: title, message: message,
            progress: fields["progress"].flatMap(Int.init).map { min(100, max(0, $0)) })
    }

    /// A shell boundary ends the program's lifetime even when it could not
    /// send clear (SIGKILL, crash). A clean exit alone never proves completion.
    mutating func endCommand(exitStatus: Int?) {
        let result = statuses.values.max { $0.urgency < $1.urgency }
        beginCommand()
        guard var result else { return }
        if exitStatus == 130 { result.state = .idle }
        else if let exitStatus, exitStatus != 0 { result.state = .error }
        else if result.state != .done && result.state != .error { result.state = .idle }
        result.kind = nil; result.progress = nil
        statuses[""] = result
    }

    mutating func beginCommand() {
        statuses.removeAll(); progress = nil; tabMetadata = nil
        blocked = nil; blockedID = nil
    }

    static func fields(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for field in text.split(separator: ":") {
            let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { result[String(parts[0])] = String(parts[1]) }
        }
        return result
    }

    mutating func iterm(_ payload: String) {
        let parts = payload.split(separator: ";", omittingEmptySubsequences: false)
        if let first = parts.first, let code = Int(first), (1...12).contains(code) {
            // All numeric ConEmu commands are inert except progress. In
            // particular GuiMacro (6) and process execution (7) do nothing.
            guard code == 4, parts.count >= 2, let number = Int(parts[1]) else { return }
            if number == 0 { progress = nil; return }
            guard let state = ProgramProgress.State(rawValue: number) else { return }
            let value = parts.count > 2 ? Int(parts[2]).map { min(100, max(0, $0)) } : nil
            progress = ProgramProgress(state: state, value: state == .indeterminate ? nil : value)
            return
        }
        var notice = DesktopNotification()
        notice.body = ProgramText.clean(payload, limit: 2048)
        if !notice.body.isEmpty { notification = notice }
    }

    mutating func kitty(_ payload: String) -> [UInt8] {
        guard let separator = payload.firstIndex(of: ";") else { return [] }
        let fields = Self.fields(String(payload[..<separator]))
        let id = fields["i"] ?? ""
        guard fields["i"] == nil || ProgramText.validID(id) else { return [] }
        let type = fields["p"] ?? "title"
        if type == "?" {
            // The spec requires the query id for multiplexer routing. This
            // is the sole echoed field and has passed the ASCII allowlist.
            let identity = id.isEmpty ? "" : "i=\(id):"
            return Array("\u{1B}]99;\(identity)p=?;a=focus:o=always,unfocused,invisible:p=title,body,close,?:s=system,silent:w=1\u{1B}\\".utf8)
        }
        guard ["title", "body", "close"].contains(type) else { return [] }
        if type == "close" {
            guard !id.isEmpty else { return [] }
            chunks[id] = nil; chunkBytes[id] = nil
            if notification?.id == id { notification = nil }
            if !closedIDs.contains(id) {
                if closedIDs.count == 8 { closedIDs.removeFirst() }
                closedIDs.append(id)
            }
            return []
        }
        if chunks[id] == nil {
            chunkOrder.removeAll { chunks[$0] == nil }
            if chunks.count >= 8, !chunkOrder.isEmpty {
                let oldest = chunkOrder.removeFirst()
                chunks[oldest] = nil; chunkBytes[oldest] = nil
            }
        }
        if chunkBytes[id] == -1 {
            if fields["d"] != "0" { chunks[id] = nil; chunkBytes[id] = nil }
            return []
        }
        let raw = String(payload[payload.index(after: separator)...])
        let total = (chunkBytes[id] ?? 0) + raw.utf8.count
        guard total <= Self.chunkLimit else {
            if fields["d"] == "0", !chunkOrder.contains(id) { chunkOrder.append(id) }
            chunks[id] = fields["d"] == "0" ? DesktopNotification() : nil
            chunkBytes[id] = fields["d"] == "0" ? -1 : nil
            return []
        }
        let text: String
        if fields["e"] == "1" {
            guard let decoded = ProgramText.decoded(raw, limit: 3072) else {
                chunks[id] = nil; chunkBytes[id] = nil; return []
            }
            text = decoded
        } else { text = ProgramText.clean(raw, limit: 3072) }
        var notice = chunks[id] ?? DesktopNotification()
        notice.id = id
        if type == "title" { notice.title += text } else { notice.body += text }
        notice.title = ProgramText.clean(notice.title, limit: 192)
        notice.body = ProgramText.clean(notice.body, limit: 2048)
        if let occasion = fields["o"].flatMap(DesktopNotification.Occasion.init(rawValue:)) { notice.occasion = occasion }
        else if chunks[id] == nil { notice.occasion = .always }
        if let urgency = fields["u"].flatMap(Int.init) { notice.urgency = min(2, max(0, urgency)) }
        if let actions = fields["a"] { notice.focus = actions.split(separator: ",").contains("focus") }
        if let expiry = fields["w"].flatMap(Int.init) { notice.expiryMilliseconds = min(86_400_000, max(-1, expiry)) }
        // s is base64 in the kitty protocol.
        if let rawSound = fields["s"] {
            let sound = ["silent", "system"].contains(rawSound)
                ? rawSound : ProgramText.decoded(rawSound, limit: 32)
            notice.sound = sound == "system"
        }
        if fields["d"] == "0" {
            if !chunkOrder.contains(id) { chunkOrder.append(id) }
            chunks[id] = notice; chunkBytes[id] = total
        } else {
            chunks[id] = nil; chunkBytes[id] = nil
            if !notice.title.isEmpty || !notice.body.isEmpty { notification = notice }
        }
        return []
    }

    mutating func tabStatus(_ payload: String) {
        // Claude's dormant protocol uses semicolon-separated, backslash-
        // escaped fields. indicator and status-color are RGB colours.
        var fields: [String: String] = [:]
        var field = ""
        var escaped = false
        func store(_ field: String) {
            let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
        }
        for character in payload {
            if escaped { field.append(character); escaped = false }
            else if character == "\\" { escaped = true }
            else if character == ";" { store(field); field = "" }
            else { field.append(character) }
        }
        store(field)
        let previous = tabMetadata
        let title = ProgramText.clean(fields["status"] ?? previous?.title ?? "", limit: 192)
        let color = ProgramText.clean(fields["indicator"] ?? previous?.color ?? "", limit: 32)
        if title.isEmpty && color.isEmpty { tabMetadata = nil; return }
        let statusColor = ProgramText.clean(fields["status-color"] ?? previous?.statusColor ?? "", limit: 32)
        tabMetadata = ProgramStatus(state: .unknown, title: title, color: color, statusColor: statusColor)
    }
}
