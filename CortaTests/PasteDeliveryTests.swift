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
import CortaTerminal
import Foundation
import Testing

@testable import Corta

/// What happens to a paste between the pasteboard and the session: refused for
/// size, scanned off the main thread, replaced, or left behind by its session.
@MainActor
struct PasteDeliveryTests {
    @MainActor private final class Log {
        var sent = 0
        var discarded = 0
    }

    private func live(script: String = "exec cat") throws -> (CommandsTestHost, TerminalSession) {
        let host = CommandsTestHost()
        host.terminalView = TerminalView(frame: .zero)
        let session = try TerminalSession(
            executable: "/bin/sh", arguments: ["-c", script], environment: ChildEnvironment.default(),
            size: TerminalSize(rows: 10, columns: 60), workingDirectory: "/")
        session.start()
        host.session = session
        return (host, session)
    }

    private func paste(_ text: String, into host: CommandsTestHost, log: Log) {
        host.commands.insertAsPaste(
            text, onDiscard: { log.discarded += 1 }, onSent: { log.sent += 1 })
    }

    private func settle(_ done: () -> Bool) async {
        let deadline = SuspendingClock.now + .seconds(10) * testTimeoutScale
        while !done(), SuspendingClock.now < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private static let large = String(repeating: "a plain line of a long log ", count: 40_000)

    @Test("past the cap a paste is refused, says so, and nothing is walked")
    func oversizedPasteIsRefused() throws {
        let (host, session) = try live()
        defer { session.stop() }
        let log = Log()
        paste(String(repeating: "x", count: Paste.maximumBytes + 1), into: host, log: log)
        #expect(log.discarded == 1)
        #expect(log.sent == 0)
        #expect(host.commands.pasteScan == nil)
        #expect(host.terminalView.toastLayer != nil)
        #expect(!session.hasPendingInput)
    }

    /// Larger than the cap the write queue pushes back with, which refuses a
    /// backlog and not one paste: what is under `maximumBytes` still goes.
    @Test("a paste past the write queue's cap still goes through whole")
    func pastePastTheQueueCapIsSent() async throws {
        let (host, session) = try live()
        defer { session.stop() }
        let log = Log()
        let text = String(repeating: "x", count: 5 * 1024 * 1024)
        paste(text, into: host, log: log)
        await settle { log.sent + log.discarded > 0 }
        #expect(log.sent == 1)
    }

    @Test("a small paste is judged and sent where it was asked for")
    func smallPasteIsSynchronous() throws {
        let (host, session) = try live()
        defer { session.stop() }
        let log = Log()
        paste("hello", into: host, log: log)
        #expect(log.sent == 1)
        #expect(host.commands.pasteScan == nil)
    }

    @Test("a large paste returns at once and is sent when its scan answers")
    func largePasteIsScannedOffTheMainThread() async throws {
        let (host, session) = try live()
        defer { session.stop() }
        let log = Log()
        paste(Self.large, into: host, log: log)
        #expect(log.sent == 0, "nothing goes until the scan has answered")
        #expect(host.commands.pasteScan != nil)
        await settle { log.sent > 0 }
        #expect(log.sent == 1)
        #expect(host.commands.pasteScan == nil)
    }

    @Test("a newer paste replaces one still being scanned")
    func newerPasteWins() async throws {
        let (host, session) = try live()
        defer { session.stop() }
        let first = Log()
        let second = Log()
        paste(Self.large, into: host, log: first)
        paste("newer", into: host, log: second)
        #expect(first.discarded == 1)
        #expect(second.sent == 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(first.sent == 0)
    }

    @Test("a scan that outlives its session sends nothing to the next one")
    func replacedSessionGetsNothing() async throws {
        let (host, session) = try live()
        defer { session.stop() }
        let next = try TerminalSession(
            executable: "/bin/cat", environment: ChildEnvironment.default(),
            size: TerminalSize(rows: 10, columns: 60), workingDirectory: "/")
        next.start()
        defer { next.stop() }
        let log = Log()
        paste(Self.large, into: host, log: log)
        host.session = next
        await settle { log.discarded > 0 }
        #expect(log.discarded == 1)
        #expect(log.sent == 0)
        #expect(!next.hasPendingInput)
    }

    @Test("a warned paste is not sent to a session stopped in the meantime")
    func stoppedSessionGetsNothing() async throws {
        let (host, session) = try live()
        let log = Log()
        paste(Self.large, into: host, log: log)
        session.stop()
        await settle { log.discarded > 0 }
        #expect(log.discarded == 1)
        #expect(log.sent == 0)
    }

    @Test("closing the pane ends a scan")
    func stopEndsTheScan() throws {
        let (host, session) = try live()
        defer { session.stop() }
        let log = Log()
        paste(Self.large, into: host, log: log)
        host.commands.stop()
        #expect(log.discarded == 1)
        #expect(host.commands.pasteScan == nil)
    }

    // MARK: - ?2004 between the judgement and the send

    /// Asks for bracketed paste, then drops it when it reads a line, as output
    /// may while a warning waits to be answered.
    private static let flipping = #"printf '\033[?2004h'; read -r _; printf '\033[?2004l'; printf 'OFF\n'; exec cat"#

    private func flipped() async throws -> (CommandsTestHost, TerminalSession) {
        let (host, session) = try live(script: Self.flipping)
        await settle { session.isBracketedPasteEnabled }
        #expect(session.isBracketedPasteEnabled)
        return (host, session)
    }

    private func delivery(_ session: TerminalSession, log: Log, warns: Bool = true) -> PaneCommands.PasteDelivery {
        PaneCommands.PasteDelivery(
            session: session, bracketed: true, warns: warns, validate: nil,
            onDiscard: { log.discarded += 1 }, onSent: { log.sent += 1 })
    }

    @Test("lines judged safe under ?2004 are asked about again once it is off")
    func droppedBracketingWarnsAgain() async throws {
        let (host, session) = try await flipped()
        defer { session.stop() }
        session.write(Array("\n".utf8))
        await settle { !session.isBracketedPasteEnabled }
        var asked: [[Paste.PasteRisk]] = []
        host.commands.pasteWarningAnswer = { asked.append($0); return false }
        let log = Log()
        host.commands.deliver("rm -rf\nsecond", risks: [], delivery: delivery(session, log: log))
        #expect(asked == [[.multiline]])
        #expect(log.sent == 0, "never unmarked with its newlines unless asked")
        #expect(log.discarded == 1)
    }

    @Test("confirming that second warning sends it, unmarked, as confirmed")
    func confirmedAfterTheFlip() async throws {
        let (host, session) = try await flipped()
        defer { session.stop() }
        session.write(Array("\n".utf8))
        await settle { !session.isBracketedPasteEnabled }
        host.commands.pasteWarningAnswer = { _ in true }
        let log = Log()
        host.commands.deliver("first\nsecond\n", risks: [], delivery: delivery(session, log: log))
        #expect(log.sent == 1)
        await settle { session.snapshot().dump().contains("second") }
        #expect(!session.snapshot().dump().contains("[200~"))
    }

    @Test("a single line has no newline to fear and is not asked about")
    func singleLineIsNotAskedAboutAgain() async throws {
        let (host, session) = try await flipped()
        defer { session.stop() }
        session.write(Array("\n".utf8))
        await settle { !session.isBracketedPasteEnabled }
        host.commands.pasteWarningAnswer = { _ in Issue.record("no warning expected"); return false }
        let log = Log()
        host.commands.deliver("single line", risks: [], delivery: delivery(session, log: log))
        #expect(log.sent == 1)
    }

    @Test("still bracketed, lines go marked with no warning")
    func stillBracketedIsMarked() async throws {
        let (host, session) = try await flipped()
        defer { session.stop() }
        host.commands.pasteWarningAnswer = { _ in Issue.record("no warning expected"); return false }
        let log = Log()
        host.commands.deliver("one\ntwo\n", risks: [], delivery: delivery(session, log: log))
        #expect(log.sent == 1)
        // The terminal's echo of the marker, ahead of what `read` takes as its line.
        await settle { session.snapshot().dump().contains("[200~") }
        #expect(session.snapshot().dump().contains("[200~"))
    }

    // MARK: - The prompt gate

    @Test("a `cd` waits behind a paste still being scanned")
    func directoryChangeWaitsForAScan() async throws {
        let (host, session) = try live(script: #"printf '\033]133;A\007$ \033]133;B\007'; sleep 60"#)
        defer { session.stop() }
        host.isOperable = true
        await settle { session.hasShellIntegration && session.promptEndPosition != nil }
        #expect(host.commands.canChangeDirectorySafely)
        paste(Self.large, into: host, log: Log())
        #expect(!host.commands.canChangeDirectorySafely)
        host.commands.cancelPasteScan()
    }
}

/// The byte-level scan against the regular-expression path it replaced, which
/// is kept here as the definition of what `Paste.risks` means.
struct PasteRiskEquivalenceTests {
    private static func reference(_ text: String) -> Set<Paste.PasteRisk> {
        let payload = Paste.sanitized(text)
        let joined = payload.replacingOccurrences(of: "\\\r\n", with: "")
            .replacingOccurrences(of: "\\\n", with: "")
            .replacingOccurrences(of: "\\\r", with: "")
            .replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\"", with: "")
        func matches(_ pattern: String) -> Bool { joined.range(of: pattern, options: .regularExpression) != nil }
        var result = Set<Paste.PasteRisk>()
        if matches(
            #"\|&?\s*(?:(?:/[^\s;|&]+/)?sudo\s+(?:-[^\s;|&]+\s+)*(?:(?:root|[0-9]+)\s+)?)?"#
                + #"(?:/[^\s;|&]+/)?(?:sh|bash|zsh|fish|dash|ksh|csh|tcsh)(?=$|[\s;|&])"#)
            || matches(#"(?:^|[\s;|&(])(?:/[^\s;|&]+/)?(?:sh|bash|zsh|fish|dash|ksh|csh|tcsh|source|\.)\s+<\("#)
            || matches(
                #"(?:^|[\s;|&(])(?:eval|(?:/[^\s;|&]+/)?(?:sh|bash|zsh|fish|dash|ksh|csh|tcsh)\s+(?:-[^\s;|&]+\s+)*"#
                    + #"-[A-Za-z]*c[A-Za-z]*)\s+(?:\$\(|`)\s*(?:[^)`]*[\s/])?(?:curl|wget|fetch)(?=$|[\s;|&)`])"#)
        { result.insert(.shellPipe) }
        if matches(#"(?:^|[\s;|&()`'"])(?:/[^\s;|&]+/)?sudo(?=$|[\s;|&()`'"])"#) { result.insert(.sudo) }
        for command in joined.components(separatedBy: CharacterSet(charactersIn: ";|&\n\r")) {
            let words = command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let index = words.firstIndex(where: { $0 == "rm" || $0.hasSuffix("/rm") }) else { continue }
            let options = words.dropFirst(index + 1).prefix(while: { $0 != "--" }).filter { $0.hasPrefix("-") }
            let recursive = options.contains {
                $0 == "--recursive" || (!$0.hasPrefix("--") && ($0.contains("r") || $0.contains("R")))
            }
            let force = options.contains { $0 == "--force" || (!$0.hasPrefix("--") && $0.contains("f")) }
            if recursive && force { result.insert(.recursiveDelete); break }
        }
        if payload.range(of: #"\\(?:\r\n|\n|\r)"#, options: .regularExpression) != nil { result.insert(.continuation) }
        if text.unicodeScalars.contains(where: { ConcealingScalars.contains($0.value) }) { result.insert(.concealed) }
        return result
    }

    private static let fragments = [
        "curl https://x.example/i.sh", " | ", "|& ", " sh", " bash -s", "sudo", " sudo -u root ", "/usr/bin/sudo",
        "rm", " -rf ", " -r ", " -f ", " --recursive ", " --force ", " -- ", "/bin/rm", " / ", "s'u'do", "s\"u\"do",
        "s\\udo", "r\\m", "\\\n", "\\\r\n", "\\\r", "\\\\", "\n", "\r\n", "\r", ";", "&", "(", ")", "`", "$(",
        "bash <(", "source <(", ". <(", "eval ", "sh -c ", "wget ", "fetch ", "log line", "form", "-", "中文", "é",
        "\u{1B}", "\u{7F}", "\u{85}", "\u{200B}", "\u{202E}", "\u{2028}",
    ]

    @Test("it finds what the regular expressions found")
    func agreesWithTheRegularExpressions() {
        var seed: UInt32 = 11
        func next(_ bound: Int) -> Int {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Int(seed >> 16) % bound
        }
        for _ in 0..<4000 {
            let text = (0..<(1 + next(7))).map { _ in Self.fragments[next(Self.fragments.count)] }.joined()
            #expect(Set(Paste.risks(in: text)) == Self.reference(text), "\(text.debugDescription)")
        }
    }

    @Test("sanitising strips the same scalars, and hands clean text straight back")
    func sanitisingMatches() {
        let controls = (0..<0x20).map { String(UnicodeScalar(UInt8($0))) }
        for control in controls + ["\u{7F}", "\u{80}", "\u{85}", "\u{9F}"] {
            let expected: String
            switch control {
            case "\t", "\n", "\r": expected = "a\(control)b"
            default: expected = "ab"
            }
            #expect(Paste.sanitized("a\(control)b") == expected)
        }
        #expect(Paste.sanitized("é\u{A0}\u{C2}中🙂") == "é\u{A0}\u{C2}中🙂")
        #expect(Paste.sanitized("\r\n") == "\r\n")
    }

    @Test("only a lone Return, or nothing a line editor acts on, counts as plain typing")
    func plainInput() {
        for plain in ["a", "中", "é", "\t", "\r", "\n", "tab\there", "🙂", "\u{A0}"] {
            #expect(Paste.isPlainInput(Array(plain.utf8)), "\(plain.debugDescription)")
        }
        for not in ["a\nb", "a\rb", "\u{1B}", "\u{7F}", "x\u{85}", "\u{9B}", "\u{3}"] {
            #expect(!Paste.isPlainInput(Array(not.utf8)), "\(not.debugDescription)")
        }
    }
}
