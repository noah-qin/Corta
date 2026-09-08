import AppKit
import CortaTerminal
import Testing

@testable import Corta

/// U09 — the screens Corta shows when something it depends on is not there.
///
/// This is the one part of the app that has to work when the rest does not,
/// which is exactly why it is the part least likely to be exercised by hand:
/// reproducing "the login shell was uninstalled" or "the volume was
/// unmounted" on a working machine takes deliberate effort, and the panel is
/// invisible in every render test. The contract is asserted here instead.
@MainActor
@Suite(.serialized, .sessionRestoreSerialized)
struct RecoveryUITests {
    // MARK: - The failure panel

    /// Failure is signalled by the symbol *and* the words. A red panel says
    /// nothing to a person who cannot separate red from grey, and this is the
    /// screen that has to stay readable when everything else is broken.
    @Test func theFailurePanelNamesTheFailureInWordsNotColour() {
        let view = PaneFailureView(
            title: "Could not start a shell", detail: "No such file or directory",
            canRetry: true)
        let label = try! #require(view.accessibilityLabel())
        #expect(label.contains("Could not start a shell"))
        #expect(label.contains("No such file or directory"))
        #expect(view.accessibilityRole() == .group)

        let icon = view.descendants(of: NSImageView.self).first
        // Not `.systemRed`: the shape carries the meaning, and the label
        // colour stays legible under Increase Contrast in both appearances.
        #expect(icon?.contentTintColor == .secondaryLabelColor)
    }

    /// Try Again appears only where retrying can help — a Mac that reports no
    /// Metal device will not grow one while the app is running, and a button
    /// that cannot work is worse than no button.
    @Test func retryIsOfferedOnlyWhenRetryingCouldWork() {
        let retryable = PaneFailureView(title: "t", detail: "d", canRetry: true)
        let titles = retryable.descendants(of: NSButton.self).map(\.title)
        #expect(titles.count == 2)
        #expect(titles.first == L10n.text("failure.button.retry"))

        let terminal = PaneFailureView(title: "t", detail: "d", canRetry: false)
        let onlySettings = terminal.descendants(of: NSButton.self).map(\.title)
        #expect(onlySettings == [L10n.text("failure.button.settings")])
    }

    /// The panel takes keyboard focus itself, because the pane it replaced
    /// has no terminal view for `makeFirstResponder` to land on (U09).
    @Test func thePanelOffersSomethingToFocus() {
        let retryable = PaneFailureView(title: "t", detail: "d", canRetry: true)
        #expect(retryable.primaryAction?.title == L10n.text("failure.button.retry"))
        // Return activates it, so the panel answers the key a person presses
        // without looking.
        #expect(retryable.primaryAction?.keyEquivalent == "\r")

        let terminal = PaneFailureView(title: "t", detail: "d", canRetry: false)
        #expect(terminal.primaryAction?.title == L10n.text("failure.button.settings"))
    }

    @Test func bothActionsAreWired() {
        let view = PaneFailureView(title: "t", detail: "d", canRetry: true)
        var retried = false
        var settings = false
        view.onRetry = { retried = true }
        view.onOpenSettings = { settings = true }
        let buttons = view.descendants(of: NSButton.self)
        for button in buttons {
            _ = button.target?.perform(button.action, with: button)
        }
        #expect(retried)
        #expect(settings)
    }

    // MARK: - What the panel says

    /// `PTYError` carries its own description; anything else falls back to
    /// Foundation's. The detail line is the only place the underlying reason
    /// reaches the user, so an empty or synthesized one is a dead end.
    @Test func everySpawnFailureDescribesItself() {
        let errors: [PTYError] = [
            .executablePathNotAbsolute,
            .spawnFailed(code: ENOENT),
            .spawnFailed(code: EACCES),
        ]
        for error in errors {
            #expect(!error.description.isEmpty)
            // Not the raw synthesized case name.
            #expect(!error.description.hasPrefix("spawnFailed("))
        }
    }

    // MARK: - Corrupt state

    /// A terminal that refuses to launch because its restore state is corrupt
    /// is worse than one that opens a fresh window. Truncated JSON, a
    /// wrong-shaped document and an empty file all read as "nothing to
    /// restore" rather than as an error.
    @Test func corruptRestoreStateReadsAsNothingToRestore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-recovery-\(UUID().uuidString)")
        let saved = SessionRestore.directory
        SessionRestore.directory = directory
        defer {
            SessionRestore.directory = saved
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for corrupt in ["", "{", "[{\"frame\":", "null", "{\"windows\":[]}"] {
            try corrupt.write(to: SessionRestore.fileURL, atomically: true, encoding: .utf8)
            #expect(SessionRestore.load().isEmpty, "\(corrupt.debugDescription) should not throw")
        }
    }
}

extension NSView {
    /// Every descendant of a kind, for asserting on a view built in code.
    fileprivate func descendants<T: NSView>(of kind: T.Type) -> [T] {
        subviews.flatMap { view in
            ((view as? T).map { [$0] } ?? []) + view.descendants(of: kind)
        }
    }
}
