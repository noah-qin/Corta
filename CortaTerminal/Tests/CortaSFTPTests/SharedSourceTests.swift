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

/// `CortaSFTP` shares no code with the core, so the one piece of descriptor
/// machinery both need is a copy. A copy that drifts is a fix landed in one
/// place and not the other; this holds them equal.
@Suite("Shared source")
struct SharedSourceTests {
    @Test("GuardedDescriptor is the same file in both libraries")
    func guardedDescriptorCopiesMatch() throws {
        // …/Tests/CortaSFTPTests/SharedSourceTests.swift → …/Sources
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let core = try String(
            contentsOf: sources.appendingPathComponent("CortaTerminal/GuardedDescriptor.swift"),
            encoding: .utf8)
        let sftp = try String(
            contentsOf: sources.appendingPathComponent("CortaSFTP/GuardedDescriptor.swift"),
            encoding: .utf8)
        #expect(core.contains("final class GuardedDescriptor"))
        #expect(core == sftp)
    }
}
