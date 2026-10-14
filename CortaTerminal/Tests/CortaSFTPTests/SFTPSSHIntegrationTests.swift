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

@testable import CortaSFTP

/// Opt-in encrypted TCP fixture. The runner creates private keys/configuration
/// and an unprivileged localhost sshd; no personal SSH policy is consulted.
@Suite("SSH/SFTP encrypted localhost integration", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["CORTA_SSH_TEST_ROOT"] != nil,
        "Run scripts/verify-ssh-integration.py to provide the isolated sshd fixture"))
struct SFTPSSHIntegrationTests {
    private var root: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["CORTA_SSH_TEST_ROOT"]!)
    }
    private func client(config: String = "ssh.conf") -> SFTPConnection {
        SFTPConnection(host: "fixture", arguments: ["-F", root.appendingPathComponent(config).path,
            "-s", "--", "fixture", "sftp"], environment: ProcessInfo.processInfo.environment)
    }

    @Test("real SSH authentication, host verification and SFTP round-trip")
    func authenticatedRoundTrip() async throws {
        let connection = client()
        defer { connection.close() }
        #expect(try await connection.connect().version == 3)
        let source = root.appendingPathComponent("payload")
        let target = root.appendingPathComponent("download")
        let bytes = Data((0..<200000).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        _ = try await connection.upload(from: source, to: root.appendingPathComponent("remote/file").path,
            policy: .overwrite, partialDisposition: .remove, progress: nil)
        _ = try await connection.download(remotePath: root.appendingPathComponent("remote/file").path,
            to: target, policy: .overwrite, partialDisposition: .remove, progress: nil)
        #expect(try Data(contentsOf: target) == bytes)
        connection.close()
        await #expect(throws: SFTPError.self) { try await connection.listDirectory(path: "/") }
    }

    /// The connect sheet's fields, not the config, name the user, port and
    /// key: the argv `SFTPSubprocessChannel.arguments(host:options:)` builds
    /// for them reaches a real sshd.
    @Test("a user, port and key given as options sign in")
    func optionsSignIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        let port = try #require(environment["CORTA_SSH_TEST_PORT"])
        let options = ["-F", root.appendingPathComponent("bare.conf").path,
            "-l", NSUserName(), "-p", port,
            "-i", root.appendingPathComponent("client").path, "-oIdentitiesOnly=yes"]
        let connection = SFTPConnection(
            host: "127.0.0.1",
            arguments: SFTPSubprocessChannel.arguments(host: "127.0.0.1", options: options),
            environment: environment)
        defer { connection.close() }
        #expect(try await connection.connect().version == 3)
    }

    /// OpenSSH's `SSH_ASKPASS`, forced, with no terminal: what the app's
    /// askpass rides on. A stand-in program answers here; the app's own is
    /// tested against its broker in `SSHAskpassBrokerTests`.
    private func askpass(answering answer: String) throws -> (environment: [String: String], log: URL) {
        let log = root.appendingPathComponent("askpass-\(UUID().uuidString).log")
        let script = root.appendingPathComponent("askpass-\(UUID().uuidString).sh")
        try """
            #!/bin/sh
            printf '%s\\n--\\n' "$1" >> '\(log.path)'
            printf '%s\\n' '\(answer)'
            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = script.path
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment.removeValue(forKey: "DISPLAY")
        return (environment, log)
    }

    @Test("a key passphrase is asked through SSH_ASKPASS and signs in")
    func passphraseThroughAskpass() async throws {
        let (environment, log) = try askpass(answering: "corta pass phrase")
        let connection = SFTPConnection(host: "fixture", arguments: ["-F", root.appendingPathComponent("locked.conf").path,
            "-s", "--", "fixture", "sftp"], environment: environment)
        defer { connection.close() }
        #expect(try await connection.connect().version == 3)
        #expect(try String(contentsOf: log, encoding: .utf8).contains("passphrase"))
    }

    @Test("a wrong passphrase through SSH_ASKPASS is an authentication failure")
    func wrongPassphraseThroughAskpass() async throws {
        let (environment, _) = try askpass(answering: "not it")
        let connection = SFTPConnection(host: "fixture", arguments: ["-F", root.appendingPathComponent("locked.conf").path,
            "-s", "--", "fixture", "sftp"], environment: environment)
        defer { connection.close() }
        await #expect(throws: SFTPError.self) { try await connection.connect() }
    }

    /// The question the app shows as "Trust the host key": ssh's own, ending
    /// in "(yes/no/[fingerprint])?", answered "yes", and the key then saved.
    @Test("an unknown host key is asked through SSH_ASKPASS and accepted")
    func hostKeyThroughAskpass() async throws {
        let known = root.appendingPathComponent("tofu_known_hosts")
        try? FileManager.default.removeItem(at: known)
        let (environment, log) = try askpass(answering: "yes")
        let connection = SFTPConnection(host: "fixture", arguments: ["-F", root.appendingPathComponent("tofu.conf").path,
            "-s", "--", "fixture", "sftp"], environment: environment)
        defer { connection.close() }
        #expect(try await connection.connect().version == 3)
        let asked = try String(contentsOf: log, encoding: .utf8)
        #expect(asked.contains("(yes/no/[fingerprint])?"))
        #expect(FileManager.default.fileExists(atPath: known.path))
    }

    /// A `RemoteCommand` or `RequestTTY force` written for interactive
    /// logins: ssh would refuse the subsystem, or a remote terminal would
    /// mangle the frames, unless the channel switches them off.
    @Test("login-only RemoteCommand and RequestTTY do not reach the channel")
    func loginSettingsAreOverridden() async throws {
        let connection = SFTPConnection(
            host: "fixture",
            arguments: SFTPSubprocessChannel.arguments(
                host: "fixture", options: ["-F", root.appendingPathComponent("login.conf").path]),
            environment: ProcessInfo.processInfo.environment)
        defer { connection.close() }
        #expect(try await connection.connect().version == 3)
    }

    @Test("wrong client key cannot establish an SFTP session")
    func authenticationFails() async {
        let connection = client(config: "auth-failure.conf")
        defer { connection.close() }
        await #expect(throws: SFTPError.self) { try await connection.connect() }
        #expect(connection.capabilities == nil)
    }

    @Test("wrong known host key cannot establish an SFTP session")
    func hostKeyFails() async {
        let connection = client(config: "key-failure.conf")
        defer { connection.close() }
        await #expect(throws: SFTPError.self) { try await connection.connect() }
        #expect(connection.capabilities == nil)
    }
}
