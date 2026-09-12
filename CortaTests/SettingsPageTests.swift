import AppKit
import Testing

@testable import Corta

/// UI01 and UI04 — the settings page's rendering and grouping regressions.
///
/// UI01: Terminal's clipboard-write row clipped its label. The fix is a
/// short label that wraps to two lines over an explanation line, with the row
/// growing to fit; these tests pin the mechanism (wrapping, row height) and
/// sweep every shipped localization for one that would need a third line.
///
/// UI04: General's notification switch and its "Longer than" threshold were
/// separated by a blank gap, and the threshold stayed editable-looking while
/// the switch was off. These tests pin the visible gaps to the stack's row
/// spacing and the disabled state to cover the whole row.
@MainActor
struct SettingsPageTests {
    /// Every nested subview, depth-first.
    private static func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }

    /// Builds and shows a settings tab by performing its toolbar item's
    /// action. The panes are lazy and the tab type is private, so the
    /// toolbar delegate — the same path a click takes — is the way in.
    @discardableResult
    private static func showTab(_ rawValue: String) throws -> NSWindow {
        let controller = SettingsWindowController.shared
        let window = try #require(controller.window)
        let toolbar = try #require(window.toolbar)
        let identifier = NSToolbarItem.Identifier("dev.noahqin.Corta.settings.\(rawValue)")
        let item = try #require(
            controller.toolbar(
                toolbar, itemForItemIdentifier: identifier, willBeInsertedIntoToolbar: false))
        _ = controller.perform(try #require(item.action), with: item)
        // TaskNotifier's permission read completes asynchronously and can
        // unhide the permission-notice row a runloop turn later, and the tab
        // switch resizes the window with an animation — let both settle
        // before measuring anything, so the pane is in its final shape
        // rather than mid-transition.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    /// The control a settings row was built around, found by the label the
    /// row gave it, and the row container that holds both.
    private static func row(labeled label: String, in window: NSWindow) throws -> (
        row: NSView, control: NSView, label: NSTextField
    ) {
        let content = try #require(window.contentView)
        // The control, not its title: a row's label answers its own text to
        // `accessibilityLabel()` too, so the match is pinned to the view the
        // label was made the title *of*.
        let control = try #require(
            allSubviews(of: content).first {
                $0.accessibilityLabel() == label && $0.accessibilityTitleUIElement() != nil
            },
            "no control labeled \(label)")
        let title = try #require(
            control.accessibilityTitleUIElement() as? NSTextField,
            "the control must name its label for VoiceOver")
        return (try #require(title.superview), control, title)
    }

    // MARK: - UI01

    @Test("the clipboard-write row draws its whole label, with the explanation under it")
    func clipboardRowShowsFullLabelAndExplanation() throws {
        let window = try Self.showTab("terminal")
        let (row, _, title) = try Self.row(
            labeled: L10n.text("settings.label.allowClipboardCopy"), in: window)

        // The mechanism the fix rests on: a long label wraps instead of
        // truncating, and the row's height grows to contain the wrap.
        #expect(title.lineBreakMode == .byWordWrapping)
        #expect(title.maximumNumberOfLines >= 2)
        let needed = (title.stringValue as NSString).boundingRect(
            with: NSSize(width: title.frame.width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: title.font ?? .systemFont(ofSize: NSFont.systemFontSize)]
        ).height
        #expect(
            title.frame.height + 1 >= needed,
            "the label needs \(needed) pt but its frame has \(title.frame.height) pt")

        // The short label alone does not say what the switch permits; the
        // explanation line is part of the fix.
        #expect(
            Self.allSubviews(of: row).contains {
                ($0 as? NSTextField)?.stringValue == L10n.text("settings.help.allowClipboardCopy")
            },
            "the row must carry its explanation line")
    }

    @Test("every shipped localization of the clipboard-write label fits the two-line row")
    func clipboardLabelFitsInEveryLocalization() throws {
        try Self.assertFitsEveryLocalization(key: "settings.label.allowClipboardCopy")
    }

    /// B09 — the same check as `clipboardLabelFitsInEveryLocalization`,
    /// generalized to every row label on the settings page rather than just
    /// the one that was reported broken. New rows (like B09's own Font
    /// Status and Preview) get the same guarantee for free the moment their
    /// key is added to this list, instead of waiting for a second report.
    @Test("every shipped localization of every settings row label fits its two-line row")
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

    /// The column every label wraps in, and the two-line cap it wraps under:
    /// `SettingsWindowController.measuredLabelColumnWidth` clamps the label
    /// column at 240 pt and rows allow two lines. A translation that needs a
    /// third line in 240 pt would clip exactly like the originally reported
    /// defect (UI01).
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

    // MARK: - UI04

    @Test("the notification switch and its threshold sit one row spacing apart")
    func notificationGroupHasNoBlankGap() throws {
        let window = try Self.showTab("general")
        let (notifyRow, _, _) = try Self.row(
            labeled: L10n.text("settings.label.notifyOnLongTasks"), in: window)
        let (thresholdRow, _, _) = try Self.row(
            labeled: L10n.text("settings.label.longerThan"), in: window)
        let stack = try #require(notifyRow.superview as? NSStackView)
        // The threshold row must hang off the same stack — the pane lays its
        // rows out in one.
        try #require(thresholdRow.superview === stack)

        // The permission notice may sit between the two; it is a real row
        // when shown, not a gap. What must not exist is *space*: every
        // visible step from the switch to the threshold is one row spacing.
        let visible = stack.arrangedSubviews.filter { !$0.isHidden }
        let from = try #require(visible.firstIndex(of: notifyRow))
        let to = try #require(visible.firstIndex(of: thresholdRow))
        #expect(to > from, "the threshold must sit under the switch it belongs to")
        for index in from..<to {
            // Arranged top-to-bottom in y-up coordinates: the row below sits
            // at the smaller y, so the gap is this row's bottom minus the
            // next row's top.
            let gap = visible[index].frame.minY - visible[index + 1].frame.maxY
            #expect(
                abs(gap - stack.spacing) <= 0.5,
                "row gap is \(gap) pt, expected the stack's \(stack.spacing) pt")
        }
    }

    @Test("the threshold row disables and dims with the notification switch")
    func thresholdRowFollowsTheSwitch() throws {
        let window = try Self.showTab("general")
        let controller = SettingsWindowController.shared
        let (row, _, label) = try Self.row(
            labeled: L10n.text("settings.label.longerThan"), in: window)
        let field = try #require(
            Self.allSubviews(of: row).first { ($0 as? NSTextField)?.isEditable == true }
                as? NSTextField)
        let suffix = try #require(
            Self.allSubviews(of: row).first {
                ($0 as? NSTextField)?.stringValue == L10n.text("settings.label.seconds")
            } as? NSTextField)
        // Leave the shared window as the config file says, for the next test.
        defer {
            controller.applyThresholdState(
                enabled: ConfigurationStore.shared.configuration.notifyOnLongTask)
        }

        controller.applyThresholdState(enabled: false)
        #expect(!field.isEnabled)
        #expect(label.textColor == .disabledControlTextColor)
        #expect(suffix.textColor == .disabledControlTextColor)

        controller.applyThresholdState(enabled: true)
        #expect(field.isEnabled)
        #expect(label.textColor == .labelColor)
        #expect(suffix.textColor == .labelColor)
    }
}
