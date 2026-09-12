import AppKit
import Testing

@testable import Corta

/// UI06 / UI07 — how the menus group what they carry: the Shell menu's
/// create / move / resize order, and the single Theme submenu that holds
/// both the appearance choice and the theme list.
@MainActor
struct MenuStructureTests {
    /// The Shell menu's item actions, split into groups at the separators.
    private static func shellGroups() throws -> [[Selector?]] {
        let mainMenu = try #require(NSApp.mainMenu)
        let shell = try #require(
            mainMenu.items.first(where: { $0.title == L10n.text("menu.shell") })?.submenu,
            "the menu bar must carry a Shell menu")
        var groups: [[Selector?]] = [[]]
        for item in shell.items {
            if item.isSeparatorItem {
                groups.append([])
            } else {
                groups[groups.count - 1].append(item.action)
            }
        }
        return groups.filter { !$0.isEmpty }
    }

    /// The Shell menu reads as six groups, in the order of what each one is
    /// *for*: open a terminal a particular way, create panes, go somewhere
    /// else, throw terminal state away, change the geometry.
    ///
    /// The order is the assertion. Command-to-command jumping sits with the
    /// focus moves because both answer "go somewhere else"; it used to sit
    /// after the resize group, which put a geometry group between the two
    /// navigation families. The terminal-state commands (U11) are their own
    /// group because each one discards something, and grouping them with
    /// anything else would make that less obvious, not more.
    @Test("Shell groups presets, create, move, directories, clear, then resize")
    func shellMenuGrouping() throws {
        let groups = try Self.shellGroups()
        #expect(
            groups.count == 7, "presets, splits, focus, navigation, directories, state, resize")

        let split = #selector(SplitViewController.splitRight(_:))
        let focusLeft = #selector(SplitViewController.moveFocusLeft(_:))
        let previousCommand = #selector(ViewController.jumpToPreviousCommand(_:))
        let copyOutput = #selector(ViewController.copyLastCommandOutput(_:))
        let revealWorkingDirectory = #selector(ViewController.revealWorkingDirectoryInFinder(_:))
        let changeToProjectRoot = #selector(ViewController.changeDirectoryToProjectRoot(_:))
        let clearScreen = #selector(ViewController.clearScreen(_:))
        let reset = #selector(ViewController.resetTerminal(_:))
        let zoom = #selector(SplitViewController.toggleZoomPane(_:))
        let equalize = #selector(SplitViewController.equalizePanes(_:))

        // U16 — the preset list heads the menu: it is how a terminal is
        // opened, which comes before what is done with one.
        #expect(groups[0].count == 1, "one item: the preset submenu")

        #expect(groups[1].contains(split))
        #expect(groups[2].contains(focusLeft))

        // Navigation: the command jumps, then the failed-command jumps, then
        // taking the last command's output — all of them shell-integration
        // commands, and all about a command rather than a pane.
        #expect(groups[3].first == previousCommand)
        #expect(groups[3].contains(copyOutput))

        // B08 — directory navigation: reveal/copy (reads), then the two
        // `cd` primitives, then the two new-pane variants.
        #expect(groups[4].first == revealWorkingDirectory)
        #expect(groups[4].contains(changeToProjectRoot))

        // U11 — the three state commands, in the order of how much each
        // discards.
        #expect(groups[5].first == clearScreen)
        #expect(groups[5].contains(reset))

        // Geometry last, zoom at its head (U13).
        #expect(groups[6].first == zoom)
        #expect(groups[6].last == equalize)
    }

    @Test("View has one Theme submenu holding appearance, then themes")
    func themeSubmenuHoldsAppearanceAndThemes() throws {
        let mainMenu = try #require(NSApp.mainMenu)
        let view = try #require(
            mainMenu.items.first(where: { $0.title == L10n.text("menu.view") })?.submenu,
            "the menu bar must carry a View menu")

        // No second submenu for the same decision: the standalone
        // Appearance submenu is gone.
        #expect(
            view.items.allSatisfy { $0.submenu?.title != L10n.text("settings.tab.appearance") })

        let themeItem = view.items.first {
            $0.submenu?.title == L10n.text("settings.label.theme")
        }
        let theme = try #require(themeItem?.submenu, "the View menu must carry the Theme submenu")
        let appearanceCount = Configuration.Appearance.allCases.count
        #expect(theme.items.count > appearanceCount + 1)

        // Appearance choices head the list, tagged for `selectAppearance`.
        for (index, item) in theme.items.prefix(appearanceCount).enumerated() {
            #expect(item.action == #selector(AppDelegate.selectAppearance(_:)))
            #expect(item.tag == index)
        }
        #expect(theme.items[appearanceCount].isSeparatorItem)
        for item in theme.items.dropFirst(appearanceCount + 1) {
            #expect(item.action == #selector(AppDelegate.selectTheme(_:)))
        }
    }
}
