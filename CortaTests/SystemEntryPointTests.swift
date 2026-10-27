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
import Carbon.HIToolbox
import Testing
import Synchronization
import CortaPOSIX

@testable import Corta

/// The system entry points: the Quick Terminal's hotkey and geometry,
/// Secure Keyboard Entry's state machine, the App Intents' window identity,
/// and the config keys all three read.
///
/// Nothing here registers a real hotkey or flips the machine's secure-input
/// mode: `GlobalHotKey` is tested at its key-code mapping and `SecureInput`
/// through an injected `System`, because a test that changes what every
/// other application on the machine can see is a test that should not run.
struct GlobalHotKeyTests {
    @Test("config-file spellings map to ANSI virtual key codes")
    func spellingsMapToKeyCodes() {
        #expect(GlobalHotKey.keyCode(for: "a") == UInt32(kVK_ANSI_A))
        #expect(GlobalHotKey.keyCode(for: "`") == UInt32(kVK_ANSI_Grave))
        #expect(GlobalHotKey.keyCode(for: " ") == UInt32(kVK_Space))
        #expect(GlobalHotKey.keyCode(for: Shortcut.parse("space")!.key) == UInt32(kVK_Space))
        #expect(GlobalHotKey.keyCode(for: Shortcut.parse("return")!.key) == UInt32(kVK_Return))
        #expect(GlobalHotKey.keyCode(for: Shortcut.parse("up")!.key) == UInt32(kVK_UpArrow))
        #expect(GlobalHotKey.keyCode(for: Shortcut.parse("escape")!.key) == UInt32(kVK_Escape))
    }

    @Test("a key Carbon has no code for is refused rather than registered as something else")
    func unknownKeysAreRefused() {
        #expect(GlobalHotKey.keyCode(for: "é") == nil)
        #expect(GlobalHotKey.keyCode(for: "ab") == nil)
        #expect(GlobalHotKey.keyCode(for: "") == nil)
    }

    @Test("a hotkey needs a modifier: a bare key claimed system-wide would swallow typing everywhere")
    func bareKeysAreNotRegistrable() {
        #expect(GlobalHotKey.isRegistrable(Shortcut.parse("alt+space")!))
        #expect(GlobalHotKey.isRegistrable(Shortcut.parse("ctrl+`")!))
        #expect(!GlobalHotKey.isRegistrable(Shortcut.parse("space")!))
        #expect(!GlobalHotKey.isRegistrable(Shortcut.parse("a")!))
        // Shift alone is typing: a capital letter, a symbol, a selection.
        #expect(!GlobalHotKey.isRegistrable(Shortcut.parse("shift+a")!))
        #expect(!GlobalHotKey.isRegistrable(Shortcut.parse("shift+1")!))
        #expect(!GlobalHotKey.isRegistrable(Shortcut.parse("shift+space")!))
        #expect(GlobalHotKey.isRegistrable(Shortcut.parse("ctrl+shift+a")!))
        #expect(!GlobalHotKey.isRegistrable(Shortcut.parse("cmd+é")!))
    }

    @Test("modifier flags translate to Carbon's bits")
    func modifierTranslation() {
        #expect(GlobalHotKey.carbonModifiers([.option]) == UInt32(optionKey))
        #expect(
            GlobalHotKey.carbonModifiers([.command, .shift, .control])
                == UInt32(cmdKey) | UInt32(shiftKey) | UInt32(controlKey))
        #expect(GlobalHotKey.carbonModifiers([]) == 0)
    }
}

@MainActor
struct SecureInputTests {
    /// Counts the system calls so the balance — never above one, back to
    /// zero — can be asserted directly.
    final class Counter {
        var enables = 0
        var disables = 0
        var depth: Int { enables - disables }
    }

    private func make() -> (SecureInput, Counter) {
        let counter = Counter()
        let input = SecureInput(
            system: .init(enable: { counter.enables += 1 }, disable: { counter.disables += 1 }))
        return (input, counter)
    }

    @Test("engaged only while wanted, active and a terminal window is key")
    func engagesOnlyWithAllThree() {
        let (input, counter) = make()
        input.update(wanted: true)
        #expect(!input.engaged, "the setting alone must not engage — the app may be in the background")
        input.update(applicationIsActive: true, terminalWindowIsKey: false)
        #expect(!input.engaged, "Settings being key is not a terminal being key")
        input.update(applicationIsActive: true, terminalWindowIsKey: true)
        #expect(input.engaged)
        #expect(counter.depth == 1)
    }

    @Test("the counter never goes above one however often the inputs repeat")
    func neverDoubleEnables() {
        let (input, counter) = make()
        input.update(wanted: true)
        input.update(applicationIsActive: true, terminalWindowIsKey: true)
        input.update(applicationIsActive: true, terminalWindowIsKey: true)
        input.update(wanted: true)
        #expect(counter.enables == 1)
        #expect(counter.depth == 1)
    }

