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
import Foundation
import Testing

@testable import Corta
@testable import CortaTerminal

extension CommandsTestHost: PaneComposerHost {}

/// The compose field (#540): what it sends goes down the paste path and
/// nowhere else, its keys are ⌘Return and Esc and nothing an input method is
/// composing with, and a draft not sent stays with the pane.
///
/// The children are real: a shell that turns bracketed paste on and writes
/// what it reads, byte for byte, to a scratch file, or `cat` without it. The
/// input method itself is human-only (the launched-app check); here its
/// marked text is set the way one sets it, through `setMarkedText`.
@MainActor
@Suite(.serialized)
struct PaneComposerTests {
    @MainActor
    private struct Fixture {
        let host: CommandsTestHost
        let composer: PaneComposer
        let window: NSWindow
        let session: TerminalSession

        func tearDown() {
            composer.detach()
            session.stop()
            window.close()
        }
    }

    /// A pane in a window, its composer, and a running child.
    private func makeFixture(executable: String = "/bin/cat", arguments: [String] = []) throws -> Fixture {
        let host = CommandsTestHost()
        let session = try TerminalSession(
            executable: executable, arguments: arguments, environment: ChildEnvironment.default(),
            size: TerminalSize(rows: 10, columns: 60), workingDirectory: "/")
        session.start()
        host.session = session
        host.isOperable = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host.view
        return Fixture(host: host, composer: PaneComposer(host: host), window: window, session: session)
    }

    private func wait(_ what: Comment, until condition: () -> Bool) throws {
        let deadline = SuspendingClock.now + .seconds(5 * Double(testTimeoutScale))
        while SuspendingClock.now < deadline, !condition() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        #expect(condition(), what)
    }

