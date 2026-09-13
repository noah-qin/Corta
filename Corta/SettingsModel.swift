import AppKit
import CoreText
import Observation

/// A save/status report shared by every "state plus one action" row on the
/// settings page: the overall save line, the font's resolution, shell
/// integration, directory history, and the notification-permission notice.
///
/// **Why an icon and a word, never a colour alone.** A green tick and a red
/// cross are the same shape to a person who cannot separate those hues, and
/// this is the only report several of these rows make. `StatusRowView`
/// carries the symbol as the primary signal, the message as the detail, and
/// tint as the third and least load-bearing one.
struct RowStatus: Equatable {
    enum Kind: Equatable { case none, saved, adjusted, failed }
    var kind: Kind = .none
    var message: String = ""
    var actionTitle: String?
}

/// M6.1 — the settings page's state, as a `SettingsView` binds to it.
///
/// Every field is populated from `ConfigurationStore.shared.configuration`
/// by `refresh()`, and every setter writes back through
/// `ConfigurationStore.update` and calls `refresh()` again — so a value the
/// store clamped (or refused) reflects back into the field exactly like the
/// AppKit page's `commit()`/`populate()` round trip did, and an edit made in
/// `$EDITOR` while this window is open moves the controls the same way.
/// Unlike that page's one `commit()` for every control, each field here
/// writes on its own — SwiftUI's bindings write per keystroke/toggle, and
/// per-field validation is what that shape actually wants.
@MainActor
@Observable
final class SettingsModel {
    // MARK: - Config mirrors

    var theme: String = Theme.corta.name
    var appearance: Configuration.Appearance = .auto
    var fontFamily: String = Configuration.systemFontFamily
    var fontSize: Double = 12
    var scrollbackLines: Int = 10_000
    var columns: Int = 120
    var rows: Int = 30
    var bell: BellMode = .visual
    var optionAsMeta: Bool = false
    var openFileCommand: String = ""
    var copyOnSelect: Bool = true
    var linkActivation: Configuration.LinkActivation = .command
    var allowClipboardWrite: Bool = false
    var directoryHistory: Bool = true
    var restoreWindows: Bool = true
    var confirmClose: Bool = true
    var notifyOnLongTask: Bool = false
    var notificationThreshold: Double = 30

    /// The bell modes in the order the picker lists them.
    static let bellModes: [BellMode] = [.visual, .audible, .muted]

    /// The themes the picker currently lists, in `Theme.all(in:)`'s order —
    /// rebuilt on every `refresh()`, since the config file can define,
    /// rename or remove a theme while this window is open.
    var listedThemes: [Theme] = []

    // MARK: - Status rows

    var saveStatus = RowStatus()
    var fontStatus = RowStatus()
    var shellIntegrationStatus = RowStatus()
    var directoryHistoryStatus = RowStatus()
    var notificationPermissionNotice = RowStatus()

    private var clearTask: Task<Void, Never>?

