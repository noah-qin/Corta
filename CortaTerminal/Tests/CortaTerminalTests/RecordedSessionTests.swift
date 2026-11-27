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

import Foundation
import Testing

@testable import CortaTerminal

@Suite("Recorded CLI sessions")
struct RecordedSessionTests {
    struct Capture: Sendable, CustomStringConvertible {
        let name: String
        let includeScrollback: Bool
        let compareFresh: Bool
        let hasCheckpoint: Bool

        var description: String { name }
    }

    static let captures: [Capture] = [
        // Fullscreen Claude restores its parked main grid at exit. In this
        // capture the post-resize suffix starts on the already active alternate
        // screen, so feeding the suffix to a fresh main grid does not reproduce it.
        Capture(name: "claude-2.1.332-fullscreen", includeScrollback: false, compareFresh: false, hasCheckpoint: true),
        Capture(name: "claude-2.1.332-classic", includeScrollback: true, compareFresh: true, hasCheckpoint: false),
        Capture(name: "codex-0.171.0-fullscreen", includeScrollback: true, compareFresh: true, hasCheckpoint: true),
    ]

    @Test(arguments: captures)
    func replays(_ capture: Capture) throws {
        let recording = try RecordedSession.load(capture.name)
        let replay = recording.replay()
        let terminal = replay.terminal
        let grid = terminal.dump(options: DumpOptions(includeScrollback: capture.includeScrollback))
        let states = replay.states.map { $0 + "\n" }.joined()
        try verify(grid, for: capture, extension: "txt")
        try verify(states, for: capture, extension: "states")
        if capture.hasCheckpoint {
            #expect(replay.checkpoints.count == 1)
            let checkpoint = try #require(replay.checkpoints.first)
            try verify(checkpoint, for: capture, extension: "resized.txt")
        } else {
            #expect(replay.checkpoints.isEmpty)
        }
        #expect(!terminal.isBracketedPasteEnabled)
        #expect(!terminal.isSynchronizedOutputEnabled)
        #expect(!terminal.grid.isAlternateScreenActive)
        let fresh = try #require(replay.freshAfterLastResize)
        if capture.compareFresh {
            let expected = fresh.dump()
            let actual = terminal.dump()
            #expect(
                actual == expected,
                "\(capture.name) after resize\n\(Golden.diff(expected: expected, actual: actual))"
            )
        }
    }

    private func verify(_ actual: String, for capture: Capture, extension suffix: String) throws {
        let url = RecordedSession.directory.appendingPathComponent("\(capture.name).\(suffix)")
        if ProcessInfo.processInfo.environment["CORTA_UPDATE_RECORDINGS"] == "1" {
            try actual.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let expected = try String(contentsOf: url, encoding: .utf8)
        #expect(actual == expected, "\(url.lastPathComponent)\n\(Golden.diff(expected: expected, actual: actual))")
    }

    @Test func capturesStayWithinBudget() throws {
        let directory = RecordedSession.directory
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(Set(files.filter { $0.hasSuffix(".in") }) == Set(Self.captures.map { "\($0.name).in" }))
        var total = 0
        for name in files {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            if name.hasSuffix(".in") {
                #expect(data.count <= RecordedSession.maxFileBytes, "\(name): \(data.count) bytes")
            }
            total += data.count
        }
        #expect(total <= RecordedSession.maxTotalBytes, "recording suite: \(total) bytes")
    }

    @Test func loadsBytesAndResizesInOrder() throws {
        let recording = try RecordedSession(#"""
            # a small hand-written recording
            @size 2 8
            \x23A\r\n
            @resize 3 10
            \x40B
            """#)
        #expect(recording.initial.rows == 2)
        #expect(recording.initial.columns == 8)
        #expect(recording.events == [
            .bytes(Array("#A\r\n".utf8)), .resize(try #require(RecordedSession.Size(["3", "10"][...]))),
            .bytes(Array("@B".utf8)),
        ])
        let terminal = recording.replay().terminal
        #expect(terminal.grid.rows == 3)
        #expect(terminal.grid.columns == 10)
        #expect(terminal.dump().contains("@B"))
    }

    @Test func observesTwoStatusesInOneChunkAndOneAcrossResize() throws {
        let recording = try RecordedSession(#"""
            @size 2 8
            \e]7501;state=working\a\e]7501;state=blocked:kind=permission\e\\\e]7501;state=
            @resize 3 10
            done\a
            """#)
        #expect(recording.replay().states == ["working", "blocked/permission", "done"])
    }
}
