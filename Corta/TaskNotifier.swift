import AppKit
import UserNotifications

/// M6.3 — a notification when a long-running command finishes.
///
/// The honest version of this needs shell integration, and now has it: OSC
/// 133 marks where a command starts and ends (M7.2), so when the user's
/// shell emits those marks this notifier uses the real boundaries — a
/// command that prints nothing for a minute is still running, and the
/// notification fires when it actually finishes, with its exit status.
///
/// The heuristic below remains for shells with no integration configured,
/// which is most shells on a fresh machine. It is built to fail quiet rather
/// than fail noisy:
///
/// - A task *starts* when the user presses Return. That is the one moment a
///   terminal knows the user asked for something.
/// - It *ends* when output has been idle for `idleGrace`. A command that
///   prints nothing for two seconds mid-run gets an early notification; that
///   is the cost of not having shell integration, and it is why the whole
///   feature is off by default.
/// - Nothing is posted unless the run lasted longer than the configured
///   threshold *and* the window is not the key window. A notification about
///   something the user is looking at is pure noise.
///
/// The notification deliberately does not carry the command text. The grid
/// is full of things that should not be echoed to Notification Center —
/// tokens a `curl` invocation was given, a mistyped password at a prompt —
/// and a title is not worth that (`SECURITY.md` §5).
@MainActor
final class TaskNotifier {
    /// How long output must be quiet before the task counts as finished.
    private static let idleGrace: TimeInterval = 1.5

    private var startedAt: Date?
    private var idleTimer: Timer?
    /// True once this pane's shell has emitted an OSC 133 boundary. From
    /// then on the keystroke-and-idle heuristic is switched off entirely:
    /// running both would double-count, and the exact one is strictly better.
    private var usesShellIntegration = false
    /// The last `isCommandRunning` seen, so a start is detected as an edge
    /// rather than re-triggered on every output batch.
    private var wasCommandRunning = false
    /// The exit status of the command that just finished, for the body text.
    private var lastExitStatus: Int?
    /// The window to check for key status when the task ends, and the pane's
    /// title for the notification body.
    private weak var window: NSWindow?
    private static var didRequestAuthorization = false

    /// Whether macOS will actually deliver anything.
    ///
    /// The switch on the settings page said "on" whether or not permission
    /// had been granted, so a user who tapped Don't Allow — once, months ago,
    /// possibly by reflex — had a setting that was on, a feature that never
    /// fired, and nothing anywhere telling them which. The state is read from
    /// `UNUserNotificationCenter`, not stored, because System Settings can
    /// change it while Corta is running and a cached copy would be the second
    /// store the project's own rule forbids.
    enum Permission: Equatable {
        /// Not asked yet — the setting is on and the prompt appears at the
        /// first long task. Nothing to report.
        case notDetermined
        case granted
        /// Refused, or switched off in System Settings afterwards. The
        /// setting is on and does nothing.
        case denied
    }

    /// Posted when the permission state is read and turns out to be denied,
    /// so the settings page can say so without polling.
    static let permissionDidChange = Notification.Name(
        "dev.noahqin.Corta.notificationPermissionDidChange")

    /// The last state read. `nil` until something asks.
    private(set) static var permission: Permission?

    /// Reads the current authorization state and posts
    /// `permissionDidChange`. Cheap, asynchronous, and safe to call whenever
    /// a surface needs the answer — the settings page calls it as it opens.
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

    /// Opens System Settings at the pane where the decision can be reversed.
    /// There is no API to re-prompt after a denial — the only route back is
    /// the one the user has to walk, so the app has to point at it rather
    /// than ask again and appear to do nothing.
    static func openSystemNotificationSettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.notifications")
        else { return }
        NSWorkspace.shared.open(url)
    }

    init() {}

    /// The shell said a command started or stopped (OSC 133 C / D). Once
    /// this is called even once, the heuristic below stops running.
    func noteCommandRunning(_ running: Bool, exitStatus: Int?, in window: NSWindow?) {
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
            finishExactly()
        }
        wasCommandRunning = running
    }

    /// The user pressed Return: whatever happens next is a task. Ignored once
    /// the shell has proved it reports boundaries itself.
    func noteCommandSubmitted(in window: NSWindow?) {
        guard !usesShellIntegration else { return }
        guard ConfigurationStore.shared.configuration.notifyOnLongTask else { return }
        self.window = window
        startedAt = Date()
        requestAuthorizationOnce()
        restartIdleTimer()
    }

    /// Output arrived, so the task is not finished. Called from the render
    /// loop's output hook, which already runs per parse batch.
    func noteOutput() {
        guard !usesShellIntegration, startedAt != nil else { return }
        restartIdleTimer()
    }

    /// The pane is going away; a timer that outlives it would fire against a
    /// window that no longer exists.
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
        // The grace period is idle time, not work — subtracting it keeps the
        // threshold meaning what the settings page says it means.
        let elapsed = Date().timeIntervalSince(startedAt) - Self.idleGrace
        guard elapsed >= configuration.notificationThreshold else { return }
        guard window?.isKeyWindow != true else { return }
        post(elapsed: elapsed, title: window?.title ?? "Corta")
    }

    /// The shell-integration path: no grace period to subtract, because the
    /// end of the command is a fact rather than an inference.
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
        // The exit status, when the shell reported one. Still no command
        // text: the grid is full of things that should not reach Notification
        // Center, and a small integer is not one of them (`SECURITY.md` §5).
        let outcome =
            lastExitStatus.map { $0 == 0 ? L10n.text("notification.finished") : L10n.format("notification.failed", $0) } ?? L10n.text("notification.finished")
        lastExitStatus = nil
        content.body = L10n.format("notification.body", outcome, Self.duration(elapsed))
        content.sound = nil
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Whole units, largest first: "2m 15s", "45s". Anything finer is noise
    /// on something that already ran for half a minute.
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

    /// Asked for at the first task rather than at launch: a terminal that
    /// demands notification permission before it has drawn a prompt is
    /// asking for something it has not earned.
    private func requestAuthorizationOnce() {
        guard !Self.didRequestAuthorization else { return }
        Self.didRequestAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) {
            granted, _ in
            // Both results used to be discarded, which is how the setting
            // ended up able to say "on" about a feature the system had
            // switched off.
            Task { @MainActor in
                let state: Permission = granted ? .granted : .denied
                guard Self.permission != state else { return }
                Self.permission = state
                NotificationCenter.default.post(name: Self.permissionDidChange, object: nil)
            }
        }
    }
}