    init() {
        refresh()
        NotificationCenter.default.addObserver(
            forName: ConfigurationStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NotificationCenter.default.addObserver(
            forName: ConfigurationStore.writeStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleWriteStatusChanged() }
        }
        NotificationCenter.default.addObserver(
            forName: TaskNotifier.permissionDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshNotificationPermissionNotice() }
        }
    }

    /// The file may not exist until something writes it, and System Settings
    /// can have flipped notification permission since this window was last
    /// open — both are re-read on every open rather than cached.
    func windowWillShow() {
        if !ConfigurationStore.shared.write() { reportWriteFailure() }
        TaskNotifier.refreshPermission()
        refresh()
    }

    func refresh() {
        let configuration = ConfigurationStore.shared.configuration
        listedThemes = Theme.all(in: configuration)
        theme = configuration.theme
        appearance = configuration.appearance
        fontFamily = configuration.fontFamily
        fontSize = configuration.fontSize
        scrollbackLines = configuration.scrollbackLines
        columns = configuration.columns
        rows = configuration.rows
        bell = configuration.bell
        optionAsMeta = configuration.optionAsMeta
        openFileCommand = configuration.openFileCommand
        copyOnSelect = configuration.copyOnSelect
        linkActivation = configuration.linkActivation
        allowClipboardWrite = configuration.allowClipboardWrite
        directoryHistory = configuration.directoryHistory
        restoreWindows = configuration.restoreWindows
        confirmClose = configuration.confirmClose
        notifyOnLongTask = configuration.notifyOnLongTask
        notificationThreshold = configuration.notificationThreshold
        refreshFontStatus()
        refreshShellIntegrationStatus()
        refreshDirectoryHistoryStatus()
        refreshNotificationPermissionNotice()
    }

    // MARK: - Derived display

    var fontFamilyDisplay: String {
        fontFamily == Configuration.systemFontFamily
            ? L10n.text("settings.font.systemMonospaced") : fontFamily
    }

    var previewTheme: Theme {
        Theme.named(theme, in: ConfigurationStore.shared.configuration) ?? .corta
    }

    var previewFont: CTFont {
        TerminalFont.primary(ofSize: fontSize, family: fontFamily)
    }

    var pathLabel: String { ConfigurationStore.fileURL.path }

    // MARK: - Setters

    func setTheme(_ name: String) {
        commit { configuration in
            configuration.theme = name
            return nil
        }
    }

    func setAppearance(_ value: Configuration.Appearance) {
        commit { configuration in
            configuration.appearance = value
            return nil
        }
    }

    func setFontSize(_ value: Double) {
        commit { configuration in
            let (clamped, message) = Self.clamp(value, 8, 64, label: L10n.text("settings.label.size"))
            configuration.fontSize = clamped
            return message
        }
    }

    func setScrollbackLines(_ value: Int) {
        commit { configuration in
            let (clamped, message) = Self.clamp(
                value, 0, 1_000_000, label: L10n.text("settings.label.scrollback"))
            configuration.scrollbackLines = clamped
            return message
        }
    }

    func setColumns(_ value: Int) {
        commit { configuration in
            let (clamped, message) = Self.clamp(value, 20, 500, label: L10n.text("settings.label.columns"))
            configuration.columns = clamped
            return message
        }
    }

    func setRows(_ value: Int) {
        commit { configuration in
            let (clamped, message) = Self.clamp(value, 5, 300, label: L10n.text("settings.label.rows"))
            configuration.rows = clamped
            return message
        }
    }

    func setBell(_ value: BellMode) {
        commit { configuration in
            configuration.bell = value
            return nil
        }
    }

    func setOptionAsMeta(_ value: Bool) {
        commit { configuration in
            configuration.optionAsMeta = value
            return nil
        }
    }

    /// Refused rather than written: the page is a front over the config
    /// file, and writing a template that cannot be launched would make the
    /// file say something the app will not do (U17).
    func setOpenFileCommand(_ value: String) {
        commit { configuration in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Configuration.isUsableOpenFileCommand(trimmed) else {
                return L10n.text("settings.status.openFileCommand")
            }
            configuration.openFileCommand = trimmed
            return nil
        }
    }

    func setCopyOnSelect(_ value: Bool) {
        commit { configuration in
            configuration.copyOnSelect = value
            return nil
        }
    }

    func setLinkActivation(_ value: Configuration.LinkActivation) {
        commit { configuration in
            configuration.linkActivation = value
            return nil
        }
    }

    func setAllowClipboardWrite(_ value: Bool) {
        commit { configuration in
            configuration.allowClipboardWrite = value
            return nil
        }
    }

    func setDirectoryHistory(_ value: Bool) {
        commit { configuration in
            configuration.directoryHistory = value
            return nil
        }
    }

    func setRestoreWindows(_ value: Bool) {
        commit { configuration in
            configuration.restoreWindows = value
            return nil
        }
    }

    func setConfirmClose(_ value: Bool) {
        commit { configuration in
            configuration.confirmClose = value
            return nil
        }
    }

    func setNotifyOnLongTask(_ value: Bool) {
        commit { configuration in
            configuration.notifyOnLongTask = value
            return nil
        }
    }

    func setNotificationThreshold(_ value: Double) {
        commit { configuration in
            let (clamped, message) = Self.clamp(
                value, 1, 86_400, label: L10n.text("settings.label.longerThan"))
            configuration.notificationThreshold = clamped
            return message
        }
    }

    /// One write path for every setter: mutate, re-read the whole page so a
    /// clamped or rejected value shows what the file actually says, then
    /// report what happened.
    private func commit(_ mutate: (inout Configuration) -> String?) {
        var message: String?
        let saved = ConfigurationStore.shared.update { configuration in
            message = mutate(&configuration)
        }
        refresh()
        if !saved {
            reportWriteFailure()
        } else if let message {
            setSaveStatus(RowStatus(kind: .adjusted, message: message))
        } else {
            setSaveStatus(RowStatus(kind: .saved, message: L10n.text("settings.status.saved")))
        }
    }

    /// A bound as a person would write it. The fields hold whole numbers, but
    /// the font size and the notification threshold are `Double` — so the
    /// unformatted description said "Size must be between 8.0 and 64.0",
    /// which reads as a precision the setting does not have.
    private static func plain(_ value: CustomStringConvertible) -> String {
        let text = value.description
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    private static func clamp<T: Comparable & CustomStringConvertible>(
        _ value: T, _ low: T, _ high: T, label: String
    ) -> (T, String?) {
        let result = min(high, max(low, value))
        guard result != value else { return (result, nil) }
        let message = L10n.format(
            "settings.status.clamped", label, plain(low), plain(high), plain(result))
        return (result, message)
    }

    /// A success or a clamp clears itself after a few seconds — it is a
    /// confirmation, not a condition. A failure stays: it describes a state
    /// the file is still in, and it carries the only action that can fix it.
    private func setSaveStatus(_ status: RowStatus) {
        clearTask?.cancel()
        saveStatus = status
        guard status.kind == .saved || status.kind == .adjusted else { return }
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.saveStatus = RowStatus()
        }
    }

    /// The write failed — a read-only home directory, a full disk, a
    /// `~/.config/corta` someone has made a symlink to nowhere. The page has
    /// already rolled the value back (`ConfigurationStore.update`), so the
    /// controls show what the file still says; this is what tells the user
    /// why their change did not take, and offers the one action that can
    /// help.
    private func reportWriteFailure() {
        clearTask?.cancel()
        let reason =
            ConfigurationStore.shared.lastWriteError?.localizedDescription
            ?? L10n.text("settings.status.writeFailedUnknown")
        saveStatus = RowStatus(
            kind: .failed, message: L10n.format("settings.status.writeFailed", reason),
            actionTitle: L10n.text("settings.status.retry"))
    }

    func retryWrite() {
        if ConfigurationStore.shared.write() {
            setSaveStatus(RowStatus(kind: .saved, message: L10n.text("settings.status.saved")))
        } else {
            reportWriteFailure()
        }
    }

    /// The store's write status changed from somewhere other than this page —
    /// an external edit that could not be re-serialised, or a retry that
    /// succeeded. Reflect it rather than leaving a stale failure on screen.
    private func handleWriteStatusChanged() {
        clearTask?.cancel()
        if ConfigurationStore.shared.lastWriteError != nil {
            reportWriteFailure()
        } else {
            saveStatus = RowStatus()
        }
    }

    /// Writes first and only reveals what it managed to write. Revealing a
    /// path whose write just failed points Finder at a file that does not
    /// say what the page says — or at no file at all on a first launch.
    func revealConfigFile() {
        guard ConfigurationStore.shared.write() else {
            reportWriteFailure()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([ConfigurationStore.fileURL])
    }

    // MARK: - Font status

    /// B09 — distinguishes a family AppKit knows nothing about from one that
    /// exists but fails the grid's uniform-advance check, rather than
    /// leaving both as an unexplained silent substitution.
    private func refreshFontStatus() {
        switch TerminalFont.resolution(forFamily: fontFamily) {
        case .resolved:
            fontStatus = RowStatus()
        case .missing(let requested):
            fontStatus = RowStatus(
                kind: .failed, message: L10n.format("settings.status.fontMissing", requested),
                actionTitle: L10n.text("settings.status.retry"))
        case .invalidForGrid(let requested):
            fontStatus = RowStatus(
                kind: .failed,
                message: L10n.format("settings.status.fontInvalidForGrid", requested),
                actionTitle: L10n.text("settings.status.retry"))
        }
    }

    /// The first call site `MonospacedFontCatalog.refresh()` has ever had —
    /// a font installed (or repaired) after this window opened is picked up
    /// on request rather than only after a relaunch.
    func retryFontResolution() {
        MonospacedFontCatalog.refresh()
        refreshFontStatus()
    }

    // MARK: - Shell integration

    /// B07 — reflects `ShellIntegrationInstaller`'s three states as an icon,
    /// a sentence and the one action that changes it. Read from disk on
    /// every refresh rather than cached: unlike every other row on this
    /// page, the ground truth here is `~/.zshrc`, which the user can edit
    /// outside Corta at any time.
    private func refreshShellIntegrationStatus() {
        switch ShellIntegrationInstaller.shared.status() {
        case .notInstalled:
            shellIntegrationStatus = RowStatus(
                kind: .adjusted,
                message: L10n.text("settings.status.shellIntegrationNotInstalled"),
                actionTitle: L10n.text("settings.action.install"))
        case .conflicting(let name):
            shellIntegrationStatus = RowStatus(
                kind: .failed,
                message: L10n.format("settings.status.shellIntegrationConflict", name),
                actionTitle: L10n.text("settings.action.installAnyway"))
        case .installed:
            shellIntegrationStatus = RowStatus(
                kind: .adjusted,
                message: L10n.format(
                    "settings.status.shellIntegrationInstalled",
                    ShellIntegrationInstaller.shared.displayPath),
                actionTitle: L10n.text("settings.action.remove"))
        }
    }

    /// One dispatch point for the row's one button, whichever of the three
    /// states put it there.
    func toggleShellIntegration() {
        switch ShellIntegrationInstaller.shared.status() {
        case .notInstalled, .conflicting:
            guard ShellIntegrationInstaller.shared.install() else {
                shellIntegrationStatus = RowStatus(
                    kind: .failed,
                    message: L10n.format(
                        "settings.status.shellIntegrationWriteFailed",
                        ShellIntegrationInstaller.shared.displayPath))
                return
            }
        case .installed:
            guard ShellIntegrationInstaller.shared.uninstall() else {
                shellIntegrationStatus = RowStatus(
                    kind: .failed,
                    message: L10n.format(
                        "settings.status.shellIntegrationWriteFailed",
                        ShellIntegrationInstaller.shared.displayPath))
                return
            }
        }
        refreshShellIntegrationStatus()
    }

    // MARK: - Directory history

    /// B08 — how many directories `DirectoryHistoryStore` currently
    /// remembers, with a Clear action. Re-read on every refresh, same reason
    /// as `refreshShellIntegrationStatus`: this is app-managed state, not
    /// something this window owns a copy of.
    private func refreshDirectoryHistoryStatus() {
        let count = DirectoryHistoryStore.shared.history.entries.count
        directoryHistoryStatus = RowStatus(
            kind: .adjusted, message: L10n.format("settings.status.directoryHistoryCount", count),
            actionTitle: count > 0 ? L10n.text("settings.action.clear") : nil)
    }

    func clearDirectoryHistory() {
        DirectoryHistoryStore.shared.clear()
        refreshDirectoryHistoryStatus()
    }

    // MARK: - Notification permission

    /// Shown only when the setting is on *and* the system has been told not
    /// to deliver — the one combination in which the switch's position is
    /// not the truth.
    private func refreshNotificationPermissionNotice() {
        let denied = TaskNotifier.permission == .denied
        guard notifyOnLongTask && denied else {
            notificationPermissionNotice = RowStatus()
            return
        }
        notificationPermissionNotice = RowStatus(
            kind: .failed, message: L10n.text("settings.status.notificationsDenied"),
            actionTitle: L10n.text("settings.status.openSystemSettings"))
    }

    func openSystemNotificationSettings() {
        TaskNotifier.openSystemNotificationSettings()
    }
}
