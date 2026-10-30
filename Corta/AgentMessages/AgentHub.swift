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

/// One JSON line from `corta` or from the remote `nc` client.
nonisolated struct AgentRequest: Codable, Equatable, Sendable {
    var op: String
    var to: String?
    var body: String?
    var replyTo: Int?
    var timeout: Int?
    var number: Int?
    var context: Bool?
    var pane: String?
    var token: String?
}

nonisolated struct AgentReply: Codable, Equatable, Sendable {
    var ok: Bool
    var text: String
    var delivery: String?
}

/// What the pane can tell the waker without sharing the view.
struct AgentWakeSnapshot: Sendable {
    var kind: String?
    var claudeSocket: String?
    var codexExecutable: String?
    var codexThread: String?
    var gate: AgentNudgeGate
}

/// The in-app bus plus the socket `corta` connects to.
@MainActor
final class AgentHub {
    static let shared = AgentHub()

    private(set) var bus = AgentBus()
    /// Shell pid → Space session id.
    var shells: [pid_t: UUID] = [:]
    /// Remote token → member id. Not written to disk.
    var remoteTokens: [String: UUID] = [:]
    var remoteReady: Set<UUID> = []
    /// Filled by Space. Nil answers mean the session cannot be nudged.
    var snapshot: ((UUID) -> AgentWakeSnapshot?)?
    var writeNudge: ((UUID) -> Bool)?
    var contextLines: ((UUID) -> [String])?
    /// The pane's input revision, so a key during a nudge can be recorded.
    var inputRevision: ((UUID) -> UInt64?)?
    private var interrupted: Set<Int> = []

