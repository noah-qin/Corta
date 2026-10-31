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

import Darwin
import Foundation

/// Names that can be members. Claude and Codex also keep conversation recovery.
nonisolated enum AgentProcessNames {
    static let builtIn: Set<String> = [
        "claude", "claude-code", "codex", "gemini", "kimi", "grok", "aider", "opencode",
    ]

    static func matches(_ name: String, configured: String) -> Bool {
        if builtIn.contains(name) { return true }
        return configured.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == name }
    }
}

/// A project member. The binding to a live process is not stored.
nonisolated struct AgentMemberRecord: Codable, Equatable, Sendable {
    var id: UUID
    var role: String
    var sessionID: UUID
    var nudgeEnabled: Bool
    var paused: Bool
    /// Nil on this machine. A remote member (#444) names its host.
    var host: String?
    var contextEnabled: Bool?
    var selectionContextEnabled: Bool?
    var codexThreadName: String?

    static func cleanRole(_ text: String) -> String? {
        let scalars = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != "\n" }
        let clean = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        guard (1...64).contains(clean.count) else { return nil }
        return clean
    }

    init(id: UUID = UUID(), role: String, sessionID: UUID, nudgeEnabled: Bool = true,
         paused: Bool = false, host: String? = nil) {
        self.id = id
        self.role = role
        self.sessionID = sessionID
        self.nudgeEnabled = nudgeEnabled
        self.paused = paused
        self.host = host
    }
}

/// What Corta itself observed about a delivery. Not "the model understood it".
nonisolated enum AgentDelivery: Equatable, Sendable {
    case queued
    case pushed
    case nudged
    case pushFailed(String)
    case refused(String)
    case forwardUnavailable
    case giveUp
}

/// All six must pass. A denial writes nothing.
nonisolated struct AgentNudgeGate: Equatable, Sendable {
    var enabled = false
    var foregroundIsAgent = false
    var idle = false
    var userIdle = false
    var composing = false
    var bracketedPaste = false
    var nudgesThisMinute = 0

    var denial: String? {
        if !enabled { return "nudgeOff" }
        if !foregroundIsAgent { return "notForeground" }
        if !idle { return "busy" }
        if !userIdle || composing { return "userTyping" }
        if bracketedPaste { return "bracketedPaste" }
        if nudgesThisMinute >= 3 { return "nudgeRate" }
        return nil
    }

    /// The only bytes a nudge may write. `body` and `role` are ignored on purpose.
    static func bytes(gate: AgentNudgeGate, body: String, role: String) -> [UInt8]? {
        _ = (body, role)
        guard gate.denial == nil else { return nil }
        return AgentEnvelope.nudgeBytes()
    }
}

