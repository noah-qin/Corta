import Carbon.HIToolbox
import XCTest

/// B13/B14 against the live app, end to end, with nothing on the machine
/// changed: a throwaway stage directory carries the config, a script named `ssh`
/// stands in for a remote shell (it prints a banner, reports a remote
/// `OSC 7`, then runs `/bin/sh -i`), and `CORTA_SFTP_SSH` points the SFTP
/// channel at a script that `exec`s the real OpenSSH `sftp-server` on a
/// staged directory — so the wire protocol, the engine, the browser and
/// the remote-edit flow all run against genuine OpenSSH, the one thing the
/// in-memory fake server cannot vouch for. `CORTA_STAGE_DIR` (`AppPaths`)
/// is what keeps the launched app out of the developer's own config and
/// Application Support: `$HOME` does not move either on macOS.
///
/// Not covered here, and still a human's to judge: authentication and
/// host-key handling (there is no ssh in the loop), and anything about how
/// the panes *look* — they are Metal surfaces with no accessibility
/// content, so the assertions are on window titles, menus, the browser's
/// controls, and files on disk.
final class RemoteWorkflowUITests: XCTestCase {
    /// Fixed, because the UI-test runner is sandboxed: it may *read* all of
    /// `/` but write only its own container, which the app in turn cannot
    /// read (another app's container). So the app itself builds the stage
    /// — a first launch runs the staging script through its shell — and
    /// the last step removes it through the same terminal.
    private static let stage = URL(fileURLWithPath: "/private/tmp/corta-remote-ui", isDirectory: true)

    /// The input source the machine had before the test, restored in
    /// `tearDown`. `typeText` delivers key events, and a CJK input method
    /// composes them into candidates instead of passing them to the
    /// terminal — every typed line here would silently go nowhere. The
    /// test selects the ABC layout for its own duration and puts the
    /// user's choice back afterwards, so nothing about the machine is
    /// changed once it has run.
    private var previousInputSource: TISInputSource?

    override func setUpWithError() throws {
        continueAfterFailure = false
        previousInputSource = Self.selectLatinInputSource()
    }

    override func tearDownWithError() throws {
        if let previousInputSource { TISSelectInputSource(previousInputSource) }
    }

    /// Selects `com.apple.keylayout.ABC` (or any enabled Latin keyboard
    /// layout) and returns what was selected before, or `nil` when the
    /// current source is already a plain keyboard layout.
    private static func selectLatinInputSource() -> TISInputSource? {
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        func property(_ source: TISInputSource, _ key: CFString) -> String? {
            guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
            return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        }
        if property(current, kTISPropertyInputSourceType) == "TISTypeKeyboardLayout" {
            return nil
        }
        let filter = [kTISPropertyInputSourceType as String: "TISTypeKeyboardLayout"]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue()
            as? [TISInputSource]
        else { return nil }
        let abc = list.first { property($0, kTISPropertyInputSourceID) == "com.apple.keylayout.ABC" }
            ?? list.first
        guard let abc, TISSelectInputSource(abc) == noErr else { return nil }
        return current
    }