    @Test("losing activation releases, regaining it re-engages")
    func followsActivation() {
        let (input, counter) = make()
        input.update(wanted: true)
        input.update(applicationIsActive: true, terminalWindowIsKey: true)
        input.update(applicationIsActive: false, terminalWindowIsKey: true)
        #expect(!input.engaged)
        #expect(counter.depth == 0)
        input.update(applicationIsActive: true, terminalWindowIsKey: true)
        #expect(input.engaged)
        #expect(counter.depth == 1)
    }

    @Test("turning the setting off while engaged releases; disengage at quit releases; neither over-releases")
    func releasesAreBalanced() {
        let (input, counter) = make()
        input.update(wanted: true)
        input.update(applicationIsActive: true, terminalWindowIsKey: true)
        input.update(wanted: false)
        #expect(counter.depth == 0)
        input.disengage()
        #expect(counter.disables == 1, "disengage with nothing engaged must not call the system")
        input.update(wanted: true)
        input.disengage()
        #expect(counter.depth == 0)
    }

    @Test("a change in the engaged state is announced; a no-op is not")
    func announcesChanges() {
        let (input, _) = make()
        let posts = Mutex(0)
        let observer = NotificationCenter.default.addObserver(
            forName: SecureInput.didChange, object: input, queue: nil
        ) { _ in posts.withLock { $0 += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }
        input.update(wanted: true)
        input.update(applicationIsActive: true, terminalWindowIsKey: true)
        input.update(applicationIsActive: true, terminalWindowIsKey: true)
        input.update(wanted: false)
        #expect(posts.withLock { $0 } == 2)
    }
}

struct SystemEntryPointConfigurationTests {
    @Test("the defaults claim nothing: no hotkey, secure entry off")
    func defaults() {
        let configuration = Configuration()
        #expect(!configuration.quickTerminal)
        #expect(configuration.quickTerminalKey == Shortcut.parse("alt+space"))
        #expect(configuration.quickTerminalPosition == .top)
        #expect(configuration.quickTerminalScreen == .mouse)
        #expect(!configuration.secureKeyboardEntry)
    }

    @Test("every key parses, round-trips, and the file says what was set")
    func roundTrip() {
        let text = """
            quick-terminal = true
            quick-terminal-key = ctrl+`
            quick-terminal-position = bottom
            quick-terminal-screen = main
            secure-keyboard-entry = yes
            """
        let (configuration, unknown) = Configuration.parse(text)
        #expect(unknown.isEmpty)
        #expect(configuration.quickTerminal)
        #expect(configuration.quickTerminalKey == Shortcut.parse("ctrl+`"))
        #expect(configuration.quickTerminalPosition == .bottom)
        #expect(configuration.quickTerminalScreen == .main)
        #expect(configuration.secureKeyboardEntry)
        let (again, _) = Configuration.parse(configuration.serialized())
        #expect(again == configuration)
        #expect(configuration.serialized().contains("quick-terminal-key = ctrl+`"))
    }

    @Test("an empty hotkey means none; a bare key or an unknown key is preserved as a typo, not applied")
    func hotKeyValidation() {
        let (none, unknownNone) = Configuration.parse("quick-terminal-key =")
        #expect(none.quickTerminalKey == nil)
        #expect(unknownNone.isEmpty)
        #expect(none.serialized().contains("quick-terminal-key = \n"))

        let (bare, unknownBare) = Configuration.parse("quick-terminal-key = space")
        #expect(bare.quickTerminalKey == Configuration().quickTerminalKey)
        #expect(unknownBare.map(\.0) == ["quick-terminal-key"])

        let (odd, unknownOdd) = Configuration.parse("quick-terminal-position = left")
        #expect(odd.quickTerminalPosition == .top)
        #expect(unknownOdd.map(\.0) == ["quick-terminal-position"])
    }

