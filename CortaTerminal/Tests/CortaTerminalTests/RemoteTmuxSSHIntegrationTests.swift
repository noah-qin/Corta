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
import CortaPOSIX
import Testing
@testable import CortaTerminal

@Suite("Space SSH/tmux encrypted localhost lifecycle", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["CORTA_TMUX_TEST_EXECUTABLE"] != nil,
             "Run scripts/verify-ssh-integration.py with an installed tmux"))
struct RemoteTmuxSSHIntegrationTests {
    private struct Fixture {
        let root: URL
        let configuration: String
        let executable: String

        init() throws {
            let env = ProcessInfo.processInfo.environment
            let parent = URL(fileURLWithPath: try #require(env["CORTA_SSH_TEST_ROOT"]))
            configuration = parent.appendingPathComponent("ssh.conf").path
            executable = try #require(env["CORTA_TMUX_TEST_EXECUTABLE"])
            root = parent.appendingPathComponent("tmux-" + UUID().uuidString)
            let bin = root.appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let wrapper = bin.appendingPathComponent("tmux")
            // Test-only socket/config/default shell; never touch an existing tmux server.
            try """
            #!/bin/sh
            if [ "$1" = new-session ]; then
                exec '\(executable)' -f /dev/null "$@" /bin/sh
            fi
            exec '\(executable)' -f /dev/null "$@"
            """.write(to: wrapper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        }

        var prefix: String {
            "PATH='\(root.path)/bin:/usr/bin:/bin' TMUX_TMPDIR='\(root.path)' "
                + "HOME='\(root.path)' ZDOTDIR='\(root.path)' SHELL=/bin/sh "
        }

        func connect(_ tmux: RemoteTmux?, config: String? = nil, command: String? = nil,
                     host: String = "fixture", options: [String] = [], environment: [String: String]? = nil
        ) throws -> TerminalSession {
            let session = try TerminalSession(executable: "/usr/bin/ssh", arguments:
                ["-F", config ?? configuration] + options + ["-t", "--", host, prefix + (command ?? tmux!.command)],
                environment: environment ?? ChildEnvironment.default())
            if let tmux { session.expectRemoteTmux(token: tmux.token) }
            session.start()
            return session
        }

        func query(_ command: String) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-F", configuration, "--", "fixture", prefix + command]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func cleanup(_ identities: [RemoteTmux]) {
            for tmux in identities { _ = try? query(tmux.killCommand) }
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = SuspendingClock.now + testTimeout(10)
        while !predicate(), SuspendingClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(predicate(), "condition did not arrive before timeout")
    }

    @Test func twoIdentitiesSurviveHangupAndReattachWithTheSameRemotePIDs() async throws {
        let fixture = try Fixture()
        let identities = [RemoteTmux(id: UUID()), RemoteTmux(id: UUID())]
        defer { fixture.cleanup(identities) }
        var sessions: [TerminalSession] = []
        defer { sessions.forEach { $0.stop() } }
        var pids: [String] = []
        for tmux in identities {
            let session = try fixture.connect(tmux)
            sessions.append(session)
            try await wait { session.remoteTmuxReport?.established == true }
            #expect(session.remoteTmuxReport?.outcome == .new)
            let pid = try fixture.query("tmux display-message -p -t '=\(tmux.sessionName):0.0' '#{pane_pid}'")
            try #require(Int(pid) != nil)
            pids.append(pid)
            // Each task replaces only its own fixture shell, so the pane PID stays stable.
            session.write(chunks: [Array("exec /bin/sleep 600\n".utf8)])
        }
        #expect(pids[0] != pids[1])
        // Same TerminalSession.stop path as panel/window/app teardown (PTY SIGHUP).
        sessions.forEach { $0.stop() }
        for (index, tmux) in identities.enumerated() {
            let session = try fixture.connect(RemoteTmux(id: tmux.id))
            sessions.append(session)
            try await wait { session.remoteTmuxReport?.outcome == .attached }
            let pid = try fixture.query("tmux display-message -p -t '=\(tmux.sessionName):0.0' '#{pane_pid}'")
            #expect(pid == pids[index])
            session.resize(to: TerminalSize(rows: 33, columns: 101))
        }
        // Targeted kill ends one only; the other task remains.
        _ = try fixture.query(identities[0].killCommand)
        #expect(try fixture.query("tmux has-session -t '=\(identities[1].sessionName)'; echo $?") == "0")
        let replacement = try fixture.connect(RemoteTmux(id: identities[0].id))
        sessions.append(replacement)
        try await wait { replacement.remoteTmuxReport?.outcome == .new }
    }

    @Test func detachEndsSSHAndOrdinarySSHHasNoRetainedRemoteProcess() async throws {
        let fixture = try Fixture()
        let tmux = RemoteTmux(id: UUID())
        defer { fixture.cleanup([tmux]) }
        let session = try fixture.connect(tmux)
        defer { session.stop() }
        try await wait { session.remoteTmuxReport?.established == true }
        // Detach through tmux itself, not by killing ssh or its PTY.
        _ = try fixture.query("tmux detach-client -s '=\(tmux.sessionName)'")
        try await wait { session.pty.exitStatus != nil }
        #expect(session.pty.exitStatus == .exited(code: 0))
        #expect(try fixture.query("tmux has-session -t '=\(tmux.sessionName)'; echo $?") == "0")
        let pidFile = fixture.root.appendingPathComponent("ordinary.pid")
        let ordinary = try fixture.connect(nil, command: "echo $$ > '\(pidFile.path)'; exec /bin/sleep 600")
        defer { ordinary.stop() }
        try await wait { FileManager.default.fileExists(atPath: pidFile.path) }
        let pid = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        ordinary.stop()
        try await wait { (try? fixture.query("kill -0 \(pid) 2>/dev/null; echo $?")) != "0" }
    }

    @Test func authenticationFailureNeverClaimsThatTmuxWasCreated() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup([]) }
        let wrong = URL(fileURLWithPath: fixture.configuration).deletingLastPathComponent()
            .appendingPathComponent("auth-failure.conf").path
        let session = try fixture.connect(RemoteTmux(id: UUID()), config: wrong)
        defer { session.stop() }
        try await wait { session.pty.exitStatus != nil }
        #expect(session.remoteTmuxReport?.established == false)
        #expect(session.remoteTmuxReport?.outcome == nil)
    }
    @Test func aliasesExplicitOptionsProxyJumpAndCancelledPassphrase() async throws {
        let fixture = try Fixture()
        let tmux = RemoteTmux(id: UUID())
        defer { fixture.cleanup([tmux]) }
        let parent = URL(fileURLWithPath: fixture.configuration).deletingLastPathComponent()
        let jumped = fixture.root.appendingPathComponent("jump.conf")
        let base = try String(contentsOfFile: fixture.configuration, encoding: .utf8)
        try (base + base.replacingOccurrences(of: "Host fixture", with: "Host jumped")
            + " ProxyJump fixture\n").write(to: jumped, atomically: true, encoding: .utf8)
        let session = try fixture.connect(tmux, config: jumped.path, host: "jumped")
        defer { session.stop() }
        try await wait { session.remoteTmuxReport?.established == true }
        session.stop()
        let port = try #require(ProcessInfo.processInfo.environment["CORTA_SSH_TEST_PORT"])
        let options = ["-l", NSUserName(), "-p", port,
                       "-i", parent.appendingPathComponent("client").path, "-oIdentitiesOnly=yes"]
        let explicit = try fixture.connect(RemoteTmux(id: tmux.id),
            config: parent.appendingPathComponent("bare.conf").path, host: "127.0.0.1", options: options)
        defer { explicit.stop() }
        try await wait { explicit.remoteTmuxReport?.outcome == .attached }
        explicit.resize(to: TerminalSize(rows: 33, columns: 101))
        try await wait {
            (try? fixture.query("tmux list-clients -t '=\(tmux.sessionName)' -F '#{client_width}'")) == "101"
        }
        explicit.stop()
        let askpass = fixture.root.appendingPathComponent("cancel-askpass")
        try "#!/bin/sh\nexit 1\n".write(to: askpass, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass.path)
        var environment = ChildEnvironment.default()
        environment["SSH_ASKPASS"] = askpass.path
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        let cancelled = try fixture.connect(RemoteTmux(id: UUID()),
            config: parent.appendingPathComponent("locked.conf").path, environment: environment)
        defer { cancelled.stop() }
        try await wait { cancelled.pty.exitStatus != nil }
        #expect(cancelled.remoteTmuxReport?.outcome == nil)
        #expect(cancelled.remoteTmuxReport?.established == false)
    }

