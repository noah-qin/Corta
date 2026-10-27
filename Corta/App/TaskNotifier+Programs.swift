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

import AppKit
import CortaTerminal
import UserNotifications
import OSLog

extension TaskNotifier {
    private static let programLog = Logger(subsystem: "dev.noahqin.Corta", category: "notifications")
    nonisolated static func programDelay(now: TimeInterval, lastPosted: TimeInterval) -> TimeInterval {
        max(0, 5 - (now - lastPosted))
    }
    var programIdentifier: String { "program-" + paneID.uuidString }

    func setProgramBlocked(_ blocked: Bool, episode: Int? = nil) {
        // The parser can see leave/re-enter between two coalesced UI reads.
        // A changed kind alone does not start a new episode.
        if blocked && programBlocked, let episode, episode != programReportedEpisode {
            setProgramBlocked(false)
        }
        programReportedEpisode = blocked ? episode : nil
        guard blocked != programBlocked else { return }
        let endedWait = programWaitGeneration
        programBlocked = blocked
        programBlockedNoticeDelivered = false
        if blocked { programWaitGeneration += 1; return }
        // Only fixed state-derived attention belongs to this wait. A program
        // message has its own lifetime and must survive an unrelated clear.
        if programPendingWait == endedWait {
            programPending = nil; programPendingWait = nil
            programTimer?.cancel(); programTimer = nil
        }
        if programActiveWait == endedWait { invalidateProgramDelivery() }
    }

    func noteProgramAttention(kind: ProgramStatus.Kind?, in window: NSWindow?) {
        guard ConfigurationStore.shared.configuration.notifyFromPrograms else { return }
        if programBlocked && (programBlockedNoticeDelivered
            || (programSubmission != nil && programActiveWait == programWaitGeneration)) { return }
        // A BEL must not replace a more informative program message.
        if programPending != nil && !programPendingIsAttention { return }
        var notice = DesktopNotification()
        notice.body = L10n.text("agent.attention." + (kind?.rawValue ?? "generic"))
        queueProgramNotice(notice, attention: true,
            wait: programBlocked ? programWaitGeneration : nil,
            episode: programBlocked ? programWaitGeneration : nil, in: window)
    }

    func noteProgramNotification(_ notice: DesktopNotification, visible: Bool, focused: Bool, in window: NSWindow?) {
        guard ConfigurationStore.shared.configuration.notifyFromPrograms else { return }
        if notice.close {
            if notice.id == programPending?.id {
                programTimer?.cancel(); programTimer = nil
                programPending = nil; programPendingWait = nil; programPendingEpisode = nil
            }
            if notice.id == programLastID { invalidateProgramDelivery() }
            // Close is scoped to the matching message, not task state or a
            // newer pending id. It does not begin a new waiting episode.
            return
        }
        // Claude can emit its explicit OSC notice several seconds after
        // the 7501 blocked edge. They describe the same waiting episode.
        // Replace the pending value, but never re-alert an announced wait.
        if programBlocked && programBlockedNoticeDelivered { return }
        switch notice.occasion {
        case .always: break
        case .unfocused: guard !focused else { return }
        case .invisible: guard !visible else { return }
        }
        queueProgramNotice(notice, attention: false, wait: nil,
            episode: programBlocked ? programWaitGeneration : nil, in: window)
    }

    /// One mutable system notice per pane. A flood replaces one pending
    /// value and delivers at most once per five seconds, without a queue.
    private func queueProgramNotice(
        _ notice: DesktopNotification, attention: Bool, wait: Int?, episode: Int?, in window: NSWindow?
    ) {
        guard let window else { return }
        programPending = notice
        programPendingIsAttention = attention; programPendingWait = wait
        programPendingEpisode = episode
        guard programTimer == nil, programSubmission == nil else { return }
        // Adjacent status + explicit OSC notices describe one event. Give
        // them a short coalescing window before the first system delivery.
        let delay = max(0.15, Self.programDelay(now: programNow(), lastPosted: programLastPosted))
        let number = window.windowNumber
        let generation = sessionGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.sessionGeneration == generation else { return }
            self.firePendingProgramNotice(windowNumber: number, generation: generation)
        }
        programTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// One notice on its way to the system, with what decides whether it
    /// is still wanted when the asynchronous submission returns.
    private struct ProgramSubmission {
        var notice: DesktopNotification
        var content: UNMutableNotificationContent
        var revision: Int
        var generation: Int
        var wait: Int?
        var waitingAtSubmission: Int?
        var windowNumber: Int
    }

    /// The coalescing window closed: posts what is pending, if it is still
    /// wanted.
    private func firePendingProgramNotice(windowNumber number: Int, generation: Int) {
        programTimer = nil
        guard let notice = programPending else { return }
        let wait = programPendingWait
        let episode = programPendingEpisode
        let waitingAtSubmission = programBlocked && episode == programWaitGeneration ? episode : nil
        programPending = nil; programPendingWait = nil; programPendingEpisode = nil
        guard ConfigurationStore.shared.configuration.notifyFromPrograms,
              programCanDeliver(notice),
              !(programBlocked && programBlockedNoticeDelivered && episode == programWaitGeneration),
              wait == nil || (programBlocked && programWaitGeneration == wait) else { return }
        programActiveWait = wait
        programLastPosted = programNow()
        programLastID = notice.id
        programRevision += 1
        if let deliver = programDelivery {
            markProgramWaitDelivered(waitingAtSubmission)
            deliver(notice); return
        }
        let submission = ProgramSubmission(
            notice: notice, content: programContent(for: notice, windowNumber: number, generation: generation),
            revision: programRevision, generation: generation, wait: wait,
            waitingAtSubmission: waitingAtSubmission, windowNumber: number)
        programExpiry?.cancel(); programExpiry = nil
        programSubmission = Task { @MainActor [weak self] in
            await self?.submitProgramNotice(submission)
        }
    }