    @Test("the two commands are in the table with no default key, and under the groups the menus use")
    func commandsInTheTable() {
        #expect(TerminalCommand.quickTerminal.defaultShortcut == nil)
        #expect(TerminalCommand.secureKeyboardEntry.defaultShortcut == nil)
        #expect(TerminalCommand.quickTerminal.category == .window)
        #expect(TerminalCommand.secureKeyboardEntry.category == .terminal)
        #expect(TerminalCommand(rawValue: "quick-terminal") == .quickTerminal)
        #expect(TerminalCommand(rawValue: "secure-keyboard-entry") == .secureKeyboardEntry)
    }
}

struct WindowIdentityStateTests {
    @Test("a window id survives the state file, and its absence decodes as nil")
    func idRoundTrip() throws {
        var state = WindowState(
            frame: WindowState.Frame(NSRect(x: 0, y: 0, width: 900, height: 560)),
            layout: .pane(directory: nil))
        state.id = "ABC-123"
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(WindowState.self, from: data)
        #expect(decoded.id == "ABC-123")

        let legacy = """
            {"frame":{"x":0,"y":0,"width":900,"height":560},"layout":{"pane":{}}}
            """
        let old = try JSONDecoder().decode(WindowState.self, from: Data(legacy.utf8))
        #expect(old.id == nil)
    }
}

/// The root pane spawns as the window's content view loads, so a restore,
/// a preset or an intent's directory has to be in the controller before
/// that: `SplitViewController(setup:)` takes it by initializer, and
/// `viewDidLoad` is what consumes it — so the consumption is tested here on a
/// bare `SplitViewController`, the way `PaneTeardownTests` build panes:
/// loading its view spawns a real shell but opens no window and touches no
/// Metal layer.
@MainActor
struct WindowSetupStagingTests {
    private func makeSplit(_ setup: SplitViewController.Setup) -> SplitViewController {
        let split = SplitViewController(setup: setup)
        _ = split.view
        return split
    }

    @Test("a restored window's root pane spawns in the saved directory, not the home directory")
    func restoredRootPaneDirectory() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .standardizedFileURL.path
        let state = WindowState(
            frame: WindowState.Frame(NSRect(x: 0, y: 0, width: 900, height: 560)),
            layout: .pane(directory: directory, isFocused: true))
        let split = makeSplit(SplitViewController.Setup(restore: state))
        defer { split.teardown() }
        #expect(split.panes.first?.inheritedWorkingDirectory == directory)
        #expect(split.pendingRestore == state, "the splits are still applied when the window appears")
    }

    @Test("a preset staged for a new window reaches its root pane")
    func presetReachesRootPane() throws {
        var preset = Preset(name: "staged")
        preset.directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .standardizedFileURL.path
        let split = makeSplit(SplitViewController.Setup(preset: preset))
        defer { split.teardown() }
        #expect(split.panes.first?.preset?.name == "staged")
    }

    @Test("an intent's working directory reaches the root pane, and loses to a restore's")
    func workingDirectoryReachesRootPane() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .standardizedFileURL.path
        let plain = makeSplit(SplitViewController.Setup(workingDirectory: directory))
        defer { plain.teardown() }
        #expect(plain.panes.first?.inheritedWorkingDirectory == directory)

        let state = WindowState(
            frame: WindowState.Frame(NSRect(x: 0, y: 0, width: 900, height: 560)),
            layout: .pane(directory: "/", isFocused: true))
        let restored = makeSplit(
            SplitViewController.Setup(restore: state, workingDirectory: directory))
        defer { restored.teardown() }
        #expect(restored.panes.first?.inheritedWorkingDirectory == "/")
    }

    @Test("a setup belongs to its window: the next plain window gets nothing left over")
    func setupIsPerWindow() throws {
        let first = makeSplit(SplitViewController.Setup(workingDirectory: NSTemporaryDirectory()))
        defer { first.teardown() }
        let second = SplitViewController()
        _ = second.view
        defer { second.teardown() }
        #expect(second.panes.first?.inheritedWorkingDirectory == nil)
    }
}

/// Restored tab groups come back in saved order with the saved tab
/// selected. Programmatic windows with plain view controllers, tabbed for
/// real: AppKit's own `addTabbedWindow` ordering is what was wrong.
@MainActor
struct RestoredTabOrderTests {
    private func makeWindow(_ title: String) -> TerminalWindowController {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        window.tabbingMode = .preferred
        let controller = TerminalWindowController(window: window)
        controller.contentViewController = NSViewController()
        window.orderFront(nil)
        return controller
    }

    private func state(index: Int, selected: Bool) -> WindowState {
        WindowState(
            frame: WindowState.Frame(NSRect(x: 0, y: 0, width: 400, height: 300)),
            layout: .pane(directory: nil), tabGroupID: "group", tabIndex: index,
            isSelectedTab: selected)
    }

    @Test("three saved tabs come back first, second, third — not first, third, second")
    func savedOrderIsKept() throws {
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        let windowA = makeWindow("a"), windowB = makeWindow("b"), windowC = makeWindow("c")
        defer { for w in [windowA, windowB, windowC] { w.window?.close() } }
        delegate.regroupRestoredTabs([
            (state(index: 2, selected: true), windowC),
            (state(index: 0, selected: false), windowA),
            (state(index: 1, selected: false), windowB),
        ])
        let tabs = try #require(windowA.window?.tabbedWindows)
        #expect(tabs.map(\.title) == ["a", "b", "c"])
        #expect(windowA.window?.tabGroup?.selectedWindow === windowC.window)
    }
}

/// A task notification's click lands on the pane that posted it.
struct NotificationRoutingTests {
    private typealias Candidate = AppDelegate.NotificationCandidate

