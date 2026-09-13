import Testing

@testable import Corta

/// `SettingsModel`'s clamping and validation, tested directly rather than
/// through a live window and its toolbar delegate the way the AppKit page's
/// `SettingsPageTests` used to have to. `SettingsModel` writes through
/// `ConfigurationStore.shared`, the same store the old controller wrote
/// through, so these tests restore whatever they change.
@MainActor
struct SettingsModelTests {
    @Test("a scrollback value outside 0...1,000,000 is clamped and reported")
    func scrollbackIsClamped() {
        let model = SettingsModel()
        let original = model.scrollbackLines
        defer { model.setScrollbackLines(original) }

        model.setScrollbackLines(-5)
        #expect(model.scrollbackLines == 0)
        #expect(model.saveStatus.kind == .adjusted)

        model.setScrollbackLines(2_000_000)
        #expect(model.scrollbackLines == 1_000_000)
        #expect(model.saveStatus.kind == .adjusted)
    }

    @Test("a font size outside 8...64 is clamped")
    func fontSizeIsClamped() {
        let model = SettingsModel()
        let original = model.fontSize
        defer { model.setFontSize(original) }

        model.setFontSize(2)
        #expect(model.fontSize == 8)

        model.setFontSize(200)
        #expect(model.fontSize == 64)
    }

    @Test("columns and rows are clamped to their grid bounds")
    func columnsAndRowsAreClamped() {
        let model = SettingsModel()
        let originalColumns = model.columns
        let originalRows = model.rows
        defer {
            model.setColumns(originalColumns)
            model.setRows(originalRows)
        }

        model.setColumns(1)
        #expect(model.columns == 20)
        model.setColumns(10_000)
        #expect(model.columns == 500)

        model.setRows(0)
        #expect(model.rows == 5)
        model.setRows(10_000)
        #expect(model.rows == 300)
    }

    @Test("the notification threshold is clamped to 1...86,400 seconds")
    func notificationThresholdIsClamped() {
        let model = SettingsModel()
        let original = model.notificationThreshold
        defer { model.setNotificationThreshold(original) }

        model.setNotificationThreshold(0)
        #expect(model.notificationThreshold == 1)

        model.setNotificationThreshold(1_000_000)
        #expect(model.notificationThreshold == 86_400)
    }

    @Test("a value inside every bound is written unchanged and reported as saved, not adjusted")
    func valueInBoundsIsNotClamped() {
        let model = SettingsModel()
        let original = model.fontSize
        defer { model.setFontSize(original) }

        model.setFontSize(16)
        #expect(model.fontSize == 16)
        #expect(model.saveStatus.kind == .saved)
    }

    // MARK: - U17: the open-file command

    @Test("an open-file command whose first word isn't an absolute path is refused")
    func openFileCommandRejectsRelativePath() {
        let model = SettingsModel()
        let original = model.openFileCommand
        defer { model.setOpenFileCommand(original) }

        model.setOpenFileCommand("code {file}:{line}")
        #expect(model.openFileCommand == original, "the unusable template must not be written")
        #expect(model.saveStatus.kind == .adjusted)
    }

    @Test("an open-file command naming an unknown placeholder is refused")
    func openFileCommandRejectsUnknownPlaceholder() {
        let model = SettingsModel()
        let original = model.openFileCommand
        defer { model.setOpenFileCommand(original) }

        model.setOpenFileCommand("/usr/bin/open {oops}")
        #expect(model.openFileCommand == original)
        #expect(model.saveStatus.kind == .adjusted)
    }

    @Test("a usable open-file command is written")
    func openFileCommandAcceptsUsableTemplate() {
        let model = SettingsModel()
        let original = model.openFileCommand
        defer { model.setOpenFileCommand(original) }

        model.setOpenFileCommand("/usr/bin/open {file}:{line}")
        #expect(model.openFileCommand == "/usr/bin/open {file}:{line}")
        #expect(model.saveStatus.kind == .saved)
    }

    // MARK: - Conditional visibility

    @Test("listedThemes mirrors what the config file actually defines")
    func listedThemesMirrorsTheStore() {
        let model = SettingsModel()
        // `SettingsView` hides the theme row when this is under two — this
        // pins that `listedThemes` is a live read of the store rather than
        // a value that could go stale, which is what the row's visibility
        // actually depends on.
        #expect(model.listedThemes.map(\.name) == Theme.all(in: ConfigurationStore.shared.configuration).map(\.name))
    }

    @Test("the notification-permission notice never shows while the setting itself is off")
    func notificationNoticeHiddenWhenSettingOff() {
        let model = SettingsModel()
        let original = model.notifyOnLongTask
        defer { model.setNotifyOnLongTask(original) }

        model.setNotifyOnLongTask(false)
        #expect(model.notificationPermissionNotice.kind == .none)
    }

    @Test("the directory-history clear action is offered only when there is history to clear")
    func directoryHistoryActionFollowsCount() {
        let model = SettingsModel()
        let hasHistory = DirectoryHistoryStore.shared.history.entries.count > 0
        #expect((model.directoryHistoryStatus.actionTitle != nil) == hasHistory)
    }
}
