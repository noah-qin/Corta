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

extension AgentHub {
    func handle(_ request: AgentRequest, caller: UUID?) -> AgentReply {
        pruneDeliveryBookkeeping()
        let now = Date().timeIntervalSinceReferenceDate
        guard let caller, let callingMember = bus.members.first(where: { $0.id == caller && !$0.paused }) else {
            return AgentReply(ok: false, text: "refused(notAMember)", delivery: "refused")
        }
        switch request.operation {
        case "state":
            guard callingMember.host != nil, let body = request.body, body.utf8.count < 4096,
                  var state = try? JSONDecoder().decode(AgentRemoteState.self, from: Data(body.utf8)) else {
                return AgentReply(ok: false, text: "refused(state)", delivery: "refused")
            }
            state.seen = now
            remoteStates[caller] = state
            return AgentReply(ok: true, text: "ready", delivery: nil)
        case "members":
            let lines = bus.members.filter {
                bus.memberProjects[$0.id] == bus.memberProjects[caller]
            }.map { member in
                let level = capability(member)
                return "\(AgentEnvelope.shortID(member.id)) \(member.role) \(level)"
                    + (member.host.map { " host:" + $0 } ?? "")
            }
            return AgentReply(ok: true, text: lines.joined(separator: "\n"), delivery: nil)
        case "whoami":
            guard let member = bus.members.first(where: { $0.id == caller }) else {
                return AgentReply(ok: false, text: "refused(notAMember)", delivery: "refused")
            }
            return AgentReply(ok: true, text: "\(AgentEnvelope.shortID(member.id)) \(member.role)", delivery: nil)
        case "send": return send(request, caller: caller, member: callingMember, now: now)
        case "read": return AgentReply(ok: true, text: bus.read(member: caller, since: request.since)
            .map(envelope).joined(separator: "\n\n"), delivery: nil)
        case "wait":
            let pending = bus.read(member: caller, since: request.since)
            if pending.isEmpty, let giveUp = bus.noteEmptyWait(member: caller) {
                return AgentReply(ok: false, text: "giveUp", delivery: deliveryName(giveUp))
            }
            return AgentReply(ok: true, text: pending.map(envelope).joined(separator: "\n\n"), delivery: nil)
        case "status":
            guard let number = request.number, let item = bus.status(number: number),
                  item.from == caller || item.to == caller else {
                return AgentReply(ok: false, text: "refused(missing)", delivery: "refused")
            }
            let read = item.read ? " read" : ""
            return AgentReply(ok: true, text: "\(deliveryName(item.delivery))\(read)",
                delivery: deliveryName(item.delivery))
        default:
            return AgentReply(ok: false, text: "refused(missing)", delivery: "refused")
        }
    }

    private func pruneDeliveryBookkeeping() {
        let kept = Set(bus.items.map(\.number))
        deliveryTasks = deliveryTasks.filter { kept.contains($0.key) }
        userMessageSources = userMessageSources.filter { kept.contains($0.key) }
        interrupted.formIntersection(kept)
    }

    private func send(_ request: AgentRequest, caller: UUID, member callingMember: AgentMemberRecord,
                      now: TimeInterval) -> AgentReply {
        guard let to = request.to, let body = request.body else {
            return AgentReply(ok: false, text: "refused(missing)", delivery: "refused")
        }
        var context: [String] = []
        if request.context ?? callingMember.contextEnabled ?? false, let target = bus.member(caller.uuidString) {
            context = contextLines?(target.sessionID) ?? []
        }
        let sent = bus.send(from: caller, to: to, body: body, replyTo: request.replyTo,
                           context: context, now: now)
        guard let number = sent.number, let item = sent.item else {
            return AgentReply(ok: false, text: deliveryName(sent.delivery), delivery: deliveryName(sent.delivery))
        }
        let delivery = wake(item)
        bus.mark(number, delivery, now: now)
        return AgentReply(ok: true, text: "#\(number) \(deliveryName(delivery))",
                          delivery: deliveryName(delivery), number: number)
    }

