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

@testable import CortaTerminal

struct RecordedSession {
    struct Size: Equatable {
        let rows: Int
        let columns: Int

        init?(_ fields: ArraySlice<Substring>) {
            guard fields.count == 2,
                let rows = UInt16(fields[fields.startIndex]), rows > 0,
                let columns = UInt16(fields[fields.startIndex + 1]), columns > 0
            else { return nil }
            self.rows = Int(rows)
            self.columns = Int(columns)
        }

        func terminal() -> Terminal {
            Terminal(rows: rows, columns: columns)
        }
    }

    enum Event: Equatable {
        case bytes([UInt8])
        case resize(Size)
        case checkpoint
    }

    static let directory = Golden.directory.deletingLastPathComponent().appendingPathComponent("Recordings")
    static let maxFileBytes = 512 * 1024
    static let maxTotalBytes = 2 * 1024 * 1024

    let initial: Size
    let events: [Event]

    init(_ source: String) throws {
        var initial: Size?
        var bytes: [UInt8] = []
        var events: [Event] = []
        func flushBytes() {
            if !bytes.isEmpty { events.append(.bytes(bytes)) }
            bytes.removeAll(keepingCapacity: true)
        }

        // Split UTF-8 on the format's actual LF, even when adjacent to a
        // combining mark that Swift's String would treat as part of a cluster.
        for (index, rawLine) in source.utf8.split(separator: 0x0A, omittingEmptySubsequences: false).enumerated() {
            let line = String(decoding: rawLine, as: UTF8.self)
            if line == "# Grid checkpoint", initial != nil {
                flushBytes()
                events.append(.checkpoint)
                continue
            }
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("@") {
                let fields = line.split(separator: " ")
                guard let size = Size(fields.dropFirst()) else {
                    throw Golden.DecodeError(description: "invalid recording size at line \(index + 1): \(line)")
                }
                switch (fields.first, initial) {
                case ("@size", nil): initial = size
                case ("@resize", .some):
                    flushBytes()
                    events.append(.resize(size))
                default:
                    throw Golden.DecodeError(
                        description: "unexpected recording directive at line \(index + 1): \(line)")
                }
                continue
            }
            guard initial != nil else {
                throw Golden.DecodeError(description: "recording bytes before @size at line \(index + 1)")
            }
            bytes += try Golden.decode(line)
        }
        guard let initial else { throw Golden.DecodeError(description: "recording is missing @size") }
        flushBytes()
        self.initial = initial
        self.events = events
    }

    static func load(_ name: String) throws -> Self {
        let url = directory.appendingPathComponent("\(name).in")
        return try Self(String(contentsOf: url, encoding: .utf8))
    }

    var bytes: [UInt8] {
        events.flatMap { event -> [UInt8] in
            if case .bytes(let bytes) = event { return bytes }
            return []
        }
    }

    struct Replay {
        var terminal: Terminal
        var states: [String]
        var freshAfterLastResize: Terminal?
        var checkpoints: [String]
    }

    /// Split production input at each OSC 7501 dispatch using the VT parser.
    /// This also handles an OSC that starts before a recorded resize and
    /// ends after it, without guessing which BEL or ST belongs to it.
    private struct StatusBoundary: ParserPerformer {
        private static let prefix = Array("7501;".utf8)
        var found = false
        var requestsStopAfterAPC: Bool { found }
        mutating func oscDispatch(_ bytes: ArraySlice<UInt8>) {
            found = bytes.starts(with: Self.prefix)
        }
        func print(_ scalar: UInt32) {}
        func printASCII(_ bytes: ArraySlice<UInt8>) {}
        func printCJK(_ bytes: ArraySlice<UInt8>) {}
        func printReplacements(_ count: Int) {}
        func execute(_ control: UInt8) {}
    }

    func replay() -> Replay {
        var terminal = initial.terminal()
        var fresh: Terminal?
        var parser = Parser()
        var boundary = StatusBoundary()
        var states: [String] = []
        var checkpoints: [String] = []
        var last = "clear"
        for event in events {
            switch event {
            case .resize(let size):
                terminal.resize(rows: size.rows, columns: size.columns)
                fresh = size.terminal()
            case .checkpoint:
                checkpoints.append(terminal.dump())
            case .bytes(let bytes):
                fresh?.feed(bytes)
                var remaining = bytes[...]
                while !remaining.isEmpty {
                    boundary.found = false
                    let count = parser.parse(remaining, performer: &boundary, stoppingAfterAPC: true)
                    terminal.feed(remaining.prefix(count))
                    remaining = remaining.dropFirst(count)
                    if boundary.found {
                        let state = terminal.programStatuses[""].map {
                            $0.state.rawValue + ($0.kind.map { "/\($0.rawValue)" } ?? "")
                        } ?? "clear"
                        if state != last { states.append(state) }
                        last = state
                    }
                }
            }
        }
        return Replay(terminal: terminal, states: states, freshAfterLastResize: fresh, checkpoints: checkpoints)
    }
}
