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

import Cocoa
import CortaTerminal
import UserNotifications

/// Clicking a `TaskNotifier` notification lands on its command, via the
/// window and `CommandRecord.id` it carries.
extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Show banners while Corta is frontmost: the build may be in another
    /// pane. Still no sound (`TaskNotifier.post`).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) ->
            Void
    ) {
        completionHandler([.banner])
    }

    /// Brings the window forward and lands on the command; either may be
    /// gone (closed window, record past the store's bound), harmlessly.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let userInfo = response.notification.request.content.userInfo
        guard let windowNumber = userInfo["windowNumber"] as? Int,
            let window = NSApp.window(withWindowNumber: windowNumber)
        else { return }
        window.makeKeyAndOrderFront(nil)
        guard let split = window.contentViewController as? SplitViewController else { return }
        let panes = split.panes
        guard
            let target = Self.notificationTarget(
                paneID: userInfo["paneID"] as? String,
                sessionGeneration: userInfo["sessionGeneration"] as? Int,
                commandID: userInfo["commandID"] as? Int,
                panes: panes.map { pane in
                    NotificationCandidate(
                        paneID: pane.taskNotifier.paneID.uuidString,
                        sessionGeneration: pane.taskNotifier.sessionGeneration,
                        commandIDs: Set(pane.session?.commandRecords.records.map(\.id) ?? []))
                })
        else { return }
        let pane = panes[target.paneIndex]
        window.makeFirstResponder(pane.terminalView)
        if let commandID = target.commandID { pane.shell.focusCommand(id: commandID) }
    }

    /// A pane a notification can land on, as the click sees it.
    nonisolated struct NotificationCandidate {
        var paneID: String
        var sessionGeneration: Int
        var commandIDs: Set<Int>
    }

    nonisolated struct NotificationTarget: Equatable {
        var paneIndex: Int
        /// The command to land on; nil when only the pane is still there.
        var commandID: Int?
    }

    /// Where a click lands: the pane that posted, by its identity, and its
    /// command only while the session that ran it is still the pane's —
    /// a restarted pane numbers commands from zero again. A notification
    /// from before panes were named carries no pane, and falls back to the
    /// first pane holding the id.
    nonisolated static func notificationTarget(
        paneID: String?, sessionGeneration: Int?, commandID: Int?,
        panes: [NotificationCandidate]
    ) -> NotificationTarget? {
        if let paneID {
            guard let index = panes.firstIndex(where: { $0.paneID == paneID }) else { return nil }
            let pane = panes[index]
            guard let commandID, sessionGeneration == pane.sessionGeneration,
                pane.commandIDs.contains(commandID)
            else { return NotificationTarget(paneIndex: index, commandID: nil) }
            return NotificationTarget(paneIndex: index, commandID: commandID)
        }
        guard let commandID,
            let index = panes.firstIndex(where: { $0.commandIDs.contains(commandID) })
        else { return nil }
        return NotificationTarget(paneIndex: index, commandID: commandID)
    }
}
