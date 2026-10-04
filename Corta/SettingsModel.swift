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
    var secondaryActionTitle: String?
}

/// The settings page's state, as a `SettingsView` binds to it.
///
/// Every field is populated from `ConfigurationStore.shared.configuration`
/// by `refresh()`, and every setter writes back through
/// `ConfigurationStore.update` and calls `refresh()` again — so a value the
/// store clamped (or refused) reflects back into the field exactly like the
/// AppKit page's `commit()`/`populate()` round trip did, and an edit made in
/// `$EDITOR` while this window is open moves the controls the same way.
/// Unlike that page's one `commit()` for every control, each field here
/// writes on its own — a toggle or picker on change, a numeric or text
/// field on commit — and per-field validation is what that shape wants.
@MainActor
@Observable
final class SettingsModel {
    // MARK: - Config mirrors

    var commandHistoryLimit = 512
    var mouseOverrideModifier: Configuration.MouseOverrideModifier = .option
    var searchCaseSensitive = false
    var searchRegex = false
    var updateAutoCheck = true
    var suggestApplicationsFolder = true
    var presets: [Preset] = []
    var keybindings = Keybindings()
    var availableFonts: [String] = []

    var statusBar = false
    var statusItems = Set(SystemMetrics.Item.allCases)
    var statusNetworkInterface = "auto"
    var theme: String = Theme.corta.name
    var inputSourceIndicatorPosition: Configuration.InputSourceIndicatorPosition = .toolbar
    var inputSourceIndicator: Configuration.InputSourceIndicatorMode = .auto
    var inputSourceDirectColor = ""
    var inputSourceIMEColor = ""
    var cursorShape: Configuration.CursorShape = .block
    var cursorBlink: Bool = false
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
    var directoryCompletion: Bool = true
    var commandStatusMarks: Bool = true
    var restoreWindows: Bool = true
    var confirmClose: Bool = true
    var notifyOnLongTask: Bool = false
    var notificationThreshold: Double = 30
    var quickTerminal: Bool = false
    var quickTerminalKey: Shortcut? = Shortcut.parse(Configuration.defaultQuickTerminalKey)
    var quickTerminalPosition: Configuration.QuickTerminalPosition = .top
    var quickTerminalScreen: Configuration.QuickTerminalScreen = .mouse
    var secureKeyboardEntry: Bool = false

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
    var recentHostsStatus = RowStatus()
    var notificationPermissionNotice = RowStatus()
    /// Which key summons the Quick Terminal, or why none does.
    var quickTerminalStatus = RowStatus()

    private var clearTask: Task<Void, Never>?
    private var notificationObservers: [NSObjectProtocol] = []

    /// What the page last mirrored. `commit` refreshes directly, and the
    /// store's `didChange` for that same write then arrives here too;
    /// without this the page refreshed twice per control change. An
    /// external edit differs from this and still refreshes.
    private var mirrored: Configuration?

    /// The family `fontStatus` was resolved for. Resolving is four CoreText
    /// faces and an advance measurement across the printable ASCII range
    /// (`MonospacedFontCatalog.isUsable`), so it is redone only when the
    /// family changes or `retryFontResolution` asks.
    private var resolvedFontFamily: String?

    /// What `previewFont` was built for, so a change to any other setting
    /// does not rebuild the face.
    private var previewedFont: (size: Double, family: String)?

