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
@dynamicMemberLookup
final class SettingsModel {
    // MARK: - Config mirror

    /// Bumped per font load, so a slower earlier load cannot land last.
    private var fontLoadGeneration = 0

    /// The store's configuration as of the last `refresh()`. Controls read
    /// through it (`model.copyOnSelect` is `configuration.copyOnSelect`) and
    /// write through `set` or a setter below — never into it directly.
    private(set) var configuration = Configuration()

    subscript<Value>(dynamicMember path: KeyPath<Configuration, Value>) -> Value {
        configuration[keyPath: path]
    }

    /// The bell modes in the order the picker lists them.
    static let bellModes: [BellMode] = [.visual, .audible, .muted]

    /// The themes the picker currently lists, in `Theme.all(in:)`'s order —
    /// rebuilt on every `refresh()`, since the config file can define,
    /// rename or remove a theme while this window is open.
    var listedThemes: [Theme] = []

    /// The families the font picker lists, from `MonospacedFontCatalog` —
    /// empty until `loadFonts()` has measured them off the main thread.
    private(set) var availableFonts: [MonospacedFontCatalog.Entry] = []

    /// The families the CJK font picker lists (`MonospacedFontCatalog.cjkEntries`),
    /// loaded with `availableFonts`.
    private(set) var availableCJKFonts: [MonospacedFontCatalog.Entry] = []

    /// Why the configured CJK family is not the one drawn, or empty: the
    /// cascade skips one that is not installed or has no CJK, and says so
    /// here rather than silently. Stored, like `fontStatus`, so a body
    /// evaluation never measures a font.
    private(set) var cjkFontNotice = ""

    /// Where the chosen font comes from, and whether it brings its own CJK
    /// design — shown under the picker. Empty while `fontStatus` reports a
    /// fallback, which says more.
    private(set) var fontDetail = ""

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

    /// What `previewFont` was built for, so a change to any other setting
    /// does not rebuild the face.
    private var previewedFont: (size: Double, style: FontStyle)?