    /// Two launches. The first is an ordinary terminal that runs the
    /// staging script (`stage-remote-ui.sh`, a resource of this bundle)
    /// and is closed. The second is the staged one — `SHELL` is
    /// the script named `ssh`, so the first pane is spawned *as* a remote
    /// launcher, the path an ssh preset takes — and walks: badge → browser
    /// (asked first, host prefilled) → listing from the real sftp-server →
    /// Edit (the "editor" rewrites the managed copy) → the upload prompt →
    /// the remote file changed, no partial left → the fake remote shell
    /// exits → Reconnect → the badge is back → the stage is removed.
    @MainActor
    func testPresetBadgeBrowseEditUploadAndReconnect() throws {
        let stage = Self.stage
        let app = XCUIApplication()
        app.launchEnvironment["CORTA_RESTORE_WINDOWS"] = "0"
        // `/bin/sh`, not the login shell: no rc files, so the prompt is up
        // at once and nothing swallows the typed line.
        app.launchEnvironment["SHELL"] = "/bin/sh"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        app.windows.firstMatch.click()
        // The staging script ships as a resource of this test bundle —
        // under DerivedData, which the app can read — so one short line is
        // all the terminal has to be typed.
        let script = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "stage-remote-ui", withExtension: "sh"))
        // A nonce, so a stage left by an earlier run that failed before its
        // own cleanup is never mistaken for this one.
        let nonce = UUID().uuidString
        app.typeText("/bin/sh '\(script.path)' '\(stage.path)' \(nonce)\n")
        XCTAssertTrue(
            waitUntil(timeout: 20) {
                FileManager.default.fileExists(atPath: stage.appendingPathComponent("ready-\(nonce)").path)
            },
            "the staging script must have run in the first terminal")
        app.terminate()

        app.launchEnvironment["CORTA_STAGE_DIR"] = stage.path
        app.launchEnvironment["CORTA_SFTP_SSH"] = stage.appendingPathComponent("bin/sftp-ssh").path
        app.launchEnvironment["SHELL"] = stage.appendingPathComponent("bin/ssh").path
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        // The far end reports `file://fakebox<stage>/remote/srv/app`; the
        // badge follows within one process-facts interval.
        XCTAssertTrue(
            waitUntil(timeout: 10) { app.windows.firstMatch.title.contains("⟂ fakebox · app") },
            "title was: \(app.windows.firstMatch.title)")

        // Keystrokes reach the fake remote shell (a baseline for the same
        // check after the browser window has come and gone).
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).click()
        app.typeText("touch \(stage.path)/typed0\n")
        XCTAssertTrue(
            waitUntil(timeout: 10) { FileManager.default.fileExists(atPath: stage.appendingPathComponent("typed0").path) },
            "keystrokes must reach the remote pane")

        // Shell ▸ Browse Remote Files… is offered for a remote pane, and
        // the first connection to a reported host is a question: the
        // browser opens on its host-entry step with the name prefilled.
        let shellMenu = app.menuBarItems["Shell"]
        shellMenu.click()
        let browse = shellMenu.menuItems["Browse Remote Files…"]
        XCTAssertTrue(browse.waitForExistence(timeout: 2))
        XCTAssertTrue(browse.isEnabled, "a remote pane must offer the browser")
        browse.click()
        let browser = app.windows["Remote Files"]
        let spawnedAtOpen = FileManager.default.fileExists(atPath: stage.appendingPathComponent("sftp-ssh.log").path)
        XCTAssertTrue(
            browser.waitForExistence(timeout: 5),
            "the browser must open on the host question; windows: \(app.windows.allElementsBoundByIndex.map(\.title)), dialogs: \(app.dialogs.allElementsBoundByIndex.map(\.title)), sheets: \(app.sheets.count)")
        let hostField = browser.textFields.firstMatch
        XCTAssertTrue(hostField.waitForExistence(timeout: 2))
        XCTAssertEqual(hostField.value as? String, "fakebox", "the reported host is prefilled, not connected to")
        XCTAssertTrue(
            browser.staticTexts.element(matching: NSPredicate(format: "value CONTAINS 'reported that it is on'"))
                .exists, "the provenance of the name must be stated")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stage.appendingPathComponent("sftp-ssh.log").path),
            "nothing may be spawned before Connect (spawned at open: \(spawnedAtOpen), state: \(browser.staticTexts.allElementsBoundByIndex.map { $0.value as? String ?? $0.label })); log: \((try? String(contentsOf: stage.appendingPathComponent("sftp-ssh.log"), encoding: .utf8)) ?? "-"); windows: \(app.windows.allElementsBoundByIndex.map(\.title))")
        browser.buttons["Connect"].click()

        // A real OpenSSH sftp-server answers the listing.
        let readme = app.staticTexts["README.md"]
        XCTAssertTrue(
            readme.waitForExistence(timeout: 10),
            "listing from sftp-server; windows: \(app.windows.allElementsBoundByIndex.map(\.title)); texts: \(app.staticTexts.allElementsBoundByIndex.prefix(30).map { $0.value as? String ?? $0.label }); cells: \(app.cells.count) rows: \(app.tableRows.count) outlines: \(app.outlines.count) log: \((try? String(contentsOf: stage.appendingPathComponent("sftp-ssh.log"), encoding: .utf8)) ?? "-")")
        XCTAssertTrue(app.staticTexts["big.bin"].exists)
        XCTAssertTrue(app.staticTexts["src"].exists)
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                app.windows.element(matching: NSPredicate(format: "title BEGINSWITH 'fakebox:'")).exists
            }, "the window title must read host:path once connected")
        XCTAssertTrue(
            (try? String(contentsOf: stage.appendingPathComponent("sftp-ssh.log"), encoding: .utf8))?
                .contains("-s -- fakebox sftp") == true, "the channel's argv")

        // Edit: the file is downloaded to a managed copy under the *staged*
        // Application Support and the open-file-command runs on it; the
        // "editor" rewrites the copy, as a real one saving would.
        readme.click()
        let edit = app.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 2))
        edit.click()
        let editorLog = stage.appendingPathComponent("editor.log")
        XCTAssertTrue(
            waitUntil(timeout: 10) { FileManager.default.fileExists(atPath: editorLog.path) },
            "the editor command must run")
        let logged = try String(contentsOf: editorLog, encoding: .utf8)
        let copyPath = try XCTUnwrap(
            logged.split(separator: " ").dropFirst().first.map(String.init), "editor.log: \(logged)")
        XCTAssertTrue(copyPath.hasSuffix("/README.md"), "opened: \(copyPath)")
        XCTAssertTrue(
            copyPath.hasPrefix(stage.appendingPathComponent("ApplicationSupport/RemoteEdit/fakebox").path),
            "a managed copy under the *staged* store, never the real one: \(copyPath)")

        // The watch notices the save; uploading is an explicit question
        // naming the file and the host.
        let prompt = app.dialogs.firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 10), "the upload prompt must appear after a local edit")
        XCTAssertTrue(prompt.staticTexts["Upload Changes?"].exists)
        XCTAssertTrue(
            prompt.staticTexts.element(matching: NSPredicate(format: "value CONTAINS 'fakebox'")).exists,
            "the prompt must name the host")
        prompt.buttons["Upload"].click()
        let remoteReadme = stage.appendingPathComponent("remote/srv/app/README.md")
        XCTAssertTrue(
            waitUntil(timeout: 10) {
                (try? String(contentsOf: remoteReadme, encoding: .utf8)) == "hello, edited\n"
            }, "the remote file must carry the upload")
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: stage.appendingPathComponent("remote/srv/app").path)
        XCTAssertFalse(leftovers.contains { $0.contains(".corta-part") }, "no partial left: \(leftovers)")

        // Back to the terminal: the fake remote shell exits, the pane goes
        // local (no badge), Reconnect is offered and starts a new
        // connection whose far end reports again.
        // The browser is titled `host:path` now (asserted above).
        let connectedBrowser = app.windows.element(matching: NSPredicate(format: "title BEGINSWITH 'fakebox:'"))
        connectedBrowser.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(waitUntil(timeout: 5) { app.windows.count == 1 }, "the browser must close")
        let terminal = app.windows.firstMatch
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        // Typing must reach the fake remote shell: prove it with a file
        // before asking it to exit.
        app.typeText("touch \(stage.path)/typed\n")
        XCTAssertTrue(
            waitUntil(timeout: 10) { FileManager.default.fileExists(atPath: stage.appendingPathComponent("typed").path) },
            "keystrokes must reach the pane after the browser window closed (first responder)")
        app.typeText("exit\n")
        XCTAssertTrue(
            waitUntil(timeout: 10) { !app.windows.firstMatch.title.contains("⟂") },
            "a dead launcher's report must not keep the badge: \(app.windows.firstMatch.title)")
        shellMenu.click()
        let reconnect = shellMenu.menuItems["Reconnect to Host"]
        XCTAssertTrue(reconnect.waitForExistence(timeout: 2))
        XCTAssertTrue(reconnect.isEnabled, "a dead remote launcher must offer Reconnect")
        reconnect.click()
        XCTAssertTrue(
            waitUntil(timeout: 10) { app.windows.firstMatch.title.contains("⟂ fakebox · app") },
            "the new connection's report must bring the badge back: \(app.windows.firstMatch.title)")
        // The rebuilt pane must take keystrokes without a click — a
        // reconnect that leaves the keyboard dead is the first-responder
        // bug `CLAUDE.md` warns about.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.typeText("touch \(stage.path)/typed2\n")
        XCTAssertTrue(
            waitUntil(timeout: 10) { FileManager.default.fileExists(atPath: stage.appendingPathComponent("typed2").path) },
            "keystrokes must reach the reconnected pane")

        // The staged config was read: its preset is offered. (Asserted, not
        // driven — XCUITest clicks on a delegate-rebuilt submenu do not
        // reliably fire; the spawn path under test is the same one.)
        shellMenu.click()
        let presets = shellMenu.menuItems["New Pane with Preset"]
        XCTAssertTrue(
            presets.waitForExistence(timeout: 2),
            "Shell menu items: \(shellMenu.menuItems.allElementsBoundByIndex.map(\.title))")
        presets.click()
        XCTAssertTrue(presets.menuItems["fakebox"].waitForExistence(timeout: 2), "the config's preset must be listed")
        // Leave the menu through a harmless item — performing an item is
        // the one exit that reliably ends menu tracking; Escape left it
        // holding the next keystrokes.
        shellMenu.menuItems["Clear Screen"].click()

        // Clean up through the same terminal — the runner cannot write
        // outside its container. Click into the content first: a menu
        // that was just open otherwise keeps the keystrokes.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        app.typeText("rm -rf \(stage.path)\n")
        XCTAssertTrue(
            waitUntil(timeout: 10) { !FileManager.default.fileExists(atPath: stage.path) },
            "the stage must be gone")
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }
}
