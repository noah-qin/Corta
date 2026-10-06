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
import Testing

@testable import Corta
@testable import CortaTerminal

/// A pane as its commands see it, with no renderer or window: a font size
/// the commands can change, a remote side that is local, and a session only
/// if a test gives it one (`LargeTextTaskTests`).
@MainActor
final class CommandsTestHost: PaneCommandsHost {
    let view = NSView()
    var session: TerminalSession! = nil
    var isOperable = false
    var terminalView: TerminalView! = nil
    var terminalRenderer: TerminalRenderer! = nil
    var splitController: SplitViewController? { nil }
    var selection: TerminalSelection?
    var scrollOffset = 0
    var topInset: CGFloat = 0
    var didTeardown = false
    var isFocusedPane = true
    var effectiveCommand: CommandRecord? { nil }
    let remote = PaneRemote()
    var fontSize: CGFloat = 12
    var isFontSizeZoomed = false
    private(set) lazy var commands = PaneCommands(host: self)

    private(set) var settles = 0
    func setFontSize(_ newSize: CGFloat, settle: Bool) {
        fontSize = min(64, max(8, newSize))
        if settle { settles += 1 }
    }
    func settleFontChange() { settles += 1 }
    let pointer = PanePointer()
    private(set) var redraws = 0
    func invalidateDisplay() { redraws += 1 }
}

/// Font size, the context menu, the `cd` gate and the menu items, against
/// `PaneCommands` alone. Copy, export and the Finder actions are covered
/// through real panes (`LargeTextTaskTests`, `ReopenAndExportTests`,
/// `CommandHistoryWiringTests`).
@MainActor
struct PaneCommandsTests {
    @Test("⌘+ and ⌘− zoom a lone pane; ⌘0 ends the zoom at the configured size")
    func fontSizeZoom() {
        let host = CommandsTestHost()
        host.commands.increaseFontSize(nil)
        #expect(host.fontSize == 13)
        #expect(host.isFontSizeZoomed)
        host.commands.decreaseFontSize(nil)
        #expect(host.fontSize == 12)
        host.commands.resetFontSize(nil)
        #expect(host.fontSize == min(64, max(8, CGFloat(ConfigurationStore.shared.configuration.fontSize))))
        #expect(!host.isFontSizeZoomed)
    }

    @Test("a pinch is spent a whole point at a time, settles once at its end, and a new one starts from zero")
    func pinchSteps() {
        let host = CommandsTestHost()
        host.commands.magnify(by: 0.1)
        #expect(host.fontSize == 12)
        host.commands.magnify(by: 0.1)
        host.commands.magnify(by: 0.3)
        #expect(host.fontSize == 15)
        // The steps refit without settling; the window waits for the end.
        #expect(host.settles == 0)
        host.commands.endMagnification()
        #expect(host.settles == 1)
        host.commands.magnify(by: 0.1)
        #expect(host.fontSize == 15)
        // A pinch that changed nothing settles nothing.
        host.commands.endMagnification()
        #expect(host.settles == 1)
    }

    @Test("the context menu sends copy here and paste and select-all to the pane")
    func contextMenuTargets() throws {
        let host = CommandsTestHost()
        let menu = host.commands.contextMenu()
        let copy = try #require(menu.items.first { $0.action == #selector(PaneCommands.copy(_:)) })
        #expect(copy.target === host.commands)
        #expect(!copy.isEnabled, "nothing is selected")
        let paste = try #require(menu.items.first { $0.action == TerminalCommand.paste.action })
        #expect(paste.target === host)
    }

    @Test("a failed pane refuses an app-initiated cd and greys the directory items")
    func failedPaneRefusesDirectoryCommands() {
        let host = CommandsTestHost()
        #expect(!host.commands.canChangeDirectorySafely)
        #expect(!host.commands.changeDirectory(to: "/tmp"))
        #expect(host.commands.shellDirectory == nil)
        for action in [
            #selector(PaneCommands.exportText(_:)), #selector(PaneCommands.exportCommandOutput(_:)),
            #selector(PaneCommands.revealWorkingDirectoryInFinder(_:)),
            #selector(PaneCommands.changeDirectoryToParent(_:)),
            #selector(PaneCommands.changeDirectoryToProjectRoot(_:)),
        ] {
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            #expect(!host.commands.validateMenuItem(item), "\(action)")
        }
    }