    /// The family `fontStatus` was resolved for. Resolving measures four
    /// faces across printable ASCII (`MonospacedFontCatalog.isUsable`), so
    /// it is redone only when the family or the installed fonts change.
    private var resolvedFontFamily: String?

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
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: NSFont.fontSetChangedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.fontsDidChange() }
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
        // `commit` refreshes directly, and the store's `didChange` for that
        // same write arrives here too: without this the page refreshed twice
        // per control change. An external edit differs and still refreshes.
        guard ConfigurationStore.shared.configuration != configuration else { return }
        refresh()
    }

    /// Mirrors the store: every config field, and the rows derived from
    /// them. Not the rows whose truth is elsewhere on disk — see
    /// `refreshExternalState`.
    func refresh() {
        let configuration = ConfigurationStore.shared.configuration
        self.configuration = configuration
        listedThemes = Theme.all(in: configuration)
        previewTheme = Theme.named(configuration.theme, in: configuration) ?? .corta
        if previewedFont?.size != configuration.fontSize || previewedFont?.style != FontStyle(configuration) {
            refreshPreviewFont()
        }
        if configuration.fontFamily != resolvedFontFamily { refreshFontStatus() }
        refreshCJKFontNotice()
        refreshQuickTerminalStatus()
        refreshNotificationPermissionNotice()
    }

    private func refreshPreviewFont() {
        previewedFont = (configuration.fontSize, FontStyle(configuration))
        previewFont = FontStyle(configuration).font(ofSize: configuration.fontSize)
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
        switch configuration.appearance {
        case .light: false
        case .dark: true
        case .auto: followsSystemDark
        }
    }
    private(set) var followsSystemDark = false

    /// Stored rather than computed: a computed `previewFont` re-resolved
    /// the face — the same measurement `refreshFontStatus` does — on every
    /// body evaluation, and the body is evaluated after every control
    /// change.
    private(set) var previewTheme: Theme = .corta
    private(set) var previewFont: CTFont = TerminalFont.primary(ofSize: 12)

    var pathLabel: String { ConfigurationStore.fileURL.path }

    // MARK: - Setters

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

    func setInputSourceColor(_ value: String, direct: Bool) {
        commit { configuration in
            guard let normalized = value.isEmpty ? "" : Theme.color(value).map(Theme.hex) else {
                return L10n.text("inputSource.color.invalid")
            }
            if direct {
                configuration.inputSourceDirectColor = normalized
            } else {
                configuration.inputSourceIMEColor = normalized
            }
            return nil
        }
    }

    /// Refused unless the grid can lay the family out, the rule
    /// `TerminalFont.primary` applies: writing one it would not use would
    /// make the file say something the app will not do.
    func setFontFamily(_ value: String) {
        commit { configuration in
            guard value == Configuration.systemFontFamily || MonospacedFontCatalog.isUsable(family: value) else {
                return L10n.text("ui.font.invalid")
            }
            configuration.fontFamily = value
            return nil
        }
    }

    /// Refused unless the family can draw CJK, the rule the cascade applies.
    func setCJKFontFamily(_ value: String) {
        commit { configuration in
            guard value == Configuration.automaticCJKFontFamily || MonospacedFontCatalog.isUsableCJK(family: value)
            else { return L10n.text("ui.font.invalid") }
            configuration.cjkFontFamily = value
            return nil
        }
    }

    func setLineSpacing(_ value: Double) {
        commit { $0.lineSpacing = Configuration.snappedLineSpacing(value); return nil }
    }

    func setFontSize(_ value: Double) {
        set(\.fontSize, value, clampedTo: Configuration.fontSizeRange, label: L10n.text("settings.label.size"))
    }

    func setScrollbackLines(_ value: Int) {
        set(
            \.scrollbackLines, value, clampedTo: Configuration.scrollbackLinesRange,
            label: L10n.text("settings.label.scrollback"))
    }

    func setColumns(_ value: Int) {
        set(\.columns, value, clampedTo: Configuration.columnsRange, label: L10n.text("settings.label.columns"))
    }

    func setRows(_ value: Int) {
        set(\.rows, value, clampedTo: Configuration.rowsRange, label: L10n.text("settings.label.rows"))
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
}

// MARK: - System entry points

extension SettingsModel {

