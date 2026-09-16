import AppKit
import Carbon.HIToolbox
import Testing

@testable import Corta

/// B16 — the system entry points: the Quick Terminal's hotkey and geometry,
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

struct QuickTerminalGeometryTests {
    let visible = NSRect(x: 100, y: 50, width: 1000, height: 800)

    @Test("the top band spans the screen width and hangs from the visible frame's top edge")
    func topBand() {
        let frame = QuickTerminalController.frame(for: .top, in: visible)
        #expect(frame.minX == 100 && frame.width == 1000)
        #expect(frame.maxY == visible.maxY)
        #expect(frame.height == 320)
    }

    @Test("the bottom band sits on the visible frame's bottom edge, clear of the Dock")
    func bottomBand() {
        let frame = QuickTerminalController.frame(for: .bottom, in: visible)
        #expect(frame.minY == visible.minY)
        #expect(frame.width == visible.width)
        #expect(frame.height == 320)
    }

    @Test("the centred panel is centred, and smaller than the screen on both axes")
    func centered() {
        let frame = QuickTerminalController.frame(for: .center, in: visible)
        #expect(frame.midX == visible.midX && frame.midY == visible.midY)
        #expect(frame.width == 700 && frame.height == 480)
        #expect(visible.contains(frame))
    }

    @Test("a band slides in from its own edge")
    func slideDirections() {
        #expect(QuickTerminalController.slideOffset(for: .top).height > 0)
        #expect(QuickTerminalController.slideOffset(for: .bottom).height < 0)
        #expect(QuickTerminalController.slideOffset(for: .center).width == 0)
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
        var posts = 0
        let observer = NotificationCenter.default.addObserver(
            forName: SecureInput.didChange, object: input, queue: nil
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        input.update(wanted: true)
        input.update(applicationIsActive: true, terminalWindowIsKey: true)
        input.update(applicationIsActive: true, terminalWindowIsKey: true)
        input.update(wanted: false)
        #expect(posts == 2)
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

/// The intents are exercised against programmatic window controllers — an
/// `NSWindow` with a plain view controller, tracked by the delegate exactly
/// as a storyboard window is — rather than by opening real terminal
/// windows. A storyboard window brings a Metal layer, a first present and a
/// spawned shell with it, and on the hosted CI runner that held the main
/// thread for long enough to time out every other main-actor suite in the
/// run (the same starvation PR #76 closed for the teardown tests). What
/// these tests are about — identity, listing, focus, refusal — needs none
/// of that; `WindowSetupStagingTests` covers the root pane's spawn inputs
/// without a window at all.
@MainActor
struct AppIntentTests {
    private var delegate: AppDelegate {
        get throws { try #require(NSApp.delegate as? AppDelegate) }
    }

    /// A tracked terminal window controller with no terminal in it.
    private func makeTrackedWindow(title: String = "") throws -> TerminalWindowController {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        let controller = TerminalWindowController(window: window)
        controller.contentViewController = NSViewController()
        try delegate.track(controller)
        return controller
    }

    @Test("a folder parameter must be an existing directory; nothing means home")
    func directoryValidation() throws {
        #expect(try OpenTerminalWindowIntent.validatedDirectory(nil) == nil)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        #expect(try OpenTerminalWindowIntent.validatedDirectory(tmp) == tmp.standardizedFileURL.path)
        let file = tmp.appendingPathComponent("corta-intent-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: CortaIntentError.self) {
            try OpenTerminalWindowIntent.validatedDirectory(file)
        }
        #expect(throws: CortaIntentError.self) {
            try OpenTerminalWindowIntent.validatedDirectory(URL(string: "https://example.com")!)
        }
    }

    @Test("focusing an id no window carries fails rather than picking another window")
    func unknownIdIsRefused() throws {
        #expect(try delegate.focusWindow(id: "no-such-window") == false)
    }

    @Test("a tracked window is listed by identity, titled for display, and focusable by id")
    func listAndFocus() throws {
        let delegate = try delegate
        let controller = try makeTrackedWindow(title: "build — zsh")
        defer { controller.window?.close() }
        let listed = TerminalWindowQuery.openWindows()
        let entity = try #require(listed.first { $0.id == controller.windowID })
        #expect(entity.title == "build — zsh")
        #expect(Set(listed.map(\.id)).count == listed.count, "ids must be unique across windows")
        #expect(delegate.focusWindow(id: controller.windowID))
        // Frontmost among the app's windows. Not `isKeyWindow`: a test host
        // that is not the active application cannot make any window key.
        #expect(NSApp.orderedWindows.first === controller.window)
    }

    @Test("an untitled window is presented as Corta, never as an empty row")
    func emptyTitleFallsBack() throws {
        let controller = try makeTrackedWindow(title: "")
        defer { controller.window?.close() }
        #expect(TerminalWindowEntity(controller: controller).title == "Corta")
    }

    @Test("a closed window leaves the listing, so its id resolves to nothing")
    func closedWindowIsGone() throws {
        let controller = try makeTrackedWindow()
        let id = controller.windowID
        controller.window?.close()
        #expect(!TerminalWindowQuery.openWindows().contains { $0.id == id })
        #expect(try delegate.focusWindow(id: id) == false)
    }

    @Test("the Quick Terminal is not an entity: it is summoned, not arranged")
    func quickTerminalIsNotListed() throws {
        let controller = try makeTrackedWindow()
        defer { controller.window?.close() }
        controller.isQuickTerminal = true
        #expect(!TerminalWindowQuery.openWindows().contains { $0.id == controller.windowID })
        #expect(controller.restorableState == nil, "the panel is never saved into the arrangement")
    }
}

/// The storyboard loads the window's content view — and with it spawns the
/// root pane's shell — *inside* `instantiateInitialController`. A restore or
/// a preset assigned to the controller afterwards therefore never reached
/// the root pane; only the splits (rebuilt in `viewWillAppear`) got their
/// directories. `SplitViewController.pendingSetup` stages the values first,
/// and `viewDidLoad` is what consumes them — so the consumption is tested
/// here on a bare `SplitViewController`, the way `PaneTeardownTests` build
/// panes: loading its view spawns a real shell but opens no window and
/// touches no Metal layer.
@MainActor
struct WindowSetupStagingTests {
    private func makeSplit(_ setup: SplitViewController.Setup) -> SplitViewController {
        SplitViewController.pendingSetup = setup
        let split = SplitViewController()
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

    @Test("the staging is consumed: the next plain window gets nothing left over")
    func stagingIsConsumed() throws {
        let first = makeSplit(SplitViewController.Setup(workingDirectory: NSTemporaryDirectory()))
        defer { first.teardown() }
        #expect(SplitViewController.pendingSetup == nil)
        let second = SplitViewController()
        _ = second.view
        defer { second.teardown() }
        #expect(second.panes.first?.inheritedWorkingDirectory == nil)
    }
}
