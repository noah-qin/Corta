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
        guard let split = window.contentViewController as? SplitViewController,
            let commandID = userInfo["commandID"] as? Int
        else { return }
        guard let pane = split.panes.first(where: { pane in
            pane.session?.commandRecords.records.contains { $0.id == commandID } == true
        }) else { return }
        window.makeFirstResponder(pane.terminalView)
        pane.focusCommand(id: commandID)
    }
}
