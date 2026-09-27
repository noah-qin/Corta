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
import UserNotifications

/// A notification when a long-running command finishes.
///
/// With shell integration, OSC 133 marks give the real start, end and exit
/// status. Without it a heuristic fails quiet: a task starts at Return and
/// ends after `idleGrace` of silence — a mid-run pause notifies early,
/// which is why the feature is off by default.
///
/// Nothing is posted below the threshold or while the window is key, and
/// never the command text: the grid holds tokens and mistyped passwords
/// (`SECURITY.md` §5).
@MainActor
final class TaskNotifier {
    /// How long output must be quiet before the task counts as finished.
    private static let idleGrace: TimeInterval = 1.5

    private var startedAt: Date?
    private var idleTimer: Timer?
    /// Set at the first OSC 133 boundary; the heuristic then switches off.
    private var usesShellIntegration = false
    /// Detects starts as edges, not per output batch.
    private var wasCommandRunning = false
    private var lastExitStatus: Int?
    /// For jumping back on click; nil on the heuristic path.
    private var lastCommandID: Int?
    /// Checked for key status, and the source of the title.
    private weak var window: NSWindow?
    private static var didRequestAuthorization = false

    /// Whether macOS will deliver anything, so the settings page can explain
    /// an "on" switch that does nothing. Read from
    /// `UNUserNotificationCenter`, never stored: System Settings can change it
    /// at any time (D10).
    enum Permission: Equatable {
        /// Not asked yet; the prompt comes with the first long task.
        case notDetermined
        case granted
        /// Refused, or turned off in System Settings.
        case denied
    }

    /// Posted when a read finds permission denied.
    static let permissionDidChange = Notification.Name(
        "dev.noahqin.Corta.notificationPermissionDidChange")

    private(set) static var permission: Permission?

    /// Reads the state asynchronously and posts `permissionDidChange`.
    static func refreshPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let state: Permission =
                switch settings.authorizationStatus {
                case .notDetermined: .notDetermined
                case .denied: .denied
                default: .granted
                }
            Task { @MainActor in
                guard permission != state else { return }
                permission = state
                NotificationCenter.default.post(name: permissionDidChange, object: nil)
            }
        }
    }

    /// Opens System Settings: after a denial there is no re-prompt API.
    static func openSystemNotificationSettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.notifications")
        else { return }
        NSWorkspace.shared.open(url)
    }

    init() {}

    /// OSC 133 C / D; the first call disables the heuristic.
    ///
    /// - Parameter commandID: the finished command, for the click; nil on a
    ///   start.
    func noteCommandRunning(
        _ running: Bool, exitStatus: Int?, commandID: Int?, in window: NSWindow?
    ) {
        usesShellIntegration = true
        idleTimer?.invalidate()
        idleTimer = nil
        guard ConfigurationStore.shared.configuration.notifyOnLongTask else {
            wasCommandRunning = running
            return
        }
        self.window = window
        if running, !wasCommandRunning {
            startedAt = Date()
            requestAuthorizationOnce()
        } else if !running, wasCommandRunning {
            lastExitStatus = exitStatus
            lastCommandID = commandID
            finishExactly()
        }
        wasCommandRunning = running
    }

    /// Return pressed: a task starts, unless the shell reports boundaries.
    func noteCommandSubmitted(in window: NSWindow?) {
        guard !usesShellIntegration else { return }
        guard ConfigurationStore.shared.configuration.notifyOnLongTask else { return }
        self.window = window
        startedAt = Date()
        requestAuthorizationOnce()
        restartIdleTimer()
    }

    /// Output arrived; called per parse batch.
    func noteOutput() {
        guard !usesShellIntegration, startedAt != nil else { return }
        restartIdleTimer()
    }

    /// The pane is closing; stop the timer.
    func cancel() {
        idleTimer?.invalidate()
        idleTimer = nil
        startedAt = nil
    }

    private func restartIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(
            withTimeInterval: Self.idleGrace, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
    }

    private func finish() {
        guard let startedAt else { return }
        self.startedAt = nil
        idleTimer = nil
        let configuration = ConfigurationStore.shared.configuration
        guard configuration.notifyOnLongTask else { return }
        // The grace is idle time, not work.
        let elapsed = Date().timeIntervalSince(startedAt) - Self.idleGrace
        guard elapsed >= configuration.notificationThreshold else { return }
        guard window?.isKeyWindow != true else { return }
        post(elapsed: elapsed, title: window?.title ?? "Corta")
    }

    /// The shell-integration path: the end is a fact, no grace.
    private func finishExactly() {
        guard let startedAt else { return }
        self.startedAt = nil
        let configuration = ConfigurationStore.shared.configuration
        guard configuration.notifyOnLongTask else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed >= configuration.notificationThreshold else { return }
        guard window?.isKeyWindow != true else { return }
        post(elapsed: elapsed, title: window?.title ?? "Corta")
    }

    private func post(elapsed: TimeInterval, title: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        // An exit status is safe to show; command text is not.
        let outcome =
            lastExitStatus.map { $0 == 0 ? L10n.text("notification.finished") : L10n.format("notification.failed", $0) } ?? L10n.text("notification.finished")
        lastExitStatus = nil
        content.body = L10n.format("notification.body", outcome, Self.duration(elapsed))
        content.sound = nil
        // A window number and command id: enough to find it, no text.
        var userInfo: [String: Any] = [:]
        if let windowNumber = window?.windowNumber { userInfo["windowNumber"] = windowNumber }
        if let lastCommandID { userInfo["commandID"] = lastCommandID }
        content.userInfo = userInfo
        lastCommandID = nil
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// "2m 15s", "45s".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return L10n.format("duration.seconds", total) }
        let minutes = total / 60
        let remainder = total % 60
        if minutes < 60 {
            return remainder == 0 ? L10n.format("duration.minutes", minutes) : L10n.format("duration.minutesSeconds", minutes, remainder)
        }
        let hours = minutes / 60
        return L10n.format("duration.hoursMinutes", hours, minutes % 60)
    }

    /// Asked at the first task, not at launch.
    private func requestAuthorizationOnce() {
        guard !Self.didRequestAuthorization else { return }
        Self.didRequestAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) {
            granted, _ in
            // Keep the result, so the setting never claims "on" falsely.
            Task { @MainActor in
                let state: Permission = granted ? .granted : .denied
                guard Self.permission != state else { return }
                Self.permission = state
                NotificationCenter.default.post(name: Self.permissionDidChange, object: nil)
            }
        }
    }
}