    @Test("the pane's two lists of action owners name the same collaborators")
    func actionOwnerListsAgree() {
        let pane = ViewController()
        #expect(
            pane.actionOwners.map { ObjectIdentifier(type(of: $0)) }
                == ViewController.actionOwnerClasses.map { ObjectIdentifier($0) })
    }

    @Test("a failed pane validates Copy Last Command Output without a session")
    func failedPaneValidatesCommandOutput() {
        let pane = ViewController()
        let item = NSMenuItem(
            title: "", action: #selector(PaneShellIntegration.copyLastCommandOutput(_:)),
            keyEquivalent: "")
        #expect(!pane.validateMenuItem(item))
    }

    /// Drops and Services take the ⌘V path (`SECURITY.md` §2.3): sanitised,
    /// then written to the child. `cat` echoes what arrives.
    @Test("text inserted as a paste reaches the child sanitised")
    func insertAsPasteSanitises() throws {
        let host = CommandsTestHost()
        let session = try TerminalSession(
            executable: "/bin/cat", arguments: [], environment: ChildEnvironment.default(),
            size: TerminalSize(rows: 10, columns: 60), workingDirectory: "/")
        defer { session.stop() }
        session.start()
        host.session = session
        host.commands.insertAsPaste("safe\u{1B}[31mtext")
        session.write(Array("\n".utf8))
        let deadline = Date().addingTimeInterval(5 * Double(testTimeoutScale))
        func lines() -> [String] { session.snapshot().logicalLines().map(\.text) }
        while Date() < deadline, !lines().contains(where: { $0.contains("safe") }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        let echoed = try #require(lines().first { $0.contains("safe") })
        // Unsanitised, the echo would read `safe^[[31mtext` and `cat`'s
        // copy would turn red and read `safetext`.
        #expect(echoed.contains("safe[31mtext"))
    }

    @Test("a failed pane greys Clear and Reset, and they leave it alone")
    func failedPaneHasNothingToClear() {
        let host = CommandsTestHost()
        host.scrollOffset = 3
        for action in [
            #selector(PaneCommands.clearScreen(_:)), #selector(PaneCommands.clearHistory(_:)),
            #selector(PaneCommands.resetTerminal(_:)),
        ] {
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            #expect(!host.commands.validateMenuItem(item), "\(action)")
        }
        host.commands.clearScreen(nil)
        #expect(host.scrollOffset == 3)
    }

    @Test("the pane answers the menu commands and validates them as its commands do")
    func paneForwardsCommands() {
        // Not loaded: a failed-pane state, in which none of these applies.
        let pane = ViewController()
        for action in [
            #selector(PaneCommands.exportText(_:)), #selector(PaneCommands.exportCommandOutput(_:)),
            #selector(PaneCommands.revealWorkingDirectoryInFinder(_:)),
            #selector(PaneCommands.changeDirectoryToParent(_:)),
        ] {
            #expect(pane.responds(to: action), "\(action)")
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            #expect(!pane.validateMenuItem(item), "\(action)")
        }
        for action in [
            #selector(PaneCommands.copy(_:)), #selector(PaneCommands.increaseFontSize(_:)),
            #selector(PaneCommands.decreaseFontSize(_:)), #selector(PaneCommands.resetFontSize(_:)),
            #selector(PaneCommands.copyWorkingDirectoryPath(_:)),
            #selector(PaneCommands.changeDirectoryToProjectRoot(_:)),
            #selector(PaneCommands.openParentDirectoryInNewPane(_:)),
            #selector(PaneCommands.openProjectRootInNewPane(_:)),
        ] {
            #expect(pane.responds(to: action), "\(action)")
        }
        // Sent to the pane by name, as a menu item with a target or the
        // palette does, the action runs on its owner.
        let size = pane.fontSize
        #expect(NSApp.sendAction(#selector(PaneCommands.increaseFontSize(_:)), to: pane, from: nil))
        #expect(pane.fontSize == size + 1)
    }
}
