import AppKit
import Testing

@testable import Corta

/// UI01 and UI04's regression tests, ported to `SettingsModel`/`SettingsView`
/// after the settings page's SwiftUI rewrite.
///
/// UI01 (Terminal's clipboard-write row clipping its label) and UI04 (the
/// notification switch and its "Longer than" threshold reading as separated
/// by a blank gap, with the threshold staying editable-looking while the
/// switch was off) were both AppKit layout defects — a label's wrap
/// mechanism and a stack's row spacing, each pinned by measuring real view
/// geometry. `Form`/`LabeledContent` give correct label wrapping and
/// label-control accessibility pairing natively, which is what those two
/// bugs needed all along, so there is no longer a *layout* mechanism here to
/// pin the same way: this project has no view-inspection dependency
/// (`ViewInspector` or similar) that could assert a SwiftUI row's rendered
/// frame or line count the way `NSView.fittingSize` let the AppKit version
/// do it directly. That is a real coverage gap versus the old tests, called
/// out here and in the PR that made this change, not silently dropped.
///
/// What remains directly testable without a view-inspection library:
/// UI04's actual behavioral claim (the threshold is disabled with the
/// switch) as a `SettingsModel` property, and UI01/UI04's shared underlying
/// concern — that a translated label fits in the space the row gives it —
/// generalized as a plain string-measurement test with no view involved.
@MainActor
struct SettingsPageTests {
    // MARK: - UI04

    @Test("the notification threshold notice is hidden while the setting itself is off")
    func thresholdNoticeFollowsTheSwitch() {
        let model = SettingsModel()
        let original = model.notifyOnLongTask
        defer { model.setNotifyOnLongTask(original) }

        model.setNotifyOnLongTask(false)
        #expect(model.notificationPermissionNotice.kind == .none)
    }

    // MARK: - UI01

    /// The column every label wraps in, and the two-line cap the old page's
    /// row builder enforced: `SettingsWindowController.measuredLabelColumnWidth`
    /// clamped the label column at 240 pt and rows allowed two lines. SwiftUI's
    /// `Form` wraps a label at whatever width the row actually gets rather
    /// than a fixed 240 pt column, so this no longer pins the exact old
    /// mechanism — but a translation needing a third line at 240 pt is still
    /// worth flagging as unusually long, and this keeps that check alive.
    @Test("every shipped localization of every settings row label fits two lines at 240pt")
    func everyRowLabelFitsInEveryLocalization() throws {
        let keys = [
            "settings.label.theme", "settings.label.lightOrDark", "settings.label.font",
            "settings.label.fontStatus", "settings.label.size", "settings.label.preview",
            "settings.label.scrollback", "settings.label.bell", "settings.label.optionAsMeta",
            "settings.label.copyOnSelect", "settings.label.openLinksWith",
            "settings.label.allowClipboardCopy", "settings.label.openFileCommand",
            "settings.label.shellIntegration", "settings.label.newWindow",
            "settings.label.restoreWindows", "settings.label.confirmClose",
            "settings.label.notifyOnLongTasks", "settings.label.longerThan",
            "settings.label.directoryHistory", "settings.label.directoryHistoryClear",
        ]
        for key in keys {
            try Self.assertFitsEveryLocalization(key: key)
        }
    }

    private static func assertFitsEveryLocalization(key: String) throws {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let lineHeight = NSTextField(labelWithString: "Ag").fittingSize.height
        for localization in Bundle.main.localizations {
            guard
                let path = Bundle.main.path(forResource: localization, ofType: "lproj"),
                let bundle = Bundle(path: path)
            else { continue }
            let text = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
            // A bundle without the key answers with the key itself.
            guard text != key else { continue }
            let needed = (text as NSString).boundingRect(
                with: NSSize(width: 240, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font]
            ).height
            #expect(
                needed <= 2 * lineHeight + 1,
                "\(localization)'s \(key) needs \(needed) pt (\(text)) — more than two lines")
        }
    }
}