    @Test func actualMissingAndBrokenTmuxFallBackIntoDifferentLoginShells() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup([]) }
        for shell in ["/bin/sh", "/bin/bash", "/bin/zsh"] {
            let tmux = RemoteTmux(id: UUID())
            let command = "PATH=/usr/bin:/bin SHELL=\(shell) " + tmux.command
            let missing = try fixture.connect(tmux, command: command)
            defer { missing.stop() }
            try await wait { missing.remoteTmuxReport?.outcome == .missing }
            missing.write(chunks: [Array("printf 'FALLBACK_OK\\n'\nexit\n".utf8)])
            try await wait { missing.pty.exitStatus != nil }
            #expect(missing.remoteTmuxReport?.established == false)
        }
        let broken = fixture.root.appendingPathComponent("bin/tmux")
        try "#!/bin/sh\necho 'fixture broken tmux' >&2\nexit 23\n".write(
            to: broken, atomically: true, encoding: .utf8)
        let session = try fixture.connect(RemoteTmux(id: UUID()))
        defer { session.stop() }
        try await wait { session.remoteTmuxReport?.failureStatus == 23 }
        #expect(session.remoteTmuxReport?.reason == "fixture broken tmux")
        session.write(chunks: [Array("exit\n".utf8)])
        try await wait { session.pty.exitStatus != nil }
    }

}
