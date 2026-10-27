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

@Suite("OSC coverage")
struct OSCCoverageTests {
    static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    static func documentedCodes(_ text: String) -> Set<Int> {
        Set(text.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("| `OSC ") else { return nil }
            return Int(line.dropFirst(7).prefix { $0.isNumber })
        })
    }
    static func dispatchedCodes(_ source: String) throws -> Set<Int> {
        let dispatch = try #require(source.components(separatedBy: "switch code {").last)
            .components(separatedBy: "default:").first!
        let pattern = try NSRegularExpression(pattern: #"case ([0-9, ]+):"#)
        let matches = pattern.matches(in: dispatch, range: NSRange(dispatch.startIndex..., in: dispatch))
        return Set(matches.flatMap { match in
            dispatch[Range(match.range(at: 1), in: dispatch)!].split(separator: ",").compactMap {
                Int($0.trimmingCharacters(in: .whitespaces))
            }
        })
    }
    @Test func conformanceAndDispatcherAgreeInBothDirections() throws {
        let source = try String(
            contentsOf: Self.root.appendingPathComponent("CortaTerminal/Sources/CortaTerminal/Performer+OSC.swift"),
            encoding: .utf8)
        let doc = try String(contentsOf: Self.root.appendingPathComponent("docs/CONFORMANCE.md"), encoding: .utf8)
        let handled = try Self.dispatchedCodes(source)
        let listed = Self.documentedCodes(doc)
        #expect(!handled.isEmpty)
        #expect(
            handled == listed,
            "OSC table drift: missing \(handled.subtracting(listed)), stale \(listed.subtracting(handled))")
        // Prove a missing row fails the same predicate, rather than merely
        // checking a hard-coded second copy of the dispatcher.
        let removed = doc.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("| `OSC 633`") }.joined(separator: "\n")
        #expect(Self.documentedCodes(removed) != handled)
    }
}