    private var source: DispatchSourceRead?
    private var listener: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "dev.noahqin.Corta.agent", qos: .utility)
    private(set) var socketPath: String?

    static func socketDirectory(development: Bool, uid: uid_t = getuid()) -> String {
        "/tmp/" + (development ? "corta-agent-dev-\(uid)" : "corta-agent-\(uid)")
    }

    func sync(members: [AgentMemberRecord], bound: Set<UUID>, shells: [pid_t: UUID]) {
        bus.replaceMembers(members)
        bus.boundSessions = bound
        bus.forwardsDown = Set(members.filter { $0.host != nil && !remoteReady.contains($0.id) }.map(\.id))
        self.shells = shells
    }

    func rememberRemote(token: String, member: UUID) {
        remoteTokens[token] = member
    }

    func markRemoteReady(_ member: UUID) {
        remoteReady.insert(member)
    }

    /// Start or stop with `agent-messages`. A second call refreshes the link.
    func apply(enabled: Bool, development: Bool, executable: String) {
        guard enabled else {
            stop()
            return
        }
        let directory = Self.socketDirectory(development: development)
        _ = AgentCommandLink.ensure(
            bin: URL(fileURLWithPath: directory).appendingPathComponent("bin"),
            executable: URL(fileURLWithPath: executable))
        if socketPath != nil { return }
        let path = directory + "/agent.sock"
        guard let listener = Self.listen(directory: directory, path: path) else { return }
        self.listener = listener
        socketPath = path
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.accept() }
        source.setCancelHandler { close(listener) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
        if listener >= 0 { close(listener); listener = -1 }
        if let socketPath { unlink(socketPath) }
        socketPath = nil
    }

    /// Called on the accept queue or from a test.
    func exchange(_ request: AgentRequest, caller: UUID?) -> AgentReply {
        let reply = onMain { self.handle(request, caller: caller) }
        return reply
    }

    private func handle(_ request: AgentRequest, caller: UUID?) -> AgentReply {
        let now = Date().timeIntervalSinceReferenceDate
        switch request.op {
        case "members":
            let lines = bus.members.map { member in
                let level = member.host != nil ? "remote" : (bus.boundSessions.contains(member.sessionID) ? "nudge" : "unbound")
                return "\(AgentEnvelope.shortID(member.id)) \(member.role) \(level)"
                    + (member.paused ? " paused" : "")
            }
            return AgentReply(ok: true, text: lines.joined(separator: "\n"), delivery: nil)
        case "whoami":
            guard let caller, let member = bus.members.first(where: { $0.id == caller }) else {
                return AgentReply(ok: false, text: "refused(notAMember)", delivery: "refused")
            }
            return AgentReply(ok: true, text: "\(AgentEnvelope.shortID(member.id)) \(member.role)", delivery: nil)
        case "send":
            guard let caller else { return AgentReply(ok: false, text: "refused(notAMember)", delivery: "refused") }
            guard let to = request.to, let body = request.body else {
                return AgentReply(ok: false, text: "refused(missing)", delivery: "refused")
            }
            var context: [String] = []
            if request.context == true, let target = bus.member(caller.uuidString) {
                context = contextLines?(target.sessionID) ?? []
            }
            let sent = bus.send(from: caller, to: to, body: body, replyTo: request.replyTo,
                               context: context, now: now)
            guard let number = sent.0, let item = sent.2 else {
                return AgentReply(ok: false, text: String(describing: sent.1), delivery: deliveryName(sent.1))
            }
            let delivery = wake(item)
            bus.mark(number, delivery, now: now)
            return AgentReply(ok: true, text: "#\(number) \(deliveryName(delivery))", delivery: deliveryName(delivery))
        case "read":
            guard let caller else { return AgentReply(ok: false, text: "refused(notAMember)", delivery: "refused") }
            let items = bus.read(member: caller)
            let text = items.map { item in
                AgentEnvelope.text(fromRole: role(of: item.from), fromID: item.from, number: item.number,
                                   replyTo: item.replyTo, body: item.body, context: item.context)
            }.joined(separator: "\n\n")
            return AgentReply(ok: true, text: text, delivery: nil)
        case "wait":
            guard let caller else { return AgentReply(ok: false, text: "refused(notAMember)", delivery: "refused") }
            let pending = bus.read(member: caller)
            if pending.isEmpty, let giveUp = bus.noteEmptyWait(member: caller) {
                return AgentReply(ok: false, text: "giveUp", delivery: deliveryName(giveUp))
            }
            let text = pending.map { item in
                AgentEnvelope.text(fromRole: role(of: item.from), fromID: item.from, number: item.number,
                                   replyTo: item.replyTo, body: item.body, context: item.context)
            }.joined(separator: "\n\n")
            return AgentReply(ok: true, text: text, delivery: nil)
        case "status":
            guard let number = request.number, let item = bus.status(number: number) else {
                return AgentReply(ok: false, text: "refused(missing)", delivery: "refused")
            }
            let read = item.read ? " read" : ""
            return AgentReply(ok: true, text: "\(deliveryName(item.delivery))\(read)", delivery: deliveryName(item.delivery))
        default:
            return AgentReply(ok: false, text: "refused(missing)", delivery: "refused")
        }
    }

    private func role(of id: UUID) -> String {
        if id == AgentEnvelope.userID { return "user" }
        return bus.members.first { $0.id == id }?.role ?? "member"
    }

    private func wake(_ item: AgentBus.Item) -> AgentDelivery {
        guard let member = bus.members.first(where: { $0.id == item.to }) else { return .queued }
        if member.host != nil { return bus.forwardsDown.contains(member.id) ? .forwardUnavailable : .queued }
        guard let shot = snapshot?(member.sessionID) else { return .queued }
        let text = envelope(item)
        var pushFailed = false
        if let path = shot.claudeSocket {
            if AgentPush.writeClaude(socket: path, envelope: text) { return .pushed }
            pushFailed = true
        }
        if let executable = shot.codexExecutable, let thread = shot.codexThread,
           let argv = AgentPush.codexArguments(executable: executable, thread: thread, message: text),
           AgentPush.run(argv, timeout: 10) {
            return .pushed
        } else if shot.codexExecutable != nil {
            pushFailed = true
        }
        guard AgentNudgeGate.bytes(gate: shot.gate, body: item.body, role: member.role) != nil else {
            return pushFailed ? .pushFailed("connect") : .queued
        }
        guard writeNudge?(member.sessionID) == true else {
            return pushFailed ? .pushFailed("connect") : .queued
        }
        let revision = inputRevision?(member.sessionID)
        let number = item.number
        let sessionID = member.sessionID
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
            guard let self, let revision, let now = self.inputRevision?(sessionID), now != revision else { return }
            self.interrupted.insert(number)
        }
        return .nudged
    }

    private func envelope(_ item: AgentBus.Item) -> String {
        AgentEnvelope.text(fromRole: role(of: item.from), fromID: item.from, number: item.number,
                           replyTo: item.replyTo, body: item.body, context: item.context)
    }

    func deliveryName(_ delivery: AgentDelivery) -> String {
        switch delivery {
        case .queued: return "queued"
        case .pushed: return "pushed"
        case .nudged: return "nudged"
        case .pushFailed(let reason): return "pushFailed(\(reason))"
        case .refused(let reason): return "refused(\(reason))"
        case .forwardUnavailable: return "forwardUnavailable"
        case .giveUp: return "giveUp"
        }
    }

    /// Walk parents to a registered shell. A claimed pane that disagrees is refused.
    func caller(pid: pid_t, claimedPane: String?) -> UUID? {
        var current = pid
        for _ in 0..<24 {
            if let session = shells[current] {
                if let claimedPane, claimedPane.lowercased() != session.uuidString.lowercased() { return nil }
                return bus.members.first { $0.sessionID == session }?.id
            }
            guard let parent = Self.parent(of: current), parent != current else { return nil }
            current = parent
        }
        return nil
    }

    func caller(token: String) -> UUID? { remoteTokens[token] }

    /// A person sending a selection. Wakes the receiver the same way `corta send` does.
    private var nudgedThrough: [UUID: Int] = [:]

    /// One nudge for unread mail when the gate newly allows it. Not a poll of the PTY.
    func nudgePending() {
        let now = Date().timeIntervalSinceReferenceDate
        for member in bus.members where !member.paused && member.host == nil {
            let unread = bus.peek(member: member.id)
            guard let newest = unread.map(\.number).max(), (nudgedThrough[member.id] ?? 0) < newest else { continue }
            guard let shot = snapshot?(member.sessionID),
                  AgentNudgeGate.bytes(gate: shot.gate, body: "", role: member.role) != nil,
                  writeNudge?(member.sessionID) == true else { continue }
            nudgedThrough[member.id] = newest
            bus.mark(newest, .nudged, now: now)
        }
    }

    func dropInbox(sessionID: UUID) {
        if let member = bus.members.first(where: { $0.sessionID == sessionID }) {
            bus.dropInbox(member: member.id)
        }
    }

    func introduction(sessionID: UUID) -> String? {
        guard let member = bus.members.first(where: { $0.sessionID == sessionID }) else { return nil }
        return AgentEnvelope.introduction(role: member.role, id: member.id)
    }

    func historyText(sessionID: UUID) -> String {
        guard let member = bus.members.first(where: { $0.sessionID == sessionID }) else { return "" }
        return bus.items.filter { $0.to == member.id || $0.from == member.id }.suffix(20).map { item in
            "#\(item.number) \(deliveryName(item.delivery))" + (item.read ? " read" : "")
                + (interrupted.contains(item.number) ? " nudgeInterrupted" : "")
        }.joined(separator: "\n")
    }

    func unreadText(sessionID: UUID) -> String {
        guard let member = bus.members.first(where: { $0.sessionID == sessionID }) else { return "" }
        return bus.peek(member: member.id).map { item in
            AgentEnvelope.text(fromRole: role(of: item.from), fromID: item.from, number: item.number,
                               replyTo: item.replyTo, body: item.body, context: item.context)
        }.joined(separator: "\n\n")
    }

    func deliverUser(to token: String, body: String, context: [String]) -> AgentDelivery {
        let now = Date().timeIntervalSinceReferenceDate
        let sent = bus.send(from: AgentEnvelope.userID, to: token, body: body, replyTo: nil, context: context, now: now)
        guard let number = sent.0, let item = sent.2 else { return sent.1 }
        let delivery = wake(item)
        bus.mark(number, delivery, now: now)
        return delivery
    }

    func wakeSnapshot(for sessionID: UUID) -> AgentWakeSnapshot? { snapshot?(sessionID) }

    private func onMain<T>(_ body: () -> T) -> T {
        if Thread.isMainThread { return body() }
        return DispatchQueue.main.sync(execute: body)
    }

    private func accept() {
        let client = Darwin.accept(listener, nil, nil)
        guard client >= 0 else { return }
        acceptQueue.async { [weak self] in
            defer { close(client) }
            guard let self, let line = SSHAskpass.readLine(from: client, limit: AgentEnvelope.bodyLimit + 4096),
                  let request = try? JSONDecoder().decode(AgentRequest.self, from: line) else { return }
            let caller: UUID? = self.onMain {
                if let token = request.token { return self.caller(token: token) }
                var pid: pid_t = 0
                var size = socklen_t(MemoryLayout<pid_t>.size)
                guard getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 else { return nil }
                return self.caller(pid: pid, claimedPane: request.pane)
            }
            let reply = self.exchange(request, caller: caller)
            if let data = try? JSONEncoder().encode(reply) { _ = SSHAskpass.writeLine(data, to: client) }
        }
    }

    private static func listen(directory: String, path: String) -> Int32? {
        mkdir(directory, 0o700)
        chmod(directory, 0o700)
        unlink(path)
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0, var address = SSHAskpass.socketAddress(path) else {
            if listener >= 0 { close(listener) }
            return nil
        }
        _ = fcntl(listener, F_SETFD, FD_CLOEXEC)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(listener, 16) == 0 else {
            close(listener)
            unlink(path)
            return nil
        }
        return listener
    }

    private static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let parent = pid_t(info.pbi_ppid)
        return parent > 1 ? parent : nil
    }
}

enum AgentCommandLink {
    /// `bin/corta` → the running executable. A link that points elsewhere is replaced.
    @discardableResult
    static func ensure(bin: URL, executable: URL) -> Bool {
        let directory = bin.path
        mkdir(directory, 0o700)
        chmod(directory, 0o700)
        let link = bin.appendingPathComponent("corta").path
        var target = [UInt8](repeating: 0, count: Int(PATH_MAX))
        let count = readlink(link, &target, target.count)
        if count > 0 {
            let current = String(decoding: target.prefix(count), as: UTF8.self)
            if current == executable.path { return true }
            unlink(link)
        }
        return symlink(executable.path, link) == 0
    }
}


