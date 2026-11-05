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

import Darwin
import Foundation
import Testing

@testable import Corta
@testable import CortaTerminal

struct ProcessEntryPointTests {
    @Test func interpreterFlagsDoNotBecomeProgramNames() {
        #expect(ProcessEntryPoint.resolve(process: "node", arguments: ["node", "--require", "init.js", "/opt/kimi"])
            == "/opt/kimi")
        #expect(ProcessEntryPoint.resolve(process: "Python", arguments: ["python", "-u", "-m", "kimi_cli"])
            == "kimi_cli")
        #expect(ProcessEntryPoint.resolve(process: "bun", arguments: ["bun", "run", "agent.js"]) == "agent.js")
        #expect(ProcessEntryPoint.resolve(process: "node", arguments: ["node", "-e", "claude"]) == nil)
        #expect(ProcessEntryPoint.resolve(process: "python3", arguments: ["python3", "-c", "kimi"]) == nil)
        #expect(ProcessEntryPoint.resolve(process: "node", arguments: ["node", "--unknown-flag", "claude"]) == nil)
        #expect(ProcessEntryPoint.resolve(process: "ssh", arguments: ["ssh", "claude"]) == nil)
    }

    @Test func kernelArgumentParsingStopsBeforeEnvironment() {
        let args = ["python3", "-m", "kimi_cli"]
        var argc = Int32(args.count)
        var bytes = withUnsafeBytes(of: &argc) { Array($0) }
        bytes += Array("/usr/bin/python3\0\0\0".utf8)
        bytes += args.flatMap { Array(($0 + "\0").utf8) }
        bytes += Array("SECRET=not-an-entrypoint\0".utf8)
        #expect(ProcessEntryPoint.argumentPrefix(bytes) == args)
        #expect(ProcessEntryPoint.argumentPrefix([]).isEmpty)
        #expect(ProcessEntryPoint.argumentPrefix([0, 0, 0, 0, 0]).isEmpty)
        #expect(ProcessEntryPoint.argumentPrefix(Array(bytes.prefix(8))).isEmpty)
    }

    @Test @MainActor func pythonHostedCLIIsRecognisedFromTheLiveProcess() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("kimi")
        try "import time\ntime.sleep(30)\n".write(to: script, atomically: true, encoding: .utf8)
        let session = try TerminalSession(
            executable: "/usr/bin/python3", arguments: [script.path], environment: ChildEnvironment.default(),
            size: TerminalSize(rows: 24, columns: 80), workingDirectory: folder.path)
        defer { session.stop() }
        session.start()
        let deadline = SuspendingClock.now + .seconds(3) * testTimeoutScale
        var entry: String?
        while entry == nil, SuspendingClock.now < deadline {
            entry = session.activeProcessEntryPoint
            if entry == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(entry == script.path)
        #expect(ProgramIcon.identify(session.activeProcessName, entryPoint: entry) == .kimi)
    }
}
