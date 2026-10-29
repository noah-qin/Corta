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
import Darwin
import Foundation
import Testing
@testable import Corta

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CORTA_TMUX_TEST_EXECUTABLE"] != nil
    && MetalRenderTarget.supportsMetal4, "Run the isolated SSH fixture with --app on a Metal 4 Mac"))
struct CortaSpaceSSHIntegrationTests {
    @MainActor private final class Fixture {
        let fixture: URL
        let executable: String
        let root: URL
        let projectURL: URL
        let bin: URL
        let records: [SpaceSessionRecord]
        var launches = 0

        init() throws {
            let env = ProcessInfo.processInfo.environment
            fixture = URL(fileURLWithPath: try #require(env["CORTA_SSH_TEST_ROOT"]))
            executable = try #require(env["CORTA_TMUX_TEST_EXECUTABLE"])
            root = fixture.appendingPathComponent("app-lifecycle")
            projectURL = root.appendingPathComponent("project")
            bin = root.appendingPathComponent("bin")
            for directory in [projectURL, bin] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let wrapper = bin.appendingPathComponent("tmux")
            try """
            #!/bin/sh
            if [ "$1" = new-session ]; then exec '\(executable)' -f /dev/null "$@" /bin/sh; fi
            exec '\(executable)' -f /dev/null "$@"
            """.write(to: wrapper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
            records = (1...2).map { number in
                var record = SpaceSessionRecord(number: number, ssh: SSHTarget(host: "fixture"))
                record.retainSSH = true
                return record
            }
            SpaceStore.standard.save(SpaceState(projects: [
                SpaceProjectRecord(path: projectURL.path, sessions: records, layout: .panel(0), nextNumber: 3),
            ], selectedProject: projectURL.path))
        }

        func query(_ arguments: [String]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["-f", "/dev/null"] + arguments
            process.environment = ["TMUX_TMPDIR": root.path, "PATH": "/usr/bin:/bin"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func cleanup() {
            for record in records {
                _ = try? query(["kill-session", "-t", "=" + RemoteTmux(id: record.id).sessionName])
            }
            try? FileManager.default.removeItem(at: SpaceStore.standard.fileURL)
        }

        func makeWindow() throws -> (TerminalWindowController, SplitViewController) {
            let controller = TerminalWindowController(setup: .init())
            let host = try #require(controller.contentViewController as? SplitViewController)
            host.space.makeSSHPreset = { [self] target, tmux in
                launches += 1
                var preset = SSHDestination.preset(for: target, retaining: tmux)
                let preamble = ["-F", fixture.appendingPathComponent("ssh.conf").path]
                let leadIn = "PATH='\(bin.path):/usr/bin:/bin' TMUX_TMPDIR='\(root.path)' "
                    + "HOME='\(root.path)' ZDOTDIR='\(root.path)' SHELL=/bin/sh "
                if let tmux {
                    preset.retainedSSHPreamble = preamble
                    preset.retainedCommandLeadIn = leadIn
                    preset.arguments = SSHDestination.retainedArguments(
                        for: target, tmux: tmux, preamble: preamble, commandLeadIn: leadIn)
                } else {
                    preset.arguments.insert(contentsOf: preamble, at: 0)
                }
                return preset
            }
            controller.showWindow(nil)
            return (controller, host)
        }
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = SuspendingClock.now + .seconds(10) * testTimeoutScale
        while !condition(), SuspendingClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition())
    }

    @Test func windowTeardownAndReloadKeepRemotePIDsAndStartOnlyWhenSpaceOpens() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let (firstWindow, first) = try fixture.makeWindow()
        defer { first.teardown(); firstWindow.window?.close() }
        #expect(fixture.launches == 0, "constructing a window does not connect a remembered project")
        first.space.setActive(true)
        let project = try #require(first.space.selectedProject)
        #expect(fixture.launches == 2, "the off-grid session starts at first project opening too")
        try await wait { project.sessions.allSatisfy { $0.pane?.remote.tmuxReport?.established == true } }
        #expect(project.shown.count == 1)
        var pids: [String] = []
        for session in project.sessions {
            let name = RemoteTmux(id: session.id).sessionName
            let pid = try fixture.query(["display-message", "-p", "-t", "=\(name):0.0", "#{pane_pid}"])
            try #require(Int32(pid) != nil)
            pids.append(pid)
            session.pane?.session?.write(chunks: [Array("exec /bin/sleep 600\n".utf8)])
        }
        first.space.saveNow()
        first.teardown() // the same window/quit cleanup path; it must not kill remote tmux
        firstWindow.window?.close()
        for pid in pids { #expect(kill(try #require(Int32(pid)), 0) == 0) }
        fixture.launches = 0
        let (secondWindow, second) = try fixture.makeWindow()
        defer { second.teardown(); secondWindow.window?.close() }
        #expect(fixture.launches == 0)
        second.space.setActive(true)
        let reopened = try #require(second.space.selectedProject)
        #expect(reopened.sessions.map(\.id) == fixture.records.map(\.id))
        try await wait { reopened.sessions.allSatisfy { $0.pane?.remote.tmuxReport?.outcome == .attached } }
        for (index, session) in reopened.sessions.enumerated() {
            let name = RemoteTmux(id: session.id).sessionName
            #expect(try fixture.query(["display-message", "-p", "-t", "=\(name):0.0", "#{pane_pid}"]) == pids[index])
            #expect(session.record.tmuxEstablished == true)
        }
    }
}