    private func programContent(
        for notice: DesktopNotification, windowNumber: Int, generation: Int
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = ProgramText.clean(title(), limit: 192)
        let text = [notice.title, notice.body].filter { !$0.isEmpty }.joined(separator: ": ")
        content.body = L10n.format("agent.notification.message", ProgramText.clean(text, limit: 2048))
        content.sound = notice.sound ? .default : nil
        content.interruptionLevel = notice.urgency == 0 ? .passive : .active
        // Routing uses Corta identities exclusively. No reports to stdin.
        if notice.focus {
            content.userInfo = ["windowNumber": windowNumber, "paneID": paneID.uuidString,
                                "sessionGeneration": generation]
        }
        return content
    }

    /// Hands the notice to the system once permission is settled, then
    /// queues whatever arrived meanwhile.
    private func submitProgramNotice(_ submission: ProgramSubmission) async {
        defer {
            programSubmission = nil
            if let pending = programPending,
               let window = NSApp.window(withWindowNumber: submission.windowNumber) {
                queueProgramNotice(pending, attention: programPendingIsAttention,
                    wait: programPendingWait, episode: programPendingEpisode, in: window)
            }
        }
        let center = UNUserNotificationCenter.current()
        guard await authorizeProgramNotices(center, revision: submission.revision) else { return }
        let revision = submission.revision
        let wait = submission.wait
        guard !Task.isCancelled, programRevision == revision,
              sessionGeneration == submission.generation,
              ConfigurationStore.shared.configuration.notifyFromPrograms,
              programCanDeliver(submission.notice),
              wait == nil || (programBlocked && programWaitGeneration == wait) else { return }
        do {
            let request = UNNotificationRequest(
                identifier: programIdentifier, content: submission.content, trigger: nil)
            if let submit = programSubmit {
                try await submit(request)
            } else {
                try await center.add(request)
            }
            if programRevision == revision { markProgramWaitDelivered(submission.waitingAtSubmission) }
        } catch {
            // Never log program text, titles or ids.
            Self.programLog.error(
                "Program notice delivery failed: \((error as NSError).code, privacy: .public)")
        }
        programLastPosted = programNow()
        // A close/restart can race the asynchronous OS submission.
        guard programRevision == revision else {
            removeProgramNotice()
            return
        }
        if submission.notice.expiryMilliseconds > 0 {
            scheduleProgramExpiry(after: submission.notice.expiryMilliseconds, revision: revision)
        }
    }

    /// Asks once while permission is undecided, or while badges are
    /// unsupported under an authorisation that predates them.
    /// - Returns: false when the notice stopped being wanted meanwhile.
    private func authorizeProgramNotices(_ center: UNUserNotificationCenter, revision: Int) async -> Bool {
        if let authorize = programAuthorize {
            await authorize()
            return true
        }
        let settings = await center.notificationSettings()
        Self.programLog.debug(
            "Program notice authorization: \(settings.authorizationStatus.rawValue, privacy: .public)")
        guard !Task.isCancelled, programRevision == revision,
              ConfigurationStore.shared.configuration.notifyFromPrograms else { return false }
        if settings.authorizationStatus == .notDetermined
            || (settings.authorizationStatus == .authorized && settings.badgeSetting == .notSupported) {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            Self.refreshPermission()
        }
        return true
    }

    /// Withdraws the posted notice when the program's expiry passes, unless
    /// a newer one replaced it.
    private func scheduleProgramExpiry(after milliseconds: Int, revision: Int) {
        let expiry = DispatchWorkItem { [weak self] in
            guard let self, self.programRevision == revision else { return }
            self.removeProgramNotice()
            self.programExpiry = nil
        }
        programExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(milliseconds) / 1000, execute: expiry)
    }

    private func markProgramWaitDelivered(_ wait: Int?) {
        if programBlocked && wait == programWaitGeneration { programBlockedNoticeDelivered = true }
    }

    private func invalidateProgramDelivery() {
        programExpiry?.cancel(); programExpiry = nil
        programRevision += 1; programActiveWait = nil; programLastID = ""
        // Keep the slot until the OS call finishes. Its revision check removes
        // stale delivery before the pending replacement may be submitted.
        programSubmission?.cancel()
        removeProgramNotice()
    }

    private func removeProgramNotice() {
        if let remove = programRemove { remove(); return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [programIdentifier])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [programIdentifier])
    }

    func cancelProgramNotifications() {
        programTimer?.cancel(); programTimer = nil
        programPending = nil; programPendingWait = nil; programPendingIsAttention = false
        programPendingEpisode = nil
        programBlocked = false; programBlockedNoticeDelivered = false
        programWaitGeneration += 1; programReportedEpisode = nil
        invalidateProgramDelivery()
    }
}
