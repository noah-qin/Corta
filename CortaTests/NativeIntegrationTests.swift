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

@MainActor
struct NativeIntegrationTests {
    @Test("pinch accumulation uses keyboard-sized steps and preserves remainder")
    func pinchSteps() {
        var accumulator: CGFloat = 0
        #expect(PaneCommands.fontSizes(
            forMagnification: 0.14, accumulator: &accumulator, startingAt: 12).isEmpty)
        #expect(accumulator == 0.14)
        #expect(PaneCommands.fontSizes(
            forMagnification: 0.31, accumulator: &accumulator, startingAt: 12) == [13, 14, 15])
        #expect(abs(accumulator) < 0.000_001)
    }

    @Test("pinch accumulation clamps and drops blocked remainder")
    func pinchClamp() {
        var accumulator: CGFloat = 0
        #expect(PaneCommands.fontSizes(
            forMagnification: 0.45, accumulator: &accumulator, startingAt: 63) == [64])
        #expect(accumulator == 0)
    }

    @Test("file pasteboards expose only file URL paths")
    func droppedFilePaths() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        _ = pasteboard.writeObjects([
            NSURL(fileURLWithPath: "/tmp/one file"),
            NSURL(fileURLWithPath: "/tmp/two")
        ])
        #expect(TerminalView.droppedPaths(from: pasteboard) == ["/tmp/one file", "/tmp/two"])

        pasteboard.clearContents()
        pasteboard.setString("https://example.com", forType: .string)
        #expect(TerminalView.droppedPaths(from: pasteboard).isEmpty)
    }

    @Test("Services exports and imports selected text")
    func servicesRoundTrip() {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let pasteboard = NSPasteboard.withUniqueName()
        view.onServicesSelection = { "selected text" }
        #expect(view.writeSelection(to: pasteboard, types: [.string]))
        #expect(pasteboard.string(forType: .string) == "selected text")

        var inserted: String?
        view.onServicesInsert = { inserted = $0 }
        #expect(view.readSelection(from: pasteboard))
        #expect(inserted == "selected text")
    }

    @Test("dropped shell paths quote metacharacters, apostrophes and backslashes")
    func shellQuoting() {
        #expect(PaneCommands.shellQuoted("/tmp/plain-file") == "/tmp/plain-file")
        #expect(PaneCommands.shellQuoted("/tmp/a b") == "'/tmp/a b'")
        #expect(PaneCommands.shellQuoted("/tmp/a'b") == #"'/tmp/a'"'"'b'"#)
        #expect(PaneCommands.shellQuoted(#"/tmp/a\b"#) == #"'/tmp/a'"\\"'b'"#)
        #expect(PaneCommands.shellQuoted("/tmp/$(touch hacked)") == "'/tmp/$(touch hacked)'")
    }

    /// The quoting is read by whatever shell the pane runs. fish's single
    /// quotes treat `\'` and `\\` as escapes, so POSIX's `'\''` let
    /// `x\'; cmd; \'` out of the quotes there. Each installed shell must
    /// read every name back exactly.
    @Test("every shell reads a quoted path back exactly", arguments: [
        "/bin/sh", "/bin/bash", "/bin/zsh", "/opt/homebrew/bin/fish", "/usr/local/bin/fish",
    ])
    func quotingRoundTripsThroughShells(shell: String) throws {
        // sh, bash and zsh ship with macOS; fish is checked where installed.
        let installed = FileManager.default.isExecutableFile(atPath: shell)
        try #require(installed || shell.hasSuffix("fish"), "\(shell) ships with macOS")
        guard installed else { return }
        let names = [
            #"/tmp/x\'; echo CORTA-PWNED; echo \'/sub"#, #"a\"#, "John's Folder",
            "$(echo CORTA-PWNED)", "tick`echo CORTA-PWNED`", #"double"quote"#, "😀 中文",
        ]
        for name in names {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            let script = "printf '%s\\n' " + PaneCommands.shellQuoted(name)
            process.arguments = (shell.hasSuffix("fish") ? ["--no-config"] : []) + ["-c", script]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(printed == name + "\n", "\(shell) read \(name.debugDescription) as \(printed.debugDescription)")
        }
    }

    @Test("dropped paths are sanitised before quoting")
    func dropTextSanitisesControls() {
        // ESC and the other C0 controls are stripped before quoting, and a
        // path reduced to nothing is left out of the run entirely.
        #expect(PaneCommands.quotedDropText(["/tmp/a\u{1B}[2Jb"]) == "'/tmp/a[2Jb'")
        #expect(PaneCommands.quotedDropText(["\u{7}", "/tmp/ok"]) == "/tmp/ok")
    }

    @Test("a newline in a dropped filename stays inside the quotes")
    func dropTextQuotesNewline() {
        // Inside single quotes a newline is a literal character, not an
        // executed line; the paste-path newline warning covers the rest.
        #expect(PaneCommands.quotedDropText(["/tmp/a\nb"]) == "'/tmp/a\nb'")
    }
}
