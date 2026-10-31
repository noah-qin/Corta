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

import CryptoKit
import Foundation
import Testing
@testable import Corta

/// Regression contracts derived directly from #439.
@MainActor
@Suite(.serialized)
struct SpaceIssueAcceptanceTests {
    @Test("#439: index v4 strip counts use Git's offset encoding above 127 bytes")
    func indexV4HandlesLongPreviousPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        // Independently encoded fixture: two missing files, first name 140 bytes,
        // then strip all 140 bytes (Git OFS_DELTA encoding 0x80, 0x0c), suffix z.
        var data = Data([0x44, 0x49, 0x52, 0x43, 0, 0, 0, 4, 0, 0, 0, 2])
        data.append(Data(count: 60))
        data.append(contentsOf: [0, 140, 0])
        data.append(Data(repeating: 0x61, count: 140))
        data.append(0)
        data.append(Data(count: 60))
        data.append(contentsOf: [0, 1])
        data.append(contentsOf: [0x80, 0x0c, 0x7a, 0])
        data.append(contentsOf: Insecure.SHA1.hash(data: data))
        try data.write(to: git.appendingPathComponent("index"))
        let facts = try #require(GitStatusReader.read(directory: root.path))
        #expect(!facts.unchecked)
        #expect(facts.changedFiles == 2)
    }
}
