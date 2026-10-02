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

/// Opt-in encrypted TCP fixture. The runner creates private keys/configuration
/// and an unprivileged localhost sshd; no personal SSH policy is consulted.
@Suite("SSH/SFTP encrypted localhost integration", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["CORTA_SSH_TEST_ROOT"] != nil,
        "Run script/verify_ssh_integration.py to provide the isolated sshd fixture"))
struct SFTPSSHIntegrationTests {
    private var root: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["CORTA_SSH_TEST_ROOT"]!)
    }
    private func client(config: String = "ssh.conf") -> SFTPConnection {
        SFTPConnection(host: "fixture", arguments: ["-F", root.appendingPathComponent(config).path,
            "-s", "--", "fixture", "sftp"])
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
