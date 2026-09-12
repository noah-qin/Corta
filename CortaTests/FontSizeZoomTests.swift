import AppKit
import Testing

@testable import Corta

/// B09 — a font-size change from ⌘+/⌘−/pinch is a temporary, per-window
/// zoom, not a write to the config file. Regression coverage for the bug
/// this closes: zooming one window used to change every other open
/// window's size (and the saved default) the moment either next re-read
/// the config — `persistFontSize` wrote the zoomed size straight into
/// `Configuration.fontSize`.
///
/// Real panes, like `PaneZoomTests`: each spawns a genuine `zsh -l`, torn
/// down at the end of every test. Never writes `ConfigurationStore.shared`
/// (`CLAUDE.md` — never change the machine to test); every assertion here
/// either reads it or checks it is unchanged.
@MainActor
@Suite(.serialized)
struct FontSizeZoomTests {
    private func makeSplit() -> (SplitViewController, NSWindow) {
        let split = SplitViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = split
        _ = split.view
        split.view.layoutSubtreeIfNeeded()
        return (split, window)
    }

    @Test func zoomingOneWindowNeverTouchesTheConfigFile() throws {
        let (split, _) = makeSplit()
        defer { split.teardown() }
        let pane = try #require(split.focusedPane)
        let before = ConfigurationStore.shared.configuration
        pane.increaseFontSize(nil)
        pane.increaseFontSize(nil)
        #expect(pane.isFontSizeZoomed)
        #expect(ConfigurationStore.shared.configuration == before)
    }

    @Test func zoomingOneWindowDoesNotAffectAnother() throws {
        let (splitA, _) = makeSplit()
        let (splitB, _) = makeSplit()
        defer {
            splitA.teardown()
            splitB.teardown()
        }
        let paneA = try #require(splitA.focusedPane)
        let paneB = try #require(splitB.focusedPane)
        let originalA = paneA.fontSize
        let originalB = paneB.fontSize
        paneA.increaseFontSize(nil)
        #expect(paneA.fontSize == originalA + 1)
        #expect(paneB.fontSize == originalB)
        #expect(!paneB.isFontSizeZoomed)
    }

    @Test func resetReturnsToTheLiveConfiguredDefaultNotAConstant() throws {
        let (split, _) = makeSplit()
        defer { split.teardown() }
        let pane = try #require(split.focusedPane)
        pane.increaseFontSize(nil)
        pane.increaseFontSize(nil)
        #expect(pane.isFontSizeZoomed)
        pane.resetFontSize(nil)
        #expect(!pane.isFontSizeZoomed)
        #expect(pane.fontSize == CGFloat(ConfigurationStore.shared.configuration.fontSize))
    }

    /// The regression itself: `configurationChanged` used to apply
    /// `Configuration.fontSize` unconditionally, so a zoomed pane snapped
    /// back to the default the moment *anything* in the config changed —
    /// not only a font-size edit.
    @Test func aZoomedPaneIgnoresAConfigurationChange() throws {
        let (split, _) = makeSplit()
        defer { split.teardown() }
        let pane = try #require(split.focusedPane)
        pane.isFontSizeZoomed = true
        pane.fontSize = 999
        pane.configurationChanged()
        #expect(pane.fontSize == 999)
    }

    /// The other half: an *un*zoomed pane still tracks the config file, so
    /// the fix does not turn every pane into a permanent zoom.
    @Test func anUnzoomedPaneStillTracksTheConfiguration() throws {
        let (split, _) = makeSplit()
        defer { split.teardown() }
        let pane = try #require(split.focusedPane)
        pane.isFontSizeZoomed = false
        pane.fontSize = 999
        pane.configurationChanged()
        #expect(pane.fontSize == CGFloat(ConfigurationStore.shared.configuration.fontSize))
    }
}
