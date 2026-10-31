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

/// The in-app bus plus the socket `corta` connects to.
@MainActor
final class AgentHub {
    static let shared = AgentHub()

    var bus = AgentBus()
    /// Shell pid → Space session id.
    var shells: [pid_t: UUID] = [:]
    var shellStarts: [pid_t: UInt64] = [:]
    /// Remote token → member id. Not written to disk.
    var remoteTokens: [String: UUID] = [:]
    var remoteReady: Set<UUID> = []
    var remoteStates: [UUID: AgentRemoteState] = [:]
    /// Filled by Space. Nil answers mean the session cannot be nudged.
    var snapshot: ((UUID) -> AgentWakeSnapshot?)?
    var writeNudge: ((UUID) -> Bool)?
    var contextLines: ((UUID) -> [String])?
    var userDeliveryChanged: ((UUID, AgentDelivery) -> Void)?
    var userMessageSources: [Int: UUID] = [:]
    /// The pane's input revision, so a key during a nudge can be recorded.
    var inputRevision: ((UUID) -> UInt64?)?
    var interrupted: Set<Int> = []

    private var server: AgentSocketServer?
    var remoteEndpoints: [String: AgentSocketServer] = [:]
    var pendingDeliveries: Set<Int> = []
    var deliveryTasks: [Int: Task<AgentDelivery, Never>] = [:]
    var deliveredThrough: [UUID: Int] = [:]
    var remoteSessionNames: [String: String] = [:]
    private(set) var socketPath: String?

    static func socketDirectory(development: Bool, uid: uid_t = getuid()) -> String {
        "/tmp/" + (development ? "corta-agent-dev-\(uid)" : "corta-agent-\(uid)")
    }

    func sync(members: [AgentMemberRecord], bound: Set<UUID>, shells: [pid_t: UUID],
              projects: [UUID: String] = [:]) {
        let active = Set(members.filter { !$0.paused }.map(\.id))
        remoteTokens = remoteTokens.filter { active.contains($0.value) }
        pruneRemoteEndpoints()
        remoteReady.formIntersection(active)
        let now = Date().timeIntervalSinceReferenceDate
        for (id, state) in remoteStates where now - (state.seen ?? 0) > 4 { disconnectRemote(id) }
        bus.memberProjects = projects
        for member in bus.members where member.host == nil && bus.boundSessions.contains(member.sessionID)
            && !bound.contains(member.sessionID) { bus.dropInbox(member: member.id) }
        bus.replaceMembers(members)
        bus.boundSessions = bound
        bus.forwardsDown = Set(members.filter { $0.host != nil && !remoteReady.contains($0.id) }.map(\.id))
        shellStarts = shells.reduce(into: [:]) { result, entry in
            result[entry.key] = self.shells[entry.key] == entry.value
                ? shellStarts[entry.key] : Self.processStart(entry.key)
        }
        self.shells = shells
    }

    func rememberRemote(token: String, member: UUID) {
        remoteTokens = remoteTokens.filter { $0.value != member }
        remoteReady.remove(member)
        remoteTokens[token] = member
        pruneRemoteEndpoints()
    }

    func markRemoteReady(_ member: UUID) {
        remoteReady.insert(member)
    }

    /// Start or stop with `agent-messages`. A second call refreshes the link.
    func apply(enabled: Bool, development: Bool, executable: String, directoryOverride: String? = nil) {
        guard enabled else {
            stop()
            return
        }
        let testPID = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            ? nil : ProcessInfo.processInfo.processIdentifier
        let directory = directoryOverride ?? (testPID.map { "/tmp/corta-agent-test-\(getuid())-\($0)" }
            ?? Self.socketDirectory(development: development))
        mkdir(directory, 0o700)
        _ = AgentCommandLink.ensure(
            bin: URL(fileURLWithPath: directory).appendingPathComponent("bin"),
            executable: URL(fileURLWithPath: executable))
        if socketPath != nil { return }
        bus.commandPath = directory + "/bin/corta"
        let path = directory + "/agent.sock"
        guard let server = AgentSocketServer(directory: directory, path: path, handler: { [weak self] request, pid in
            guard let self else { return AgentReply(ok: false, text: "refused(unavailable)", delivery: "refused") }
            return await self.receive(request, pid: pid)
        }) else { return }
        self.server = server
        socketPath = path
    }

    func stop() {
        server?.stop()
        server = nil
        for endpoint in remoteEndpoints.values { endpoint.stop() }
        remoteEndpoints = [:]
        remoteTokens = [:]
        remoteReady = []
        remoteSessionNames = [:]
        remoteStates = [:]
        for task in deliveryTasks.values { task.cancel() }
        deliveryTasks = [:]
        pendingDeliveries = []
        deliveredThrough = [:]
        for member in bus.members { bus.dropInbox(member: member.id) }
        if let socketPath { unlink(socketPath) }
        socketPath = nil
    }