    /// Every session numbers its commands from zero, so two panes of one
    /// window both had a command 0, and the click landed on the first.
    @Test("two panes with the same command id: the click lands on the one that posted")
    func sameCommandIDInTwoPanes() {
        let panes = [
            Candidate(paneID: "left", sessionGeneration: 1, commandIDs: [0]),
            Candidate(paneID: "right", sessionGeneration: 1, commandIDs: [0]),
        ]
        let target = AppDelegate.notificationTarget(
            paneID: "right", sessionGeneration: 1, commandID: 0, panes: panes)
        #expect(target == AppDelegate.NotificationTarget(paneIndex: 1, commandID: 0))
    }

    @Test("a restarted pane is focused, but not on another session's command of the same id")
    func restartedPaneDoesNotReuseCommandIDs() {
        let panes = [Candidate(paneID: "pane", sessionGeneration: 2, commandIDs: [0])]
        let target = AppDelegate.notificationTarget(
            paneID: "pane", sessionGeneration: 1, commandID: 0, panes: panes)
        #expect(target == AppDelegate.NotificationTarget(paneIndex: 0, commandID: nil))
    }

    @Test("a closed pane is not replaced by another one")
    func closedPaneLandsNowhere() {
        let panes = [Candidate(paneID: "other", sessionGeneration: 1, commandIDs: [0])]
        #expect(
            AppDelegate.notificationTarget(
                paneID: "gone", sessionGeneration: 1, commandID: 0, panes: panes) == nil)
    }

    @Test("a notification from before panes were named still finds its command")
    func legacyNotificationFallsBack() {
        let panes = [
            Candidate(paneID: "a", sessionGeneration: 1, commandIDs: [3]),
            Candidate(paneID: "b", sessionGeneration: 1, commandIDs: [4]),
        ]
        #expect(
            AppDelegate.notificationTarget(
                paneID: nil, sessionGeneration: nil, commandID: 4, panes: panes)
                == AppDelegate.NotificationTarget(paneIndex: 1, commandID: 4))
    }
}

/// What the session-ended panel says. The panel itself needs a pane, which
/// needs Metal 4 (`SessionLifecycleTests`); the wording does not.
@MainActor
struct SessionEndedWordingTests {
    private func content(_ exit: ProcessExit, connection: Bool, host: String? = nil, program: String = "zsh")
        -> PaneStatusPanel.Content
    {
        SessionEnded.content(for: exit, isConnection: connection, host: host, program: program)
    }

    @Test("an exit says its code, a signal its name, and a connection names its host")
    func wordingFollowsTheExit() {
        #expect(content(.exited(code: 0), connection: false).title
            == L10n.format("session.ended.local.title", "zsh"))
        #expect(content(.exited(code: 3), connection: false).body == L10n.format("session.ended.local.code", 3))
        #expect(content(.signalled(signal: SIGKILL), connection: false).body
            == L10n.format("session.ended.local.signal", "SIGKILL", 9))
        #expect(content(.exited(code: 255), connection: true, host: "deploy@box", program: "ssh").title
            == L10n.format("session.ended.connection.ended.host", "deploy@box"))
        #expect(content(.exited(code: 1), connection: true, program: "mosh").title
            == L10n.text("session.ended.connection.ended"))
        #expect(SessionEnded.signalName(SIGTERM) == "SIGTERM")
        #expect(SessionEnded.signalName(77) == "signal 77")
        // Every case reads differently.
        let all = Set([
            content(.exited(code: 0), connection: false).body,
            content(.exited(code: 0), connection: true).body,
            content(.signalled(signal: 15), connection: false).body,
            content(.signalled(signal: 15), connection: true, program: "ssh").body,
            content(.exited(code: 255), connection: true, program: "ssh").body,
            content(.exited(code: 255), connection: true, program: "mosh").body,
        ])
        #expect(all.count == 6)
    }

    /// 255 is ssh's own code for a connection that failed or dropped; said
    /// as such for ssh alone, as a plain exit code for anything else.
    @Test("ssh's 255 is explained, another launcher's is not")
    func sshsOwnCodeIsExplained() {
        #expect(content(.exited(code: 255), connection: true, program: "ssh").body
            == L10n.text("session.ended.connection.ssh255"))
        #expect(content(.exited(code: 255), connection: true, program: "et").body
            == L10n.format("session.ended.connection.code", "et", 255))
    }

    /// Both say what starting again costs, and only the remote one is a
    /// new connection.
    @Test("the note says the output is cleared")
    func theNoteNamesTheCost() {
        #expect(content(.exited(code: 0), connection: true).note == L10n.text("session.ended.connection.note"))
        #expect(content(.exited(code: 0), connection: false).note == L10n.text("session.ended.local.note"))
    }
}