nonisolated struct AgentBus: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        var number: Int
        var from: UUID
        var to: UUID
        var body: String
        var replyTo: Int?
        var context: [String]
        var userPane: String?
        var events: [String] = []
        var read = false
        var delivery: AgentDelivery
        var at: TimeInterval
    }

    var commandPath = "corta"
    private(set) var members: [AgentMemberRecord] = []
    private(set) var items: [Item] = []
    private var inboxes: [UUID: [Item]] = [:]
    private var nextNumber = 1
    private var sentAt: [UUID: [TimeInterval]] = [:]
    private var nudgedAt: [UUID: [TimeInterval]] = [:]
    private var emptyWaits: [UUID: Int] = [:]
    /// session id -> bound. Not persisted.
    var boundSessions: Set<UUID> = []
    var memberProjects: [UUID: String] = [:]
    /// Remote members whose forward is down.
    var forwardsDown: Set<UUID> = []

    static let inboxLimit = 100
    static let historyLimit = 500
    static let sendsPerMinute = 10
    static let replyDepth = 20
    static let emptyWaitLimit = 20

    mutating func setHost(_ id: UUID, _ host: String?) {
        guard let index = members.firstIndex(where: { $0.id == id }) else { return }
        members[index].host = host
    }

    mutating func replaceMembers(_ members: [AgentMemberRecord]) {
        let ids = Set(members.filter { !$0.paused }.map(\.id))
        self.members = members
        inboxes = inboxes.filter { ids.contains($0.key) }
        sentAt = sentAt.filter { ids.contains($0.key) || $0.key == AgentEnvelope.userID }
        nudgedAt = nudgedAt.filter { ids.contains($0.key) }
        emptyWaits = emptyWaits.filter { ids.contains($0.key) }
        items.removeAll { !ids.contains($0.to) && $0.to != AgentEnvelope.userID }
    }

    func member(_ token: String) -> AgentMemberRecord? {
        let matches = members.filter { member in
            member.id.uuidString.lowercased() == token.lowercased()
                || AgentEnvelope.shortID(member.id) == token.lowercased()
        }
        return matches.count == 1 ? matches.first : nil
    }

    struct SendResult {
        let number: Int?
        let delivery: AgentDelivery
        let item: Item?
    }

    private func unavailable(_ target: AgentMemberRecord, from: UUID, forwardDown: Bool) -> AgentDelivery? {
        if target.paused { return .refused("paused") }
        if let project = memberProjects[from], memberProjects[target.id] != project {
            return .refused("differentProject")
        }
        if target.host == nil && !boundSessions.contains(target.sessionID) { return .refused("unbound") }
        if target.host != nil && (forwardDown || forwardsDown.contains(target.id)) { return .forwardUnavailable }
        return nil
    }

    mutating func send(from: UUID, to token: String, body: String, replyTo: Int? = nil, context: [String] = [],
                       now: TimeInterval, forwardDown: Bool = false) -> SendResult {
        guard from == AgentEnvelope.userID || members.contains(where: { $0.id == from && !$0.paused }) else {
            return SendResult(number: nil, delivery: .refused("notAMember"), item: nil)
        }
        if token == "user" || token.lowercased() == AgentEnvelope.userID.uuidString.lowercased() {
            return SendResult(number: nil, delivery: .refused("userIsNotARecipient"), item: nil)
        }
        guard let target = member(token) else {
            return SendResult(number: nil,
                delivery: .refused(members.contains { $0.role == token } ? "useAnID" : "missing"), item: nil)
        }
        if let reason = unavailable(target, from: from, forwardDown: forwardDown) {
            return SendResult(number: nil, delivery: reason, item: nil)
        }
        if body.utf8.count > AgentEnvelope.bodyLimit { return SendResult(number: nil,
            delivery: .refused("tooLarge"), item: nil) }
        if replyDepth(of: replyTo) >= Self.replyDepth { return SendResult(number: nil,
            delivery: .refused("tooDeep"), item: nil) }
        let recent = (sentAt[from] ?? []).filter { now - $0 < 60 }
        if recent.count >= Self.sendsPerMinute { return SendResult(number: nil, delivery: .refused("rate"), item: nil) }
        if (inboxes[target.id] ?? []).count >= Self.inboxLimit {
            return SendResult(number: nil, delivery: .refused("inboxFull"), item: nil)
        }
        let sender = members.first { $0.id == from }?.role ?? "user"
        let overhead = AgentEnvelope.text(fromRole: sender, fromID: from, number: nextNumber,
                                         replyTo: replyTo, body: "", context: context, command: commandPath).utf8.count
        if body.utf8.count > AgentEnvelope.bodyLimit - overhead { return SendResult(number: nil,
            delivery: .refused("tooLarge"), item: nil) }
        let number = nextNumber
        nextNumber += 1
        sentAt[from] = recent + [now]
        let item = Item(number: number, from: from, to: target.id, body: body, replyTo: replyTo,
                        context: context, delivery: .queued, at: now)
        inboxes[target.id, default: []].append(item)
        items.append(item)
        if items.count > Self.historyLimit { items.removeFirst(items.count - Self.historyLimit) }
        emptyWaits[target.id] = 0
        return SendResult(number: number, delivery: .queued, item: item)
    }

    mutating func mark(_ number: Int, _ delivery: AgentDelivery, now: TimeInterval) {
        let index = items.lastIndex { $0.number == number }
        let target = index.map { items[$0].to }
            ?? inboxes.first { $0.value.contains { $0.number == number } }?.key
        if let target, let mail = inboxes[target]?.firstIndex(where: { $0.number == number }) {
            inboxes[target]?[mail].delivery = delivery
        }
        if let index {
            items[index].delivery = delivery
            items[index].events.append(String(describing: delivery))
            if items[index].events.count > 32 { items[index].events.removeFirst() }
        }
        if delivery == .nudged, let target {
            let recent = (nudgedAt[target] ?? []).filter { now - $0 < 60 }
            nudgedAt[target] = recent + [now]
        }
    }

    func nudges(for member: UUID, now: TimeInterval) -> Int {
        (nudgedAt[member] ?? []).filter { now - $0 < 60 }.count
    }

    func peek(member: UUID) -> [Item] {
        inboxes[member] ?? []
    }

    mutating func dropInbox(member: UUID) {
        inboxes[member] = nil
        items.removeAll { $0.to == member }
    }

    mutating func read(member: UUID, since: Int? = nil) -> [Item] {
        guard members.contains(where: { $0.id == member && !$0.paused }) else { return [] }
        var taken: [Item] = []
        var kept: [Item] = []
        var bytes = 0
        for var item in inboxes[member] ?? [] {
            let size = item.body.utf8.count + 4096
            guard since == nil || item.number > (since ?? 0), bytes + size <= 256 * 1024 else {
                kept.append(item)
                continue
            }
            bytes += size
            item.read = true
            taken.append(item)
            if let index = items.firstIndex(where: { $0.number == item.number }) { items[index].read = true }
        }
        inboxes[member] = kept
        return taken
    }

    mutating func noteEmptyWait(member: UUID) -> AgentDelivery? {
        emptyWaits[member, default: 0] += 1
        return emptyWaits[member, default: 0] >= Self.emptyWaitLimit ? .giveUp : nil
    }

    func status(number: Int) -> Item? { items.last { $0.number == number } }

    private func replyDepth(of replyTo: Int?) -> Int {
        var depth = 0
        var current = replyTo
        var seen = Set<Int>()
        while let number = current, seen.insert(number).inserted,
            let item = items.last(where: { $0.number == number }) {
            depth += 1
            current = item.replyTo
            if depth > Self.replyDepth { break }
        }
        return depth
    }
}

extension AgentBus {
    mutating func note(_ number: Int, event: String) {
        guard let index = items.firstIndex(where: { $0.number == number }) else { return }
        if items[index].events.last != event { items[index].events.append(event) }
        if items[index].events.count > 32 { items[index].events.removeFirst() }
    }

    mutating func setUserPane(_ number: Int, _ title: String) {
        guard let index = items.firstIndex(where: { $0.number == number }) else { return }
        items[index].userPane = AgentEnvelope.prefixUTF8(title, limit: 256)
        if let mail = inboxes[items[index].to]?.firstIndex(where: { $0.number == number }) {
            inboxes[items[index].to]?[mail].userPane = items[index].userPane
        }
    }
}
