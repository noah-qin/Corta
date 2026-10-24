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

    func setProgramBlocked(_ blocked: Bool) {
        if !blocked { programBlockedNoticeDelivered = false }
        programBlocked = blocked
    }

    func noteProgramAttention(kind: ProgramStatus.Kind?, in window: NSWindow?) {
        guard ConfigurationStore.shared.configuration.notifyFromPrograms else { return }
        var notice = DesktopNotification()
        notice.body = L10n.text("agent.attention." + (kind?.rawValue ?? "generic"))
        queueProgramNotice(notice, in: window)
    }

    func noteProgramNotification(_ notice: DesktopNotification, visible: Bool, focused: Bool, in window: NSWindow?) {
        guard ConfigurationStore.shared.configuration.notifyFromPrograms else { return }
        if notice.close {
            if notice.id == programLastID || notice.id == programPending?.id { cancelProgramNotifications() }
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
        queueProgramNotice(notice, in: window)
    }

    /// One mutable system notice per pane. A flood replaces one pending
    /// value and delivers at most once per five seconds, without a queue.
    private func queueProgramNotice(_ notice: DesktopNotification, in window: NSWindow?) {
        guard let window else { return }
        programPending = notice
        guard programTimer == nil, programSubmission == nil else { return }
        // Adjacent status + explicit OSC notices describe one event. Give
        // them a short coalescing window before the first system delivery.
        let delay = max(0.15, Self.programDelay(now: programNow(), lastPosted: programLastPosted))
        let number = window.windowNumber
        let generation = sessionGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.sessionGeneration == generation else { return }
            self.programTimer = nil
            guard let notice = self.programPending else { return }
            self.programPending = nil
            guard ConfigurationStore.shared.configuration.notifyFromPrograms else { return }
            if self.programBlocked { self.programBlockedNoticeDelivered = true }
            self.programLastPosted = self.programNow()
            self.programLastID = notice.id
            self.programRevision += 1
            let revision = self.programRevision
            if let deliver = self.programDelivery { deliver(notice); return }
            let content = UNMutableNotificationContent()
            content.title = ProgramText.clean(self.title(), limit: 192)
            let text = [notice.title, notice.body].filter { !$0.isEmpty }.joined(separator: ": ")
            content.body = L10n.format("agent.notification.message", ProgramText.clean(text, limit: 2048))
            content.sound = notice.sound ? .default : nil
            content.interruptionLevel = notice.urgency == 0 ? .passive : .active
            // Routing uses Corta identities exclusively. No reports to stdin.
            if notice.focus {
                content.userInfo = ["windowNumber": number, "paneID": self.paneID.uuidString,
                                    "sessionGeneration": generation]
            }
            self.programExpiry?.cancel(); self.programExpiry = nil
            self.programSubmission = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    self.programSubmission = nil
                    if let pending = self.programPending,
                       let window = NSApp.window(withWindowNumber: number) {
                        self.queueProgramNotice(pending, in: window)
                    }
                }
                let center = UNUserNotificationCenter.current()
                let settings = await center.notificationSettings()
                Self.programLog.debug("Program notice authorization: \(settings.authorizationStatus.rawValue, privacy: .public)")
                guard !Task.isCancelled, self.programRevision == revision,
                      ConfigurationStore.shared.configuration.notifyFromPrograms else { return }
                if settings.authorizationStatus == .notDetermined
                    || (settings.authorizationStatus == .authorized && settings.badgeSetting == .notSupported) {
                    _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
                    Self.refreshPermission()
                }
                guard !Task.isCancelled, self.programRevision == revision,
                      self.sessionGeneration == generation,
                      ConfigurationStore.shared.configuration.notifyFromPrograms else { return }
                do {
                    try await center.add(UNNotificationRequest(
                        identifier: self.programIdentifier, content: content, trigger: nil))
                } catch {
                    // Never log program text, titles or ids.
                    Self.programLog.error("Program notice delivery failed: \((error as NSError).code, privacy: .public)")
                }
                self.programLastPosted = self.programNow()
                // A close/restart can race the asynchronous OS submission.
                guard self.programRevision == revision else {
                    center.removeDeliveredNotifications(withIdentifiers: [self.programIdentifier])
                    return
                }
                if notice.expiryMilliseconds > 0 {
                    let expiry = DispatchWorkItem { [weak self] in
                        guard let self, self.programRevision == revision else { return }
                        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [self.programIdentifier])
                        self.programExpiry = nil
                    }
                    self.programExpiry = expiry
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(notice.expiryMilliseconds) / 1000, execute: expiry)
                }
            }
        }
        programTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func cancelProgramNotifications() {
        programTimer?.cancel(); programTimer = nil
        programExpiry?.cancel(); programExpiry = nil
        programPending = nil; programRevision += 1
        programBlocked = false; programBlockedNoticeDelivered = false
        // Keep the slot occupied until the OS call completes, so a stale
        // submission cannot overtake and erase its replacement.
        programSubmission?.cancel()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [programIdentifier])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [programIdentifier])
    }
}
