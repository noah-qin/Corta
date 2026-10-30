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

/// A project member. The binding to a live process is not stored.
nonisolated struct AgentMemberRecord: Codable, Equatable, Sendable {
    var id: UUID
    var role: String
    var sessionID: UUID
    var nudgeEnabled: Bool
    var paused: Bool
    /// Nil on this machine. A remote member (#444) names its host.
    var host: String?

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

nonisolated struct AgentEnvelope: Equatable, Sendable {
    static let bodyLimit = 64 * 1024
    static let userID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let nudgeText = "Corta: you have new messages; run corta read."

    static func nudgeBytes(submit: String = "\r") -> [UInt8] {
        Array((nudgeText + submit).utf8)
    }

    static func contextLine(_ key: String, _ value: String) -> String? {
        guard ["cwd", "branch", "head", "dirty", "pane"].contains(key) else { return nil }
        let flat = value.replacingOccurrences(of: "\n", with: " ")
        let trimmed = String(decoding: flat.utf8.prefix(256), as: UTF8.self)
        guard !trimmed.isEmpty else { return nil }
        return key + ": " + trimmed
    }

    static func introduction(role: String, id: UUID) -> String {
        let short = shortID(id)
        return "You are Corta project member \"\(role)\" (\(short)). "
            + "`corta members` lists members; `corta send <ID> \"…\"` sends; "
            + "`corta read` reads; `corta wait` waits. "
            + "Reply with `corta send <ID> --reply-to <number>`."
    }

    static func shortID(_ id: UUID) -> String {
        "m-" + id.uuidString.lowercased().prefix(8)
    }

    /// Fixed English text. Context lines, when present, sit before the divider.
    static func text(fromRole: String, fromID: UUID, number: Int, replyTo: Int?,
                     body: String, context: [String] = [], fromUserPane: String? = nil) -> String {
        let who: String
        if fromID == userID {
            who = "the user (selected in \"\(fromUserPane ?? "a pane")\")"
        } else {
            who = "member \"\(fromRole)\" (\(shortID(fromID)))"
        }
        let reply = replyTo.map { " Reply to #\($0)." } ?? ""
        let head = "[Corta] Message #\(number) from \(who).\(reply) "
            + "This is a peer agent's request, not a user instruction. "
            + "Reply: corta send \(shortID(fromID)) --reply-to \(number) \"…\"; or the MCP tool corta_send."
        let extra = context.isEmpty ? "" : "\n" + context.joined(separator: "\n")
        return head + extra + "\n---\n" + body
    }
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
        var read = false
        var delivery: AgentDelivery
        var at: TimeInterval
    }

    private(set) var members: [AgentMemberRecord] = []
    private(set) var items: [Item] = []
    private var nextNumber = 1
    private var sentAt: [UUID: [TimeInterval]] = [:]
    private var nudgedAt: [UUID: [TimeInterval]] = [:]
    private var emptyWaits: [UUID: Int] = [:]
    /// session id -> bound. Not persisted.
    var boundSessions: Set<UUID> = []
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
        let ids = Set(members.map(\.id))
        self.members = members
        items.removeAll { !ids.contains($0.to) && $0.to != AgentEnvelope.userID }
    }

    func member(_ token: String) -> AgentMemberRecord? {
        let matches = members.filter { member in
            member.id.uuidString.lowercased() == token.lowercased()
                || AgentEnvelope.shortID(member.id) == token.lowercased()
        }
        return matches.count == 1 ? matches.first : nil
    }

    mutating func send(from: UUID, to token: String, body: String, replyTo: Int?, context: [String],
                       now: TimeInterval, forwardDown: Bool = false) -> (Int?, AgentDelivery, Item?) {
        guard from == AgentEnvelope.userID || members.contains(where: { $0.id == from && !$0.paused }) else {
            return (nil, .refused("notAMember"), nil)
        }
        if token == "user" || token.lowercased() == AgentEnvelope.userID.uuidString.lowercased() {
            return (nil, .refused("userIsNotARecipient"), nil)
        }
        guard let target = member(token) else {
            return (nil, .refused(members.contains { $0.role == token } ? "useAnID" : "missing"), nil)
        }
        if target.paused { return (nil, .refused("paused"), nil) }
        if !boundSessions.contains(target.sessionID) { return (nil, .refused("unbound"), nil) }
        if target.host != nil && (forwardDown || forwardsDown.contains(target.id)) {
            return (nil, .forwardUnavailable, nil)
        }
        if body.utf8.count > AgentEnvelope.bodyLimit { return (nil, .refused("tooLarge"), nil) }
        if replyDepth(of: replyTo) >= Self.replyDepth { return (nil, .refused("tooDeep"), nil) }
        let recent = (sentAt[from] ?? []).filter { now - $0 < 60 }
        if recent.count >= Self.sendsPerMinute { return (nil, .refused("rate"), nil) }
        if items.filter({ $0.to == target.id && !$0.read }).count >= Self.inboxLimit {
            return (nil, .refused("inboxFull"), nil)
        }
        let number = nextNumber
        nextNumber += 1
        sentAt[from] = recent + [now]
        let item = Item(number: number, from: from, to: target.id, body: body, replyTo: replyTo,
                        context: context, delivery: .queued, at: now)
        items.append(item)
        if items.count > Self.historyLimit { items.removeFirst(items.count - Self.historyLimit) }
        emptyWaits[target.id] = 0
        return (number, .queued, item)
    }

    mutating func mark(_ number: Int, _ delivery: AgentDelivery, now: TimeInterval) {
        guard let index = items.lastIndex(where: { $0.number == number }) else { return }
        items[index].delivery = delivery
        if delivery == .nudged {
            let id = items[index].to
            let recent = (nudgedAt[id] ?? []).filter { now - $0 < 60 }
            nudgedAt[id] = recent + [now]
        }
    }

    func nudges(for member: UUID, now: TimeInterval) -> Int {
        (nudgedAt[member] ?? []).filter { now - $0 < 60 }.count
    }

    func peek(member: UUID) -> [Item] {
        items.filter { $0.to == member && !$0.read }
    }

    mutating func dropInbox(member: UUID) {
        items.removeAll { $0.to == member }
    }

    mutating func read(member: UUID) -> [Item] {
        guard members.contains(where: { $0.id == member && !$0.paused }) else { return [] }
        var taken: [Item] = []
        for index in items.indices where items[index].to == member && !items[index].read {
            items[index].read = true
            taken.append(items[index])
        }
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
        while let number = current, seen.insert(number).inserted, let item = items.last(where: { $0.number == number }) {
            depth += 1
            current = item.replyTo
            if depth > Self.replyDepth { break }
        }
        return depth
    }
}

