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

/// Opt in with CORTA_REAL_CLAUDE=/absolute/path/to/claude. Uses a fresh
/// configuration and never submits a model prompt or reads account tokens.
struct RealClaudeStatusTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CORTA_REAL_CLAUDE"] != nil))
    func installedClaudeAcceptsConstantProbeReply() throws {
        let executable = try #require(ProcessInfo.processInfo.environment["CORTA_REAL_CLAUDE"])
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("corta-claude-\(UUID())")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        let log = stage.appendingPathComponent("startup.log")
        var environment = ChildEnvironment.default()
        environment["CLAUDE_CONFIG_DIR"] = stage.path
        environment["TERM_PROGRAM"] = "Corta"
        environment["TERM"] = "xterm-256color"
        let session = try TerminalSession(executable: executable,
            arguments: ["--debug-file", log.path], environment: environment,
            workingDirectory: stage.path)
        defer { session.stop() }
        session.start()
        let deadline = SuspendingClock.now + .seconds(20)
        var evidence = ""
        while SuspendingClock.now < deadline {
            evidence = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            if evidence.contains("programStatus=yes") { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(evidence.contains("programStatus=yes"), "real Claude must accept Corta's constant OSC 7501 reply")
    }
}