    init() {
        refresh()
        followsSystemDark = AppearanceController.shared.isDark
        refreshExternalState()
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: AppearanceController.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.followsSystemDark = AppearanceController.shared.isDark }
        })
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: ConfigurationStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.storeDidChange() }
        })
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: ConfigurationStore.writeStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleWriteStatusChanged() }
        })
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: TaskNotifier.permissionDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshNotificationPermissionNotice() }
        })
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: QuickTerminalController.hotKeyStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshQuickTerminalStatus() }
        })
    }

    isolated deinit {
        clearTask?.cancel()
        for observer in notificationObservers { NotificationCenter.default.removeObserver(observer) }
    }

    /// The file may not exist until something writes it, and System Settings
    /// can have flipped notification permission since this window was last
    /// open — both are re-read on every open rather than cached. Called
    /// once per open, from `SettingsWindowController.show`.
    func windowWillShow() {
        if !ConfigurationStore.shared.write() { reportWriteFailure() }
        TaskNotifier.refreshPermission()
        refresh()
        refreshExternalState()
    }

    private func storeDidChange() {
        guard ConfigurationStore.shared.configuration != mirrored else { return }
        refresh()
    }

    /// Mirrors the store: every config field, and the rows derived from
    /// them. Not the rows whose truth is elsewhere on disk — see
    /// `refreshExternalState`.
    func refresh() {
        let configuration = ConfigurationStore.shared.configuration
        mirrored = configuration
        listedThemes = Theme.all(in: configuration)
        commandHistoryLimit = configuration.commandHistoryLimit
        mouseOverrideModifier = configuration.mouseOverrideModifier
        searchCaseSensitive = configuration.searchCaseSensitive
        searchRegex = configuration.searchRegex
        updateAutoCheck = configuration.updateAutoCheck
        suggestApplicationsFolder = configuration.suggestApplicationsFolder
        presets = configuration.presets
        keybindings = configuration.keybindings
        statusBar = configuration.statusBar
        statusItems = configuration.statusItems
        statusNetworkInterface = configuration.statusNetworkInterface
        theme = configuration.theme
        inputSourceIndicatorPosition = configuration.inputSourceIndicatorPosition
        inputSourceIndicator = configuration.inputSourceIndicator
        inputSourceDirectColor = configuration.inputSourceDirectColor
        inputSourceIMEColor = configuration.inputSourceIMEColor
        cursorShape = configuration.cursorShape
        cursorBlink = configuration.cursorBlink
        appearance = configuration.appearance
        fontFamily = Configuration.systemFontFamily
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
        directoryCompletion = configuration.directoryCompletion
        commandStatusMarks = configuration.commandStatusMarks
        restoreWindows = configuration.restoreWindows
        confirmClose = configuration.confirmClose
        notifyOnLongTask = configuration.notifyOnLongTask
        notificationThreshold = configuration.notificationThreshold
        quickTerminal = configuration.quickTerminal
        quickTerminalKey = configuration.quickTerminalKey
        quickTerminalPosition = configuration.quickTerminalPosition
        quickTerminalScreen = configuration.quickTerminalScreen
        secureKeyboardEntry = configuration.secureKeyboardEntry
        previewTheme = Theme.named(theme, in: configuration) ?? .corta
        if previewedFont?.size != fontSize || previewedFont?.family != fontFamily {
            refreshPreviewFont()
        }
        refreshQuickTerminalStatus()
        if fontFamily != resolvedFontFamily { refreshFontStatus() }
        refreshNotificationPermissionNotice()
    }

    private func refreshPreviewFont() {
        previewedFont = (fontSize, fontFamily)
        previewFont = TerminalFont.primary(ofSize: fontSize, family: fontFamily)
    }

    /// The rows whose ground truth is a file this page does not own —
    /// `~/.zshrc`, the directory history and the recent hosts. Read on open
    /// and on demand, not on every keystroke: a control change writes the
    /// config file, and nothing about that moves any of these.
    func refreshExternalState() {
        refreshShellIntegrationStatus()
        refreshDirectoryHistoryStatus()
        refreshRecentHostsStatus()
    }

    // MARK: - Derived display

    /// Explicit selection drives the preview immediately; AppKit appearance
    /// propagation and configuration notifications may arrive later.
    var previewIsDark: Bool {
        switch appearance {
        case .light: false
        case .dark: true
        case .auto: followsSystemDark
        }
    }
    private(set) var followsSystemDark = false

    var fontFamilyDisplay: String {
        fontFamily == Configuration.systemFontFamily
            ? L10n.text("settings.font.systemMonospaced") : fontFamily
    }

    /// Stored rather than computed: a computed `previewFont` re-resolved
    /// the face — the same measurement `refreshFontStatus` does — on every
    /// body evaluation, and the body is evaluated after every control
    /// change.
    private(set) var previewTheme: Theme = .corta
    private(set) var previewFont: CTFont = TerminalFont.primary(ofSize: 12)

    var pathLabel: String { ConfigurationStore.fileURL.path }

    // MARK: - Setters

    func setStatusBar(_ enabled: Bool) {
        commit { $0.statusBar = enabled; return nil }
    }
    func setStatusItem(_ item: SystemMetrics.Item, enabled: Bool) {
        commit { config in
            if enabled { config.statusItems.insert(item) } else { config.statusItems.remove(item) }
            return nil
        }
    }
    func setStatusNetworkInterface(_ value: String) {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let (parsed, unknown) = Configuration.parse("status-network-interface = \(name)")
        guard unknown.isEmpty else { return }
        commit { $0.statusNetworkInterface = parsed.statusNetworkInterface; return nil }
    }

    func setTheme(_ name: String) {
        commit { configuration in
            configuration.theme = name
            return nil
        }
    }

    func setInputSourceIndicator(_ value: Configuration.InputSourceIndicatorMode) {
        commit { configuration in
            configuration.inputSourceIndicator = value
            return nil
        }
    }

    func setInputSourceIndicatorPosition(_ value: Configuration.InputSourceIndicatorPosition) {
        commit { configuration in
            configuration.inputSourceIndicatorPosition = value
            return nil
        }
    }

    func setInputSourceColor(_ value: String, direct: Bool) {
        commit { configuration in
            guard let normalized = value.isEmpty ? "" : Theme.color(value).map(Theme.hex) else {
                return L10n.text("inputSource.color.invalid")
            }
            if direct { configuration.inputSourceDirectColor = normalized }
            else { configuration.inputSourceIMEColor = normalized }
            return nil
        }
    }

    func setCursorShape(_ value: Configuration.CursorShape) {
        commit { configuration in
            configuration.cursorShape = value
            return nil
        }
    }

    func setCursorBlink(_ value: Bool) {
        commit { configuration in
            configuration.cursorBlink = value
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
            let (clamped, message) = Self.clamp(
                value, 8, 64, label: L10n.text("settings.label.size"))
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
            let (clamped, message) = Self.clamp(
                value, 20, 500, label: L10n.text("settings.label.columns"))
            configuration.columns = clamped
            return message
        }
    }

    func setRows(_ value: Int) {
        commit { configuration in
            let (clamped, message) = Self.clamp(
                value, 5, 300, label: L10n.text("settings.label.rows"))
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
    /// file say something the app will not do.
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

    func setDirectoryCompletion(_ value: Bool) {
        commit { $0.directoryCompletion = value; return nil }
    }

    func setCommandStatusMarks(_ value: Bool) {
        commit { $0.commandStatusMarks = value; return nil }
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

    // MARK: - System entry points

    func setQuickTerminal(_ value: Bool) {
        commit { configuration in
            configuration.quickTerminal = value
            return nil
        }
    }

    func setQuickTerminalPosition(_ value: Configuration.QuickTerminalPosition) {
        commit { configuration in
            configuration.quickTerminalPosition = value
            return nil
        }
    }

    func setQuickTerminalScreen(_ value: Configuration.QuickTerminalScreen) {
        commit { configuration in
            configuration.quickTerminalScreen = value
            return nil
        }
    }

    func setSecureKeyboardEntry(_ value: Bool) {
        commit { configuration in
            configuration.secureKeyboardEntry = value
            return nil
        }
    }

    /// The hotkey line under the Quick Terminal toggle. The key itself is
    /// edited in the config file (`quick-terminal-key`), like every `bind.*`
    /// shortcut: a key-capture control would be a second editor for one
    /// value. What the page adds is the fact the file cannot show — whether
    /// the system actually granted the key.
    private func refreshQuickTerminalStatus() {
        guard quickTerminal else {
            quickTerminalStatus = RowStatus(
                kind: .none, message: L10n.text("settings.status.quickTerminalOff"))
            return
        }
        guard let key = quickTerminalKey else {
            quickTerminalStatus = RowStatus(
                kind: .adjusted, message: L10n.text("settings.status.quickTerminalNoKey"))
            return
        }
        if QuickTerminalController.shared.hotKeyRegistrationFailed {
            quickTerminalStatus = RowStatus(
                kind: .failed,
                message: L10n.format("settings.status.quickTerminalKeyTaken", key.displayText))
        } else {
            quickTerminalStatus = RowStatus(
                kind: .saved,
                message: L10n.format("settings.status.quickTerminalKey", key.displayText))
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

    /// Distinguishes a family AppKit knows nothing about from one that
    /// exists but fails the grid's uniform-advance check, rather than
    /// leaving both as an unexplained silent substitution.
    private func refreshFontStatus() {
        resolvedFontFamily = fontFamily
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
        refreshPreviewFont()
    }

    // MARK: - Shell integration

    /// Reflects `ShellIntegration`'s states as an icon,
    /// a sentence and the one action that changes it. Read from disk on
    /// every refresh rather than cached: unlike every other row on this
    /// page, the ground truth here is the shell's startup files — two for
    /// bash — which the user can edit outside Corta at any time.
    private func refreshShellIntegrationStatus() {
        let integration = ShellIntegration.current
        switch integration.status() {
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
                    "settings.status.shellIntegrationInstalled", integration.displayPath),
                actionTitle: L10n.text("settings.action.remove"))
        case .outdated:
            shellIntegrationStatus = RowStatus(
                kind: .adjusted,
                message: L10n.format(
                    "settings.status.shellIntegrationOutdated", integration.pathsNeedingUpdate),
                actionTitle: L10n.text("settings.action.update"),
                // Removing must not first require writing the new hooks in.
                secondaryActionTitle: L10n.text("settings.action.remove"))
        }
    }

    /// One dispatch point for the row's first button, whichever state put
    /// it there.
    func toggleShellIntegration() {
        let integration = ShellIntegration.current
        switch integration.status() {
        case .notInstalled, .conflicting, .outdated: applyShellIntegration(integration.install())
        case .installed: applyShellIntegration(integration.uninstall())
        }
    }

    /// The second button, offered only beside Update.
    func removeShellIntegration() {
        applyShellIntegration(ShellIntegration.current.uninstall())
    }

    /// - Parameter failures: the files that could not be written.
    private func applyShellIntegration(_ failures: [String]) {
        guard failures.isEmpty else {
            shellIntegrationStatus = RowStatus(
                kind: .failed,
                message: L10n.format(
                    "settings.status.shellIntegrationWriteFailed", failures.joined(separator: ", ")))
            return
        }
        refreshShellIntegrationStatus()
    }

    // MARK: - Directory history

    /// How many directories `DirectoryHistoryStore` currently
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

    // MARK: - Recent hosts

    /// How many hosts the connect dialogs remember, with a Clear action —
    /// app state like the directory history, re-read on every refresh.
    private func refreshRecentHostsStatus() {
        let count = RecentHostsStore.shared.hosts.count
        recentHostsStatus = RowStatus(
            kind: .adjusted, message: L10n.format("settings.recentHosts.count", count),
            actionTitle: count > 0 ? L10n.text("settings.action.clear") : nil)
    }

    func clearRecentHosts() {
        RecentHostsStore.shared.clear()
        refreshRecentHostsStatus()
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

// Editors share the existing config-file write and rollback path.
extension SettingsModel {
    func editConfigFile() {
        if ConfigurationStore.shared.write() { NSWorkspace.shared.open(ConfigurationStore.fileURL) }
        else { reportWriteFailure() }
    }

    func loadFonts() async {
        availableFonts = []
    }

    func setFontFamily(_ value: String) {
        commit { configuration in
            configuration.fontFamily = Configuration.systemFontFamily
            return nil
        }
    }

    func setCommandHistoryLimit(_ value: Int) {
        commit { configuration in
            let (limit, message) = Self.clamp(value, 0, 10_000, label: L10n.text("ui.history.commands"))
            configuration.commandHistoryLimit = limit
            return message
        }
    }

    func setMouseOverrideModifier(_ value: Configuration.MouseOverrideModifier) {
        commit { $0.mouseOverrideModifier = value; return nil }
    }
    func setSearchCaseSensitive(_ value: Bool) {
        commit { $0.searchCaseSensitive = value; return nil }
    }
    func setSearchRegex(_ value: Bool) {
        commit { $0.searchRegex = value; return nil }
    }
    func setUpdateAutoCheck(_ value: Bool) {
        commit { $0.updateAutoCheck = value; return nil }
    }
    func setSuggestApplicationsFolder(_ value: Bool) {
        commit { $0.suggestApplicationsFolder = value; return nil }
    }
    func setQuickTerminalKey(_ value: Shortcut?) {
        commit { configuration in
            guard value == nil || !value!.modifiers.intersection([.command, .control, .option, .shift]).isEmpty else {
                return L10n.text("ui.shortcut.modifierRequired")
            }
            configuration.quickTerminalKey = value
            return nil
        }
    }
    func setShortcut(_ value: Shortcut?, for command: TerminalCommand) {
        commit { configuration in
            if let value, TerminalCommand.allCases.contains(where: { $0 != command && configuration.keybindings[$0] == value }) {
                return L10n.text("ui.shortcut.conflict")
            }
            configuration.keybindings[command] = value
            return nil
        }
    }
    func resetShortcut(_ command: TerminalCommand) {
        commit { $0.keybindings.reset(command); return nil }
    }
    func savePreset(_ preset: Preset, replacing originalName: String?) -> Bool {
        guard Self.validPresetName(preset.name), preset.isUsable,
            !presets.contains(where: { $0.name == preset.name && $0.name != originalName }) else { return false }
        commit { configuration in
            if let index = configuration.presets.firstIndex(where: { $0.name == originalName }) {
                configuration.presets[index] = preset
            } else { configuration.presets.append(preset) }
            return nil
        }
        return presets.contains(preset)
    }
    nonisolated static func validPresetName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains(where: { $0.isWhitespace || $0 == "." || $0 == "=" || $0 == "#" || $0.isNewline || $0 == "\0" })
    }
    func removePreset(_ name: String) {
        commit { $0.presets.removeAll { $0.name == name }; return nil }
    }
}