    /// The hotkey line under the Quick Terminal toggle. The key itself is
    /// edited in the config file (`quick-terminal-key`), like every `bind.*`
    /// shortcut: a key-capture control would be a second editor for one
    /// value. What the page adds is the fact the file cannot show — whether
    /// the system actually granted the key.
    private func refreshQuickTerminalStatus() {
        guard configuration.quickTerminal else {
            quickTerminalStatus = RowStatus(
                kind: .none, message: L10n.text("settings.status.quickTerminalOff"))
            return
        }
        guard let key = configuration.quickTerminalKey else {
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

    func setNotificationThreshold(_ value: Double) {
        set(
            \.notificationThreshold, value, clampedTo: Configuration.notificationThresholdRange,
            label: L10n.text("settings.label.longerThan"))
    }

    /// A field written as given.
    func set<Value>(_ path: WritableKeyPath<Configuration, Value>, _ value: Value) {
        commit { $0[keyPath: path] = value; return nil }
    }

    /// A numeric field the file clamps: the nearest value in `range` is
    /// written, and the page says so.
    private func set<Value: Comparable & CustomStringConvertible>(
        _ path: WritableKeyPath<Configuration, Value>, _ value: Value,
        clampedTo range: ClosedRange<Value>, label: String
    ) {
        commit { configuration in
            let (clamped, message) = Self.clamp(value, range.lowerBound, range.upperBound, label: label)
            configuration[keyPath: path] = clamped
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
        // An unreadable file is shown as it is: opening it to fix it is the
        // remedy, and a write is refused until it reads again.
        if ConfigurationStore.shared.readError != nil {
            NSWorkspace.shared.activateFileViewerSelecting([ConfigurationStore.fileURL])
            return
        }
        guard ConfigurationStore.shared.write() else {
            reportWriteFailure()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([ConfigurationStore.fileURL])
    }

    // MARK: - Font

    func loadFonts() async {
        await loadFonts(
            monospaced: { await MonospacedFontCatalog.loadEntries() },
            cjk: { await MonospacedFontCatalog.loadCJKEntries() })
    }

    func loadFonts(
        monospaced: @Sendable () async -> [MonospacedFontCatalog.Entry],
        cjk: @Sendable () async -> [MonospacedFontCatalog.Entry]
    ) async {
        fontLoadGeneration &+= 1
        let generation = fontLoadGeneration
        async let primary = monospaced()
        async let fallback = cjk()
        let result = await (primary, fallback)
        guard !Task.isCancelled, generation == fontLoadGeneration else { return }
        (availableFonts, availableCJKFonts) = result
    }

    /// Empty while fallback is off: no CJK font is used then, chosen or not.
    private func refreshCJKFontNotice() {
        let family = configuration.cjkFontFamily
        guard configuration.fontFallback, family != Configuration.automaticCJKFontFamily,
            !MonospacedFontCatalog.isUsableCJK(family: family)
        else {
            cjkFontNotice = ""
            return
        }
        cjkFontNotice = L10n.format("settings.status.cjkFontUnavailable", family)
    }

    /// A font installed or removed while this window is open: the list, the
    /// row and the preview all follow without a relaunch.
    private func fontsDidChange() async {
        MonospacedFontCatalog.refresh()
        refreshFontStatus()
        refreshCJKFontNotice()
        refreshPreviewFont()
        await loadFonts()
    }

    /// Tells a family AppKit does not know from one that exists but fails
    /// the grid's check — both fall back to System Monospaced, and neither
    /// should do it silently.
    private func refreshFontStatus() {
        resolvedFontFamily = configuration.fontFamily
        fontDetail = ""
        switch TerminalFont.resolution(forFamily: configuration.fontFamily) {
        case .resolved:
            fontStatus = RowStatus()
            fontDetail = Self.detail(forFamily: configuration.fontFamily)
            return
        case .missing(let requested):
            fontStatus = RowStatus(
                kind: .failed, message: L10n.format("settings.status.fontMissing", requested),
                actionTitle: L10n.text("settings.status.retry"))
        case .invalidForGrid(let requested):
            fontStatus = RowStatus(
                kind: .failed, message: L10n.format("settings.status.fontInvalidForGrid", requested),
                actionTitle: L10n.text("settings.status.retry"))
        }
    }

    func retryFontResolution() {
        Task { await fontsDidChange() }
    }
}

// Editors share the existing config-file write and rollback path.
extension SettingsModel {
    func setCommandHistoryLimit(_ value: Int) {
        set(
            \.commandHistoryLimit, value, clampedTo: Configuration.commandHistoryLimitRange,
            label: L10n.text("ui.history.commands"))
    }

    func setQuickTerminalKey(_ value: Shortcut?) {
        commit { configuration in
            // The rule the hotkey registration and the config parser apply.
            guard value.map(GlobalHotKey.isRegistrable) ?? true else {
                return L10n.text("ui.shortcut.modifierRequired")
            }
            configuration.quickTerminalKey = value
            return nil
        }
    }
    func setShortcut(_ value: Shortcut?, for command: TerminalCommand) {
        commit { configuration in
            if let value,
                TerminalCommand.allCases.contains(where: { $0 != command && configuration.keybindings[$0] == value })
            {
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
            !configuration.presets.contains(where: { $0.name == preset.name && $0.name != originalName })
        else { return false }
        commit { configuration in
            if let index = configuration.presets.firstIndex(where: { $0.name == originalName }) {
                configuration.presets[index] = preset
            } else { configuration.presets.append(preset) }
            return nil
        }
        return configuration.presets.contains(preset)
    }
    nonisolated static func validPresetName(_ name: String) -> Bool {
        !name.isEmpty
            && !name.contains(where: {
                $0.isWhitespace || $0 == "." || $0 == "=" || $0 == "#" || $0.isNewline || $0 == "\0"
            })
    }
    func removePreset(_ name: String) {
        commit { $0.presets.removeAll { $0.name == name }; return nil }
    }
}
