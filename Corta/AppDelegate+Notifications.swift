import Cocoa
import CortaTerminal
import UserNotifications

/// B07 — the click half of "connect notifications into the flow": a
/// `TaskNotifier` notification for a command that finished (or failed) tags
/// itself with the window and the `CommandRecord.id` it was about
/// (`TaskNotifier.post`); clicking it should land back on exactly that
/// command, not just bring some window forward.
extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Shown even while Corta is the foreground app — the default is to
    /// suppress a banner then, and a long build finishing while the user is
    /// looking at a different pane in the same app is exactly the case this
    /// feature exists for. Still no sound: `TaskNotifier.post` already
    /// leaves `content.sound` `nil` (`SECURITY.md` §5's "no command text"
    /// design extends to "no sound" too, and this must not override it).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) ->
            Void
    ) {
        completionHandler([.banner])
    }

    /// Brings the originating window forward and lands on the command that
    /// finished. Both pieces of `userInfo` are optional and independent: a
    /// window that has since closed still gets no crash, just nothing to
    /// focus, and a command id past `CommandRecordStore`'s bound (512
    /// entries) still brings the window forward even though there is
    /// nothing left to land on.
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