    func receive(_ request: AgentRequest, pid: pid_t) async -> AgentReply {
        guard socketPath != nil else { return AgentReply(ok: false, text: "refused(disabled)", delivery: "refused") }
        let identity: UUID?
        guard request.token == nil else { return Self.identityRefusal }
        identity = caller(pid: pid, claimedPane: request.pane)
        var reply = handle(request, caller: identity)
        if let number = reply.number, let task = deliveryTasks[number] {
            let delivery = await task.value
            reply.text = "#\(number) \(deliveryName(delivery))"
            reply.delivery = deliveryName(delivery)
        }
        return reply
    }

    /// Called on the accept queue or from a test.
    func exchange(_ request: AgentRequest, caller: UUID?) -> AgentReply {
        let reply = onMain { self.handle(request, caller: caller) }
        return reply
    }

    /// Walk parents to a registered shell. A claimed pane that disagrees is refused.
    func caller(pid: pid_t, claimedPane: String?) -> UUID? {
        var current = pid
        for _ in 0..<24 {
            if let session = shells[current] {
                guard let start = shellStarts[current], Self.processStart(current) == start else { return nil }
                if let claimedPane, claimedPane.lowercased() != session.uuidString.lowercased() { return nil }
                return bus.members.first { $0.sessionID == session }?.id
            }
            guard let parent = Self.parent(of: current), parent != current else { return nil }
            current = parent
        }
        return nil
    }

    func caller(token: String) -> UUID? {
        guard let member = remoteTokens[token], bus.members.contains(where: { $0.id == member && !$0.paused })
        else { return nil }
        return member
    }

    func disconnectRemote(_ member: UUID) {
        remoteReady.remove(member)
        remoteStates[member] = nil
        remoteTokens = remoteTokens.filter { $0.value != member }
        pruneRemoteEndpoints()
        bus.forwardsDown.insert(member)
    }

    /// A person sending a selection. Wakes the receiver the same way `corta send` does.

    /// One nudge for unread mail when the gate newly allows it. Not a poll of the PTY.
    func nudgePending() {
        let now = Date().timeIntervalSinceReferenceDate
        for member in bus.members where !member.paused {
            let unread = bus.peek(member: member.id)
            guard let latest = unread.max(by: { $0.number < $1.number }),
                  (deliveredThrough[member.id] ?? 0) < latest.number,
                  !unread.contains(where: { pendingDeliveries.contains($0.number) }) else { continue }
            let outcome = tryNudge(latest, member: member)
            if outcome == .nudged { bus.mark(latest.number, outcome, now: now) }

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
            + " If your tool resets PATH, use " + bus.commandPath + " instead of corta."
    }

    func historyText(sessionID: UUID) -> String {
        guard let member = bus.members.first(where: { $0.sessionID == sessionID }) else { return "" }
        return bus.items.filter { $0.to == member.id || $0.from == member.id }.suffix(20).map { item in
            "#\(item.number) \(deliveryName(item.delivery))" + (item.read ? " read" : "")
                + (interrupted.contains(item.number) ? " nudgeInterrupted" : "")
                + " " + item.events.joined(separator: " → ")
        }.joined(separator: "\n")
    }

    func unreadText(sessionID: UUID) -> String {
        guard let member = bus.members.first(where: { $0.sessionID == sessionID }) else { return "" }
        return bus.peek(member: member.id).map(envelope).joined(separator: "\n\n")
    }

    func deliverUser(to token: String, body: String, context: [String], pane: String? = nil,
                     source: UUID? = nil) -> AgentDelivery {
        let now = Date().timeIntervalSinceReferenceDate
        let sent = bus.send(from: AgentEnvelope.userID, to: token, body: AgentEnvelope.prefixUTF8(body,
            limit: AgentEnvelope.bodyLimit),
                            replyTo: nil, context: context, now: now)
        guard let number = sent.number, let item = sent.item else { return sent.delivery }
        if let source { userMessageSources[number] = source }
        if let pane { bus.setUserPane(number, pane) }
        let delivery = wake(bus.status(number: number) ?? item)
        bus.mark(number, delivery, now: now)
        return delivery
    }

    func capability(_ member: AgentMemberRecord) -> String {
        if member.paused { return "paused" }
        if member.host != nil {
            return remoteReady.contains(member.id) ? "remote/nudge" : "forwardUnavailable"
        }
        guard bus.boundSessions.contains(member.sessionID) else { return "unbound" }
        guard let shot = snapshot?(member.sessionID) else { return "unsupported:noProcess" }
        if shot.claudeSocket != nil || (shot.codexExecutable != nil && shot.codexThread != nil) { return "push" }
        if let reason = shot.gate.denial { return "nudge/" + reason }
        return "nudge"
    }

    func wakeSnapshot(for sessionID: UUID) -> AgentWakeSnapshot? { snapshot?(sessionID) }

    private func onMain<T>(_ body: () -> T) -> T {
        if Thread.isMainThread { return body() }
        return DispatchQueue.main.sync(execute: body)
    }

    private static func processStart(_ pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
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
