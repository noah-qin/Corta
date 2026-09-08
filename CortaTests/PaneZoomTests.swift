import AppKit
import Testing

@testable import Corta

/// U13 — filling the window with one pane, and putting the split back.
///
/// **What makes this worth testing rather than eyeballing.** Zoom is a
/// view-hierarchy change, and the project has already shipped six defects
/// that were invisible to every render test because the pixels were right and
/// the hierarchy was not (`CONFORMANCE.md` §4.4). The two failures that
/// matter here are both structural: the split tree quietly losing the zoomed
/// pane, and unzoom leaving the pane parented to the wrong view. Neither
/// shows up in a screenshot of a zoomed pane, which looks correct in both
/// cases.
///
/// `.serialized` and real panes, like `PaneTeardownTests`: each pane spawns a
/// genuine `zsh -l`, so the panes are torn down at the end of every test.
@MainActor
@Suite(.serialized)
struct PaneZoomTests {
    /// A window with a split controller and `count` panes, plus the teardown
    /// that stops their children.
    private func makeSplit(panes count: Int) -> (SplitViewController, NSWindow) {
        let split = SplitViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = split
        _ = split.view
        split.view.layoutSubtreeIfNeeded()
        for _ in 1..<count { split.splitFocusedPane(orientation: .columns) }
        return (split, window)
    }

    @Test func zoomingFillsTheWindowWithOnePaneAndUnzoomingPutsItBack() throws {
        let (split, window) = makeSplit(panes: 2)
        defer { split.teardown() }
        let pane = try #require(split.focusedPane)
        let treeRoot = try #require(split.view.subviews.first)

        split.toggleZoomPane(nil)
        #expect(split.isPaneZoomed)
        // The pane itself is what the controller's view holds now.
        #expect(split.view.subviews == [pane.view])
        #expect(treeRoot.superview == nil)

        split.toggleZoomPane(nil)
        #expect(!split.isPaneZoomed)
        #expect(split.view.subviews == [treeRoot])
        // And the pane is back inside the tree, not orphaned or left on the
        // controller's view — the failure a screenshot cannot show.
        #expect(pane.view.isDescendant(of: treeRoot))
        _ = window
    }

    /// Zoom is temporary and changes nothing: both panes are still there,
    /// both children are still running, and the saved arrangement still
    /// describes the split rather than the zoom.
    @Test func zoomingChangesNoPaneAndNoSavedLayout() throws {
        let (split, window) = makeSplit(panes: 2)
        defer { split.teardown() }
        let before = try #require(split.windowState(frame: window.frame))
        #expect(split.panes.count == 2)

        split.toggleZoomPane(nil)
        #expect(split.panes.count == 2)
        #expect(split.panes.allSatisfy { $0.session != nil })
        #expect(split.windowState(frame: window.frame)?.layout == before.layout)

        split.toggleZoomPane(nil)
        #expect(split.windowState(frame: window.frame)?.layout == before.layout)
    }

    /// A single-pane window has nothing to zoom *from*, so the command does
    /// nothing rather than entering a state that looks identical to the one
    /// it started in — and the menu item says so by being disabled.
    @Test func asinglePaneWindowCannotZoom() throws {
        let (split, _) = makeSplit(panes: 1)
        defer { split.teardown() }
        split.toggleZoomPane(nil)
        #expect(!split.isPaneZoomed)

        let item = NSMenuItem(
            title: "", action: #selector(SplitViewController.toggleZoomPane(_:)),
            keyEquivalent: "")
        #expect(!split.validateMenuItem(item))
    }

    /// One command, two names. The item has to say which direction it will
    /// go — a checkmark would report the state without saying what pressing
    /// it does.
    @Test func theMenuItemNamesWhichDirectionItGoes() throws {
        let (split, _) = makeSplit(panes: 2)
        defer { split.teardown() }
        let item = NSMenuItem(
            title: "", action: #selector(SplitViewController.toggleZoomPane(_:)),
            keyEquivalent: "")

        #expect(split.validateMenuItem(item))
        #expect(item.title == L10n.text("command.zoomPane"))

        split.toggleZoomPane(nil)
        #expect(split.validateMenuItem(item))
        #expect(item.title == L10n.text("command.unzoomPane"))
    }

    /// Splitting while zoomed means seeing the new pane, so the zoom ends
    /// rather than hiding the pane that was just created.
    @Test func splittingWhileZoomedLeavesZoom() throws {
        let (split, _) = makeSplit(panes: 2)
        defer { split.teardown() }
        split.toggleZoomPane(nil)
        #expect(split.isPaneZoomed)
        split.splitFocusedPane(orientation: .rows)
        #expect(!split.isPaneZoomed)
        #expect(split.panes.count == 3)
    }

    /// Closing the zoomed pane leaves zoom too — otherwise the window would
    /// be showing a view that has just been removed.
    @Test func closingTheZoomedPaneLeavesZoom() throws {
        let (split, _) = makeSplit(panes: 2)
        defer { split.teardown() }
        let pane = try #require(split.focusedPane)
        split.toggleZoomPane(nil)
        split.closePane(pane)
        #expect(!split.isPaneZoomed)
        #expect(split.panes.count == 1)
        #expect(split.view.subviews.first?.superview === split.view)
    }
}
