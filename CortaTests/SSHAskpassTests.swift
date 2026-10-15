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
import Synchronization
import Testing
@testable import Corta

struct SSHAskpassRulesTests {
    @Test func theQuestionFollowsSSHsKindAndItsHostKeyWording() {
        #expect(SSHAskpass.question(kind: .secret, prompt: "deploy@box's password: ") == .secret)
        #expect(SSHAskpass.question(kind: .secret, prompt: "Enter passphrase for key '/k': ") == .secret)
        let hostKey = """
            The authenticity of host 'box (203.0.113.9)' can't be established.
            ED25519 key fingerprint is SHA256:abc.
            Are you sure you want to continue connecting (yes/no/[fingerprint])?\u{20}
            """
        #expect(SSHAskpass.question(kind: .secret, prompt: hostKey) == .hostKey)
        #expect(SSHAskpass.question(kind: .secret, prompt: "continue connecting (yes/no)? ") == .hostKey)
        #expect(SSHAskpass.question(kind: .confirm, prompt: "Allow use of key?") == .confirm)
        #expect(SSHAskpass.question(kind: .notify, prompt: "Confirm user presence") == .notify)
        #expect(SSHAskpass.Kind(promptVariable: "confirm") == .confirm)
        #expect(SSHAskpass.Kind(promptVariable: "none") == .notify)
        #expect(SSHAskpass.Kind(promptVariable: nil) == .secret)
    }

    /// A keyboard-interactive prompt is the server's text: it must not be
    /// able to hide or reorder what the dialog says, or run on forever.
    @Test func aPromptIsShownCleanedAndBounded() {
        #expect(SSHAskpass.displayPrompt("Password:\u{1B}[2J ") == "Password:\u{FFFD}[2J")
        #expect(SSHAskpass.displayPrompt("a\u{202E}gpj.exe") == "a\u{FFFD}gpj.exe")
        #expect(SSHAskpass.displayPrompt("a\u{200B}b\tc\r\n\n") == "a\u{FFFD}b c")
        let many = (0..<100).map { "line \($0)" }.joined(separator: "\n")
        let shown = SSHAskpass.displayPrompt(many)
        #expect(shown.split(separator: "\n").count == SSHAskpass.promptLineLimit)
        #expect(shown.hasSuffix("…"))
        #expect(SSHAskpass.displayPrompt(String(repeating: "x", count: 10_000)).count == SSHAskpass.promptLimit + 1)
    }

    @Test func tokensAreRandomAndComparedWhole() throws {
        let one = try #require(SSHAskpass.makeToken())
        let two = try #require(SSHAskpass.makeToken())
        #expect(one.count == 64 && one != two)
        #expect(one.allSatisfy { $0.isHexDigit })
        #expect(SSHAskpass.tokensMatch(one, one))
        #expect(!SSHAskpass.tokensMatch(one, two))
        #expect(!SSHAskpass.tokensMatch(one, String(one.dropLast())))
    }

    @Test func theEnvironmentForcesAskpassThroughCorta() {
        let environment = SSHAskpass.environment(executable: "/A/Corta", socketPath: "/t/s", token: "t")
        #expect(environment["SSH_ASKPASS"] == "/A/Corta")
        #expect(environment["SSH_ASKPASS_REQUIRE"] == "force")
        #expect(environment[SSHAskpass.socketVariable] == "/t/s")
        #expect(environment[SSHAskpass.tokenVariable] == "t")
        // Never handed on to a shell: every CORTA_ name is stripped there.
        #expect(SSHAskpass.socketVariable.hasPrefix("CORTA_") && SSHAskpass.tokenVariable.hasPrefix("CORTA_"))
    }

    @Test func anOrdinaryLaunchIsNotAnAskpass() {
        #expect(SSHAskpassClient.runIfInvoked(environment: [:], arguments: ["Corta"]) == nil)
        #expect(SSHAskpassClient.runIfInvoked(
            environment: [SSHAskpass.socketVariable: "/t/s"], arguments: ["Corta"]) == nil)
    }
}

/// The whole path with the app's real executable as the askpass program:
/// this test process stands where ssh would, as the client's parent.
@Suite(.serialized)
struct SSHAskpassBrokerTests {
    /// What the prompter was asked, and what it answers.
    final class Recorder: Sendable {
        let asked = Mutex<[(SSHAskpass.Question, String, String)]>([])
        let cancelled = Mutex(false)
        let answer: String?
        let waitsForCancel: Bool

