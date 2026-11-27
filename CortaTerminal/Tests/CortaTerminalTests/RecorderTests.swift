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

import CortaPOSIX
import Darwin
import Foundation
import Testing

@testable import CortaTerminal

@Suite("PTY recorder")
struct RecorderTests {
    private final class BundleAnchor {}

    @Test func recordsARealPTYAndReplaysItsResize() throws {
        let executable = Bundle(for: BundleAnchor.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("corta-record")
        try #require(FileManager.default.isExecutableFile(atPath: executable.path))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("fixture.in")
        let script = #"""
            stty -echo -onlcr
            printf '#ready\r\n'
            IFS= read -r answer
            printf '\033[3;1H@%s / %s' "$answer" "$(stty size)"
            """#
        let pty = try PTY.spawn(
            executable: executable.path,
            arguments: [output.path, "test", "1", "main", "test", "--", "/bin/sh", "-c", script],
            size: TerminalSize(rows: 2, columns: 20))
        defer {
            _ = pty.terminate()
            pty.close()
        }

        var forwarded: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 256)
        let deadline = SuspendingClock.now + testTimeout(5)
        let ready = Array("#ready\r\n".utf8)
        while forwarded.count < ready.count, SuspendingClock.now < deadline {
            guard try pty.waitUntilReadable(timeoutMilliseconds: 50) else { continue }
            let count = try buffer.withUnsafeMutableBytes { try pty.read(into: $0) }
            if count == 0 { break }
            forwarded += buffer.prefix(count)
        }
        try #require(forwarded == ready)

        try pty.resize(to: TerminalSize(rows: 4, columns: 24))
        _ = try Array("answer\n".utf8).withUnsafeBytes { try pty.writeAll($0) }
        while SuspendingClock.now < deadline {
            guard try pty.waitUntilReadable(timeoutMilliseconds: 50) else { continue }
            let count = try buffer.withUnsafeMutableBytes { try pty.read(into: $0) }
            if count == 0 { break }
            forwarded += buffer.prefix(count)
        }
        #expect(pty.waitForExit(timeout: testTimeout(1)) == .exited(code: 0))
        let source = try String(contentsOf: output, encoding: .utf8)
        #expect(source.contains(#"\x23ready"#) && source.contains("@resize 4 24\n"))
        let recording = try RecordedSession(source)
        #expect(recording.bytes == forwarded)

        var expected = Terminal(rows: 2, columns: 20)
        expected.feed(ready)
        expected.resize(rows: 4, columns: 24)
        expected.feed(Array("\u{1b}[3;1H@answer / 4 24".utf8))
        #expect(recording.replay().terminal.dump() == expected.dump())
    }
}