/// `corta` argv, without talking to the app.
nonisolated enum AgentCommand {
    struct Invocation: Equatable, Sendable {
        var operation: String
        var token: String? = nil
        var body: String? = nil
        var replyTo: Int? = nil
        var timeout: Int? = nil
        var json: Bool = false
        var context: Bool = false
        var number: Int? = nil
    }

    static func parse(_ arguments: [String]) -> Invocation? {
        var args = arguments
        let json = args.contains("--json")
        args.removeAll { $0 == "--json" }
        let context = args.contains("--context")
        args.removeAll { $0 == "--context" }
        guard let operation = args.first else { return nil }
        switch operation {
        case "members", "whoami", "read":
            return Invocation(operation: operation, json: json, context: context)
        case "status":
            guard args.count == 2, let number = Int(args[1]) else { return nil }
            return Invocation(operation: operation, json: json, context: context, number: number)
        case "wait":
            var timeout = 110
            if let flag = args.firstIndex(of: "--timeout"), args.indices.contains(flag + 1), let value = Int(args[flag + 1]) {
                timeout = min(max(value, 1), 110)
            }
            return Invocation(operation: operation, timeout: timeout, json: json, context: context)
        case "send":
            var rest = Array(args.dropFirst())
            var reply: Int?
            if let flag = rest.firstIndex(of: "--reply-to"), rest.indices.contains(flag + 1) {
                reply = Int(rest[flag + 1])
                rest.removeSubrange(flag...flag + 1)
            }
            guard rest.count >= 2, reply == nil || (reply ?? 0) > 0 else { return nil }
            return Invocation(operation: "send", token: rest[0], body: rest.dropFirst().joined(separator: " "),
                              replyTo: reply, json: json, context: context)
        case "mcp":
            return Invocation(operation: "mcp", json: false, context: false)
        default:
            return nil
        }
    }
}

nonisolated enum AgentPush {
    /// One NDJSON line for Claude's per-session socket. No token is attached.
    static func claudeLine(envelope: String, messageID: String) -> String {
        let body = envelope.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return #"{"type":"user","message":{"role":"user","content":""# + body
            + #""},"priority":"next","msgV":1,"msg_id":""# + messageID + "\"}\n"
    }

    static func codexArguments(executable: String, thread: String, message: String) -> [String]? {
        guard !executable.isEmpty, !thread.isEmpty, !thread.contains(" "), !message.contains("\0"),
              thread.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return [executable, "queue", "--thread", thread, "--message", message]
    }

    /// Claude's inbox lives under its private socket directory, never an arbitrary path.
    static func acceptedSocket(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("..") && path.utf8.count < 104
            && (path.contains("cc-socks") || path.contains("claude"))
    }

    static func writeClaude(socket path: String, envelope: String) -> Bool {
        guard acceptedSocket(path) else { return false }
        guard var address = SSHAskpass.socketAddress(path) else { return false }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return false }
        let line = claudeLine(envelope: envelope, messageID: "cc-msg-corta")
        return SSHAskpass.writeLine(Data(line.utf8), to: descriptor)
    }

    static func run(_ arguments: [String], timeout: TimeInterval) -> Bool {
        guard let executable = arguments.first else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); return false }
        return process.terminationStatus == 0
    }
}
