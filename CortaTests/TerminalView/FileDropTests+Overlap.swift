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
import Testing

@testable import Corta

/// A pane with a live session, one drop in flight, for a second drop to meet.
@MainActor
private struct ReceivingPane {
    let host = CommandsTestHost()
    let session: TerminalSession
    let directory: URL
    private let earlier: Completion

    @MainActor private final class Completion { var done = false }
    var isCompleted: Bool { earlier.done }

    init(in root: URL) throws {
        directory = try FileDropStorage.makeDirectory(in: root)
        host.terminalView = TerminalView(frame: .zero)
        session = try TerminalSession(executable: "/bin/cat", arguments: [],
            environment: ChildEnvironment.default(), size: TerminalSize(rows: 10, columns: 60),
            workingDirectory: "/")
        session.start()
        host.session = session
        let completion = Completion()
        earlier = completion
        let request = FileDropRequest(count: 1, directory: directory) { _ in completion.done = true }
        request.receive(LatePromiseReceiver(names: ["slow"]),
            at: FileDropStorage.destination(in: directory), index: 0)
        request.seal()
        host.commands.fileDropRequest = request
    }
}

extension FileDropTests {
    /// Clean Now is in another window: it must not take the files out from
    /// under a warning still asking whether to name them.
    @Test("a dropped copy stays pinned while its warning is open, and is released once sent")
    func copyPinnedThroughTheWarning() throws {
        let root = scratchRoot()
        defer { FileDropStorage.remove(root) }
        let directory = try FileDropStorage.makeDirectory(in: root)
        let file = directory.appendingPathComponent("name\nwith a line")
        try Data().write(to: file)
        let host = CommandsTestHost()
        host.terminalView = TerminalView(frame: .zero)
        let session = try TerminalSession(executable: "/bin/cat", arguments: [],
            environment: ChildEnvironment.default(), size: TerminalSize(rows: 10, columns: 60),
            workingDirectory: "/")
        defer { session.stop() }
        session.start()
        host.session = session
        var survived = false
        // Named with a concealed scalar, so it warns under any `?2004`.
        let named = directory.appendingPathComponent("a\u{202E}b")
        try Data().write(to: named)
        host.commands.pasteWarningAnswer = { _ in
            FileDropStorage.removeUnpinned(in: [root])
            survived = FileManager.default.fileExists(atPath: named.path)
            return true
        }
        host.commands.completeFileDrop(.init(urls: [named], directory: directory,
            failed: false, timedOut: false), context: try #require(host.commands.dropInputContext))
        #expect(survived)
        // Sent: an ordinary finished copy now, for Clean Now to take.
        FileDropStorage.removeUnpinned(in: [root])
        #expect(!FileManager.default.fileExists(atPath: named.path))
    }

    @Test("a new drop replaces one still arriving, and says so")
    func newDropReplacesEarlier() async throws {
        let root = scratchRoot()
        defer { FileDropStorage.remove(root) }
        let pane = try ReceivingPane(in: root)
        defer { pane.session.stop() }
        let item = NSPasteboardItem()
        item.setString("file:///tmp/next", forType: .fileURL)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([item])

        #expect(pane.host.commands.receiveFileDrop(pasteboard))

        #expect(!FileManager.default.fileExists(atPath: pane.directory.path))
        #expect(pane.host.terminalView.toastLayer != nil)
        await waitUntil("the new drop finished") { pane.host.commands.fileDropRequest == nil }
        #expect(!pane.isCompleted)
    }

    @Test("a drop that cannot start leaves the one still arriving alone")
    func failedDropKeepsEarlier() throws {
        let root = scratchRoot()
        defer { FileDropStorage.remove(root) }
        let pane = try ReceivingPane(in: root)
        defer { pane.session.stop(); pane.host.commands.stop() }
        let earlier = pane.host.commands.fileDropRequest
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("not a file", forType: .string)

        #expect(!pane.host.commands.receiveFileDrop(pasteboard))

        #expect(pane.host.commands.fileDropRequest === earlier)
        #expect(pane.host.terminalView.toastLayer != nil)
        #expect(FileManager.default.fileExists(atPath: pane.directory.path))
    }
}
