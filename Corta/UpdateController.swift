import AppKit
import Sparkle

/// Wraps Sparkle's standard updater as the single point of contact for
/// update checks — the automatic background check on the interval
/// `INFOPLIST_KEY_SUScheduledCheckInterval` sets, and the manual one from
/// "Check for Updates…", which `AppDelegate+Menus` installs directly under
/// About, where every other Sparkle-using Mac app puts it.
///
/// Created (and its background timer started) at launch rather than
/// lazily on first use: `SUScheduledCheckInterval` only means what it says
/// if the controller has been running since launch.
@MainActor
final class UpdateController {
    static let shared = UpdateController()

    private let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    private init() {
        applyAutoCheckSetting()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyAutoCheckSetting), name: ConfigurationStore.didChange,
            object: nil)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }

    /// `update-auto-check` (`Configuration.swift`) governs only the
    /// unattended background check — Check for Updates… is a direct user
    /// action and always works, on or off. Read live rather than once at
    /// launch, the same as every other config-file setting.
    @objc private func applyAutoCheckSetting() {
        controller.updater.automaticallyChecksForUpdates =
            ConfigurationStore.shared.configuration.updateAutoCheck
    }
}
