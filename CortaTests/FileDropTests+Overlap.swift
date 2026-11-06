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
import Synchronization
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
    @Test("Finder's reference URL arrives as a plain path; one to a missing file fails")
    func referenceURLArrivesAsPath() async throws {
        let root = scratchRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("from finder")
        try Data().write(to: file)
        var info = stat()
        #expect(stat(file.path, &info) == 0)

        func drop(_ reference: String) async throws -> FileDropRequest.Result? {
            let item = NSPasteboardItem()
            item.setString(reference, forType: .fileURL)
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            pasteboard.writeObjects([item])
            var result: FileDropRequest.Result?
            let request = try #require(FileDropRequest.start(pasteboard) { result = $0 })
            await waitUntil("reference drop received") { result != nil }
            withExtendedLifetime(request) {}
            return result
        }

        let reference = "file:///.file/id=6571367.\(info.st_ino)"
        let received = try #require(try await drop(reference)?.urls.first)
        #expect(!received.absoluteString.contains(".file/id"))
        #expect(received.resolvingSymlinksInPath().path == file.resolvingSymlinksInPath().path)

        try FileManager.default.removeItem(at: file)
        let missing = try await drop(reference)
        #expect(missing?.urls.isEmpty == true)
        #expect(missing?.failed == true)
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
        #expect(FileManager.default.fileExists(atPath: pane.directory.path))
    }
}