        init(answer: String?, waitsForCancel: Bool = false) {
            self.answer = answer
            self.waitsForCancel = waitsForCancel
        }

        var prompter: SSHAskpassBroker.Prompter {
            { [self] question, host, prompt in
                asked.withLock { $0.append((question, host, prompt)) }
                guard waitsForCancel else { return answer }
                await withTaskCancellationHandler {
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                } onCancel: {
                    self.cancelled.withLock { $0 = true }
                }
                return nil
            }
        }
    }

    private static var executable: String { Bundle.main.executablePath! }

    private func run(
        _ grant: SSHAskpassBroker.Grant, token: String? = nil, prompt: String,
        promptKind: String? = nil
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.executable)
        process.arguments = [prompt]
        var environment = grant.environment
        if let token { environment[SSHAskpass.tokenVariable] = token }
        if let promptKind { environment["SSH_ASKPASS_PROMPT"] = promptKind }
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    private func finish(_ process: Process) async -> (status: Int32, output: String) {
        let deadline = SuspendingClock.now + .seconds(10) * testTimeoutScale
        while process.isRunning, SuspendingClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        let data = (process.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test func anAdmittedSSHGetsTheAnswer() async throws {
        let recorder = Recorder(answer: "s3cret")
        let broker = SSHAskpassBroker(executable: Self.executable, prompter: recorder.prompter)
        defer { broker.stop() }
        let grant = try #require(broker.grant(host: "deploy@box:2222"))
        grant.admit(getpid())
        let result = await finish(try run(grant, prompt: "deploy@box's password: "))
        #expect(result.status == 0)
        #expect(result.output == "s3cret\n")
        let asked = recorder.asked.withLock { $0 }
        #expect(asked.count == 1)
        #expect(asked.first?.0 == .secret)
        #expect(asked.first?.1 == "deploy@box:2222")
        #expect(asked.first?.2 == "deploy@box's password:")
    }

    @Test func aRefusalIsACancelledQuestion() async throws {
        let recorder = Recorder(answer: nil)
        let broker = SSHAskpassBroker(executable: Self.executable, prompter: recorder.prompter)
        defer { broker.stop() }
        let grant = try #require(broker.grant(host: "box"))
        grant.admit(getpid())
        let result = await finish(try run(grant, prompt: "Password: "))
        #expect(result.status == 1)
        #expect(result.output.isEmpty)
    }

    @Test func aConfirmationAnswersByItsExitStatus() async throws {
        let recorder = Recorder(answer: "yes")
        let broker = SSHAskpassBroker(executable: Self.executable, prompter: recorder.prompter)
        defer { broker.stop() }
        let grant = try #require(broker.grant(host: "box"))
        grant.admit(getpid())
        let result = await finish(try run(grant, prompt: "Allow use of key?", promptKind: "confirm"))
        #expect(result.status == 0)
        #expect(recorder.asked.withLock { $0.first?.0 } == .confirm)
    }

    @Test func aWrongTokenIsNeverAsked() async throws {
        let recorder = Recorder(answer: "s3cret")
        let broker = SSHAskpassBroker(executable: Self.executable, prompter: recorder.prompter)
        defer { broker.stop() }
        let grant = try #require(broker.grant(host: "box"))
        grant.admit(getpid())
        let forged = String(repeating: "0", count: 64)
        let result = await finish(try run(grant, token: forged, prompt: "Password: "))
        #expect(result.status == 1)
        #expect(result.output.isEmpty)
        #expect(recorder.asked.withLock { $0.isEmpty })
    }

    /// The token alone is in ssh's environment, which the same user's
    /// processes can read. The parent check is what ties a question to an
    /// ssh this connection spawned.
    @Test func aProcessNotSpawnedByTheConnectionIsNeverAsked() async throws {
        let recorder = Recorder(answer: "s3cret")
        let broker = SSHAskpassBroker(executable: Self.executable, prompter: recorder.prompter)
        defer { broker.stop() }
        let grant = try #require(broker.grant(host: "box"))
        let result = await finish(try run(grant, prompt: "Password: "))
        #expect(result.status == 1)
        #expect(recorder.asked.withLock { $0.isEmpty })
    }

    @Test func aClosedConnectionCanAskNothing() async throws {
        let recorder = Recorder(answer: "s3cret")
        let broker = SSHAskpassBroker(executable: Self.executable, prompter: recorder.prompter)
        defer { broker.stop() }
        var grant: SSHAskpassBroker.Grant? = broker.grant(host: "box")
        grant?.admit(getpid())
        let environment = try #require(grant?.environment)
        grant = nil
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.executable)
        process.arguments = ["Password: "]
        process.environment = environment
        process.standardOutput = Pipe()
        try process.run()
        let result = await finish(process)
        #expect(result.status == 1)
        #expect(recorder.asked.withLock { $0.isEmpty })
    }

    /// ssh ending its askpass — the connection was cancelled, the key was
    /// touched — takes the dialog down instead of leaving it to answer
    /// nobody.
    @Test func theDialogGoesWhenTheAskerDoes() async throws {
        let recorder = Recorder(answer: nil, waitsForCancel: true)
        let broker = SSHAskpassBroker(executable: Self.executable, prompter: recorder.prompter)
        defer { broker.stop() }
        let grant = try #require(broker.grant(host: "box"))
        grant.admit(getpid())
        let process = try run(grant, prompt: "Confirm user presence for key ED25519-SK", promptKind: "none")
        let deadline = SuspendingClock.now + .seconds(10) * testTimeoutScale
        while recorder.asked.withLock({ $0.isEmpty }), SuspendingClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(recorder.asked.withLock { $0.first?.0 } == .notify)
        process.terminate()
        process.waitUntilExit()
        while !recorder.cancelled.withLock({ $0 }), SuspendingClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(recorder.cancelled.withLock { $0 })
    }

    /// A pid is reused once its process is gone. Admission is of that
    /// process — its start time — so a later one on the same number, which
    /// may have read the token while the first ran, is never answered.
    @Test func aRecycledPidIsNotTheSSHThatWasAdmitted() async throws {
        let recorder = Recorder(answer: "s3cret")
        let restarted = Mutex(false)
        let broker = SSHAskpassBroker(
            executable: Self.executable, prompter: recorder.prompter,
            record: { pid in
                guard var record = SSHAskpassBroker.processRecord(of: pid) else { return nil }
                if pid == getpid(), restarted.withLock({ $0 }) { record.started += 1 }
                return record
            })
        defer { broker.stop() }
        let grant = try #require(broker.grant(host: "box"))
        grant.admit(getpid())
        restarted.withLock { $0 = true }
        let result = await finish(try run(grant, prompt: "Password: "))
        #expect(result.status == 1)
        #expect(recorder.asked.withLock { $0.isEmpty })
    }

    /// A `ProxyJump`'s inner ssh asks for the jump host: the asker is a
    /// grandchild of the ssh the connection spawned, and is answered.
    @Test func aJumpHostsSSHMayAsk() async throws {
        let recorder = Recorder(answer: "jump-secret")
        let broker = SSHAskpassBroker(executable: Self.executable, prompter: recorder.prompter)
        defer { broker.stop() }
        let grant = try #require(broker.grant(host: "box"))
        grant.admit(getpid())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Not `exec`: the shell stays between, as the inner ssh would.
        process.arguments = ["-c", "\"$0\" \"$1\"; exit $?", Self.executable, "bastion's password: "]
        process.environment = grant.environment
        process.standardOutput = Pipe()
        try process.run()
        let result = await finish(process)
        #expect(result.status == 0)
        #expect(result.output == "jump-secret\n")
    }

    @Test func nothingListensAgainAfterStop() {
        let broker = SSHAskpassBroker(executable: Self.executable, prompter: { _, _, _ in nil })
        #expect(broker.grant(host: "box") != nil)
        broker.stop()
        #expect(broker.grant(host: "box") == nil, "a quit's late connection leaves no socket behind")
    }

    @Test func theSocketIsTheUsersAlone() throws {
        let broker = SSHAskpassBroker(executable: Self.executable, prompter: { _, _, _ in nil })
        let grant = try #require(broker.grant(host: "box"))
        let path = try #require(grant.environment[SSHAskpass.socketVariable])
        let directory = (path as NSString).deletingLastPathComponent
        let mode = try FileManager.default.attributesOfItem(atPath: directory)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        broker.stop()
        #expect(!FileManager.default.fileExists(atPath: directory))
    }
}