    func role(of id: UUID) -> String {
        if id == AgentEnvelope.userID { return "user" }
        return bus.members.first { $0.id == id }?.role ?? "member"
    }

    func wake(_ item: AgentBus.Item) -> AgentDelivery {
        guard let member = bus.members.first(where: { $0.id == item.to }) else { return .queued }
        if member.host != nil {
            if bus.forwardsDown.contains(member.id) { return .forwardUnavailable }
            return tryNudge(item, member: member)
        }
        guard let shot = snapshot?(member.sessionID) else { return .queued }
        if shot.claudeSocket != nil || shot.codexExecutable != nil {
            let text = envelope(item)
            pendingDeliveries.insert(item.number)
            let task = Task { @MainActor [weak self] () -> AgentDelivery in
                defer { self?.pendingDeliveries.remove(item.number) }
                let pushed = await Task.detached(priority: .utility) {
                    Self.push(text, snapshot: shot)
                }.value
                guard let self, !Task.isCancelled,
                      self.bus.members.contains(where: { $0.id == member.id && !$0.paused }),
                      self.bus.boundSessions.contains(member.sessionID) else { return .refused("unbound") }
                let now = Date().timeIntervalSinceReferenceDate
                if pushed {
                    self.deliveredThrough[member.id] = max(self.deliveredThrough[member.id] ?? 0, item.number)
                    self.bus.mark(item.number, .pushed, now: now)
                    if let source = self.userMessageSources[item.number] { self.userDeliveryChanged?(source, .pushed) }
                    return .pushed
                }
                self.bus.mark(item.number, .pushFailed("unavailable"), now: now)
                let fallback = self.tryNudge(item, member: member)
                self.bus.mark(item.number, fallback, now: now)
                if let source = self.userMessageSources[item.number] { self.userDeliveryChanged?(source, fallback) }
                return fallback
            }
            deliveryTasks[item.number] = task
            return .queued
        }
        return tryNudge(item, member: member)
    }

    private nonisolated static func push(_ text: String, snapshot shot: AgentWakeSnapshot) -> Bool {
        if let path = shot.claudeSocket, AgentPush.writeClaude(socket: path, envelope: text) { return true }
        if let executable = shot.codexExecutable, let thread = shot.codexThread,
           let argv = AgentPush.codexArguments(executable: executable, thread: thread, message: text) {
            return AgentPush.run(argv, timeout: 10)
        }
        return false
    }

    func tryNudge(_ item: AgentBus.Item, member: AgentMemberRecord) -> AgentDelivery {
        guard let shot = snapshot?(member.sessionID) else { return .queued }
        guard AgentNudgeGate.bytes(gate: shot.gate, body: item.body, role: member.role) != nil else {
            bus.note(item.number, event: "gate:" + (shot.gate.denial ?? "writeRejected"))
            return .queued
        }
        guard writeNudge?(member.sessionID) == true else {
            bus.note(item.number, event: "gate:" + (shot.gate.denial ?? "writeRejected"))
            return .queued
        }
        deliveredThrough[member.id] = max(deliveredThrough[member.id] ?? 0, item.number)
        let revision = inputRevision?(member.sessionID)
        let number = item.number
        let sessionID = member.sessionID
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
            guard let self, let revision, let now = self.inputRevision?(sessionID), now != revision else { return }
            self.interrupted.insert(number)
        }
        return .nudged
    }

    func envelope(_ item: AgentBus.Item) -> String {
        let member = bus.members.first { $0.id == item.to }
        let tmux = remoteTokens.first { $0.value == item.to }.flatMap { remoteSessionNames[$0.key] }
        let remoteCommand = tmux.map { "/tmp/" + $0 + "/corta" } ?? "corta"
        let command = member?.host == nil ? bus.commandPath : remoteCommand
        return AgentEnvelope.text(fromRole: role(of: item.from), fromID: item.from, number: item.number,
                                  replyTo: item.replyTo, body: item.body, context: item.context,
                                  fromUserPane: item.userPane, command: command)
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

}