    private func key(_ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode))
    }

    @Test("⌘Return and keypad ⌘Enter send; Return, ⇧⌘Return and ⌥⌘Return do not")
    func sendKeyIsCommandReturnOnly() throws {
        #expect(ComposerTextView.isSendKey(try key(36, "\r", .command)))
        #expect(ComposerTextView.isSendKey(try key(76, "\u{3}", .command)))
        #expect(!ComposerTextView.isSendKey(try key(36, "\r")))
        #expect(!ComposerTextView.isSendKey(try key(36, "\r", [.command, .shift])))
        #expect(!ComposerTextView.isSendKey(try key(36, "\r", [.command, .option])))
        #expect(ComposerTextView.isCloseKey(try key(53, "\u{1B}")))
        #expect(!ComposerTextView.isCloseKey(try key(53, "\u{1B}", .command)))
    }

    /// The child turns `?2004` on and writes what it reads, raw, to a file:
    /// the text arrives once, between the paste markers, its control
    /// character stripped, and with no Return after it — submitting is the
    /// user's, in the program.
    @Test("a send arrives as one bracketed paste, sanitised, with nothing appended")
    func sendIsABracketedPaste() throws {
        let capture = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-composer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: capture) }
        let script =
            "printf '\\033[?2004h'; stty raw -echo; printf 'READY\\n'; exec cat > '\(capture.path)'"
        let fixture = try makeFixture(executable: "/bin/sh", arguments: ["-c", script])
        defer { fixture.tearDown() }
        try wait("the child is ready, bracketed paste on") {
            fixture.session.isBracketedPasteEnabled
                && fixture.session.snapshot().logicalLines().contains { $0.text.contains("READY") }
        }

        fixture.composer.show()
        let textView = try #require(fixture.composer.textView)
        #expect(fixture.composer.isOpen)
        #expect(fixture.window.firstResponder === textView, "the field takes the keyboard")
        textView.string = "第一行\n第二行\u{07} done"
        #expect(textView.handlesKey(try key(36, "\r", .command)))

        #expect(!fixture.composer.isOpen, "sending closes the field")
        #expect(fixture.composer.draft.isEmpty, "a sent text is no draft")
        let expected = Array("\u{1B}[200~第一行\n第二行 done\u{1B}[201~".utf8)
        try wait("the child read the paste") {
            (try? Data(contentsOf: capture)).map(Array.init) == expected
        }
        // Nothing follows it: no Return was appended.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        #expect((try? Data(contentsOf: capture)).map(Array.init) == expected)
    }

    /// Without `?2004` a multi-line text raises the paste warning, as ⌘V's
    /// would; answered Cancel, nothing is sent and the text comes back as
    /// the draft.
    @Test("an unbracketed multi-line send asks first, and a refusal keeps the draft")
    func unbracketedMultilineWarns() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        var asked: [Paste.PasteRisk] = []
        fixture.host.commands.pasteWarningAnswer = { risks in
            asked = risks
            return false
        }
        fixture.composer.show()
        let textView = try #require(fixture.composer.textView)
        textView.string = "one\ntwo"
        fixture.composer.send()

        #expect(asked.contains(.multiline))
        #expect(!fixture.composer.isOpen)
        #expect(fixture.composer.draft == "one\ntwo", "a send that did not happen gives the text back")
        fixture.composer.show()
        #expect(fixture.composer.textView?.string == "one\ntwo")
        #expect(fixture.composer.model.isEmpty == false)
    }

    /// The warning takes time to answer; the pane may get a new session
    /// meanwhile. The text was meant for the old one, so it goes nowhere.
    @Test("a pane rebuilt with a new session while the warning is up discards the send")
    func newSessionDiscardsThePendingSend() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let replacement = try TerminalSession(
            executable: "/bin/cat", arguments: [], environment: ChildEnvironment.default(),
            size: TerminalSize(rows: 10, columns: 60), workingDirectory: "/")
        replacement.start()
        defer { replacement.stop() }
        fixture.host.commands.pasteWarningAnswer = { _ in
            fixture.host.session = replacement
            return true
        }
        fixture.composer.show()
        try #require(fixture.composer.textView).string = "MARK1\nMARK2"
        fixture.composer.send()

        #expect(fixture.composer.draft == "MARK1\nMARK2")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        for session in [fixture.session, replacement] {
            #expect(!session.snapshot().logicalLines().contains { $0.text.contains("MARK") })
        }
    }

    /// While an input method composes, Esc is the composition's to cancel and
    /// ⌘Return is not a send; with nothing marked, Esc closes the field and
    /// keeps what was written.
    @Test("marked text keeps Esc and ⌘Return; without it Esc closes and keeps the draft")
    func compositionOwnsItsKeys() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        fixture.composer.show()
        let textView = try #require(fixture.composer.textView)
        textView.string = "你好"
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.setMarkedText(
            "shi", selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(textView.hasMarkedText())

        #expect(!textView.handlesKey(try key(53, "\u{1B}")), "Esc goes to the input method")
        #expect(!textView.handlesKey(try key(36, "\r", .command)), "⌘Return does not send a preedit")
        textView.cancelOperation(nil)
        #expect(fixture.composer.isOpen)

        textView.unmarkText()
        textView.string = "你好"
        #expect(textView.handlesKey(try key(53, "\u{1B}")))
        #expect(!fixture.composer.isOpen)
        #expect(fixture.composer.draft == "你好")
        #expect(!fixture.session.snapshot().logicalLines().contains { $0.text.contains("你好") })
    }

    @Test("Return is the text view's own: a newline, never a send")
    func returnIsANewline() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        fixture.composer.show()
        let textView = try #require(fixture.composer.textView)
        #expect(!textView.handlesKey(try key(36, "\r")))
        textView.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.insertNewline(nil)
        textView.insertText("b", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(textView.string == "a\nb")
        #expect(fixture.composer.isOpen)
    }

    /// Closing without sending drops an unfinished composition: the preedit
    /// is not text the user chose.
    @Test("closing mid-composition keeps the committed text only")
    func closeDropsThePreedit() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        fixture.composer.show()
        let textView = try #require(fixture.composer.textView)
        textView.string = "draft "
        textView.setSelectedRange(NSRange(location: 6, length: 0))
        textView.setMarkedText(
            "zhong", selectedRange: NSRange(location: 5, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        fixture.composer.close()
        #expect(fixture.composer.draft == "draft ")
    }

    @Test("a pane without a running session greys the command and opens nothing")
    func failedPaneOffersNothing() throws {
        let host = CommandsTestHost()
        let composer = PaneComposer(host: host)
        let item = NSMenuItem(title: "", action: TerminalCommand.composeText.action, keyEquivalent: "")
        #expect(!composer.validateMenuItem(item))
        composer.show()
        #expect(!composer.isOpen)
    }

    @Test("the pane answers Compose Text and validates it through its composer")
    func paneForwardsTheCommand() {
        let pane = TerminalPaneViewController()
        #expect(pane.responds(to: TerminalCommand.composeText.action))
        let item = NSMenuItem(title: "", action: TerminalCommand.composeText.action, keyEquivalent: "")
        #expect(!pane.validateMenuItem(item), "a pane that never started has nothing to send to")
    }
}
