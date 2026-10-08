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

@testable import CortaSFTP

/// SFTP against the real thing: `/usr/libexec/sftp-server` is on every Mac,
/// and `SFTPSubprocessChannel.spawn` takes an executable and argv, so the
/// whole stack — spawn, pipes, codec, session, engine — runs against
/// OpenSSH's own server on a temporary directory, with no ssh, no network
/// and no change to the machine. The in-memory fake server in
/// `SFTPTestSupport` cannot vouch for any of this; the first run here
/// found a spawn that never returned.
@Suite("SFTP against the real sftp-server", .serialized)
struct SFTPRealServerTests {
    private static let server = "/usr/libexec/sftp-server"

    private static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-sftp-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("srv/app/src"), withIntermediateDirectories: true)
        try "hello\n".write(
            to: root.appendingPathComponent("srv/app/README.md"), atomically: true, encoding: .utf8)
        return root
    }

    /// A connection whose "ssh" is the server itself.
    private static func connect(root: URL) async throws -> SFTPConnection {
        let client = SFTPConnection(
            host: "local", sshExecutable: server, arguments: ["-d", root.path],
            environment: ProcessInfo.processInfo.environment)
        _ = try await client.connect()
        return client
    }

    @Test("directory downloads refuse existing destination symlinks")
    func localDestinationLinkRejected() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try await Self.connect(root: root)
        defer { client.close() }
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: target.appendingPathComponent("src"), withDestinationURL: outside)
        await #expect(throws: SFTPError.self) {
            try await client.downloadDirectory(remotePath: root.appendingPathComponent("srv/app").path,
                to: target, policy: .overwrite, progress: nil)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    /// The folder the user chose — and anything above it — may itself be a
    /// link (a `~/Downloads` on another volume); only what the transfer
    /// creates or merges into is held to the no-link rule.
    @Test("a linked folder the user chose is a valid destination")
    func linkedChosenFolderAccepted() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try await Self.connect(root: root)
        defer { client.close() }
        let realFolder = root.appendingPathComponent("volume/Downloads")
        try FileManager.default.createDirectory(at: realFolder, withIntermediateDirectories: true)
        let linkedFolder = root.appendingPathComponent("Downloads")
        try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: realFolder)
        try await client.downloadDirectory(
            remotePath: root.appendingPathComponent("srv/app").path,
            to: linkedFolder.appendingPathComponent("app"), policy: .overwrite, progress: nil)
        #expect(FileManager.default.fileExists(
            atPath: realFolder.appendingPathComponent("app/README.md").path))
    }

    /// exFAT, FAT and some SMB shares have no ACLs: clearing one answers
    /// ENOTSUP, which once failed every download to them. Opt-in, because
    /// the volume has to be mounted for it — `TESTING.md` has the recipe,
    /// which mounts a scratch disk image and detaches it afterwards.
    @Test(
        "a download lands on a volume without ACL support",
        .enabled(if: ProcessInfo.processInfo.environment["CORTA_NOACL_VOLUME"] != nil))
    func downloadToVolumeWithoutACLs() async throws {
        let volume = URL(
            fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CORTA_NOACL_VOLUME"]))
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try await Self.connect(root: root)
        defer { client.close() }
        let folder = volume.appendingPathComponent("corta-noacl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("README.md")
        _ = try await client.download(
            remotePath: root.appendingPathComponent("srv/app/README.md").path, to: destination,
            policy: .overwrite, partialDisposition: .remove, progress: nil)
        #expect(
            try Data(contentsOf: destination)
                == Data(contentsOf: root.appendingPathComponent("srv/app/README.md")))
    }

    @Test("spawn returns, INIT/VERSION completes, and a listing comes back")
    func connectAndList() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try await Self.connect(root: root)
        defer { client.close() }
        let capabilities = try #require(client.capabilities)
        #expect(capabilities.version == 3)
        #expect(capabilities.extensions["posix-rename@openssh.com"] != nil)
        let app = root.appendingPathComponent("srv/app").path
        let names = try await client.listDirectory(path: app).map(\.filenameUTF8).sorted()
        #expect(names.contains("README.md") && names.contains("src"))
        let volume = try await client.volumeInfo(path: app)
        #expect(volume != nil, "OpenSSH advertises statvfs@openssh.com")
    }

    @Test("upload and download round-trip through the real server atomically")
    func uploadAndDownload() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try await Self.connect(root: root)
        defer { client.close() }
        let app = root.appendingPathComponent("srv/app")
        let payload = Data((0..<700_000).map { UInt8($0 % 251) })
        let local = root.appendingPathComponent("payload.bin")
        try payload.write(to: local)

        let up = try await client.upload(
            from: local, to: app.appendingPathComponent("payload.bin").path,
            policy: .fail, partialDisposition: .remove, progress: nil)
        #expect(up.bytesTransferred == UInt64(payload.count))
        #expect(try Data(contentsOf: app.appendingPathComponent("payload.bin")) == payload)

        // A permissive inherited ACL must not enlarge the downloaded copy.
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "everyone allow read,file_inherit,directory_inherit", root.path]
        try chmod.run()
        chmod.waitUntilExit()
        #expect(chmod.terminationStatus == 0)
        let down = root.appendingPathComponent("payload-down.bin")
        let receipt = try await client.download(
            remotePath: app.appendingPathComponent("payload.bin").path, to: down,
            policy: .fail, partialDisposition: .remove, progress: nil)
        #expect(receipt.bytesTransferred == UInt64(payload.count))
        #expect(try Data(contentsOf: down) == payload)
        let mode = try FileManager.default.attributesOfItem(atPath: down.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        if let acl = acl_get_file(down.path, ACL_TYPE_EXTENDED) {
            acl_free(UnsafeMutableRawPointer(acl))
            Issue.record("download must not retain the inherited ACL")
        } else {
            #expect(errno == ENOENT)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: app.path)
        #expect(!leftovers.contains { $0.contains(".corta-part") }, "\(leftovers)")
    }

    /// A tree goes up and comes back: nested directories, an empty one,
    /// files of several sizes; a symbolic link and a socket-like special
    /// are skipped and *reported*, never followed; the result is
    /// byte-identical.
    @Test("a directory tree round-trips, skipping and reporting what is not a regular file")
    func directoryRoundTrip() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try await Self.connect(root: root)
        defer { client.close() }
        let files = FileManager.default

        // The local tree to send.
        let source = root.appendingPathComponent("source")
        try files.createDirectory(
            at: source.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try files.createDirectory(
            at: source.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try "top\n".write(to: source.appendingPathComponent("top.txt"), atomically: true, encoding: .utf8)
        try Data((0..<150_000).map { UInt8($0 % 13) }).write(to: source.appendingPathComponent("a/mid.bin"))
        try "deep\n".write(to: source.appendingPathComponent("a/b/deep.txt"), atomically: true, encoding: .utf8)
        try files.createSymbolicLink(
            at: source.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/etc"))

        let remote = root.appendingPathComponent("srv/app/uploaded").path
        let progressBox = Mutex<SFTPTransferEngine.DirectoryTransferProgress?>(nil)
        let up = try await client.uploadDirectory(
            from: source, to: remote, policy: .fail,
            progress: { p in progressBox.withLock { $0 = p } })
        let lastProgress = progressBox.withLock { $0 }
        #expect(up.filesTransferred == 3)
        #expect(up.directoriesCreated == 4, "uploaded, a, a/b, empty")
        #expect(up.skipped == [.init(relativePath: "escape", reason: .symbolicLink)])
        #expect(lastProgress?.filesCompleted == 3 && lastProgress?.filesTotal == 3)
        #expect(files.fileExists(atPath: remote + "/empty"))
        #expect(!files.fileExists(atPath: remote + "/escape"), "the link is not followed or recreated")
        #expect(try Data(contentsOf: URL(fileURLWithPath: remote + "/a/mid.bin")).count == 150_000)

        // Back down into a fresh directory.
        let target = root.appendingPathComponent("downloaded")
        let down = try await client.downloadDirectory(
            remotePath: remote, to: target, policy: .fail, progress: nil)
        #expect(down.filesTransferred == 3 && down.skipped.isEmpty)
        #expect(
            try String(contentsOf: target.appendingPathComponent("a/b/deep.txt"), encoding: .utf8) == "deep\n")
        #expect(
            try Data(contentsOf: target.appendingPathComponent("a/mid.bin"))
                == Data(contentsOf: source.appendingPathComponent("a/mid.bin")))
        #expect(files.fileExists(atPath: target.appendingPathComponent("empty").path))
        let leftovers = try files.subpathsOfDirectory(atPath: target.path)
        #expect(!leftovers.contains { $0.contains(".corta-part") }, "\(leftovers)")

        // Merging into an existing tree: `.fail` stops at the first file
        // already there, `.overwrite` replaces it and leaves the rest.
        await #expect(throws: SFTPError.self) {
            try await client.downloadDirectory(remotePath: remote, to: target, policy: .fail, progress: nil)
        }
        try "stale\n".write(to: target.appendingPathComponent("top.txt"), atomically: true, encoding: .utf8)
        let merged = try await client.downloadDirectory(
            remotePath: remote, to: target, policy: .overwrite, progress: nil)
        #expect(merged.filesTransferred == 3 && merged.directoriesCreated == 0)
        #expect(try String(contentsOf: target.appendingPathComponent("top.txt"), encoding: .utf8) == "top\n")
    }

    /// A remote symbolic link inside the tree is skipped on download and
    /// reported — the server would happily serve its target.
    @Test("a remote symbolic link is skipped and reported on download")
    func remoteLinkSkipped() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("srv/app")
        try FileManager.default.createSymbolicLink(
            at: app.appendingPathComponent("hosts"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        let client = try await Self.connect(root: root)
        defer { client.close() }
        let target = root.appendingPathComponent("down")
        let receipt = try await client.downloadDirectory(
            remotePath: app.path, to: target, policy: .fail, progress: nil)
        #expect(receipt.filesTransferred == 1, "README.md only")
        #expect(receipt.skipped == [.init(relativePath: "hosts", reason: .symbolicLink)])
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("hosts").path))
    }

    /// OpenSSH's server moves a file's mtime on every WRITE, so the stamp
    /// an upload set on its partial at OPEN was gone when a cancel kept
    /// the partial, and the retry silently started again from zero. The
    /// fake server never moved it, so only the real one shows this.
    @Test("a cancelled upload resumes against the real server")
    func cancelledUploadResumes() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data((0..<(2 * 1024 * 1024)).map { UInt8($0 % 241) })
        let local = root.appendingPathComponent("big.bin")
        try payload.write(to: local)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: local.path)
        let remote = root.appendingPathComponent("srv/app/big.bin").path

        let first = try await Self.connect(root: root)
        let moved = Mutex(false)
        let transfer = Task {
            try await first.upload(
                from: local, to: remote, policy: .resume, partialDisposition: .keepForResume
            ) { progress in
                if progress.completedBytes > 0 { moved.withLock { $0 = true } }
            }
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while !moved.withLock({ $0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        transfer.cancel()
        _ = try? await transfer.value
        first.close()
        let partial = remote + SFTPTransferEngine.partialSuffix
        let kept = (try? FileManager.default.attributesOfItem(atPath: partial)[.size] as? NSNumber)?
            .uint64Value ?? 0
        guard kept > 0, kept < UInt64(payload.count) else {
            // The whole file went up before the cancel landed: nothing to resume.
            return
        }

        // A new connection — no memory of the first — trusts the stamp.
        let second = try await Self.connect(root: root)
        defer { second.close() }
        let receipt = try await second.upload(
            from: local, to: remote, policy: .resume, partialDisposition: .keepForResume,
            progress: nil)
        #expect(receipt.resumedFromOffset == kept)
        #expect(try Data(contentsOf: URL(fileURLWithPath: remote)) == payload)
    }

    @Test("a missing executable fails the spawn, not the connection")
    func missingExecutableFails() async {
        let client = SFTPConnection(
            host: "x", sshExecutable: "/nonexistent/ssh",
            environment: ProcessInfo.processInfo.environment)
        await #expect(throws: SFTPError.self) { try await client.connect() }
    }

    /// The first connect is the one a password prompt fails: ssh has no
    /// terminal to ask on, writes "Permission denied" and exits 255 before
    /// a single frame. That has to reach the caller as an authentication
    /// failure — which it did not, because the reclassification read the
    /// connection's *stored* channel, and nothing is stored until a session
    /// is up. An `ssh` stand-in that refuses the way ssh does covers the
    /// path without a network.
    @Test("a refusal on the first connect is classified, not reported as a lost connection")
    func firstConnectRefusalIsClassified() async throws {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-sftp-refuse-\(UUID().uuidString).sh")
        try """
            #!/bin/sh
            echo 'noah@example.com: Permission denied (publickey,password).' >&2
            exit 255
            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }

        let client = SFTPConnection(
            host: "example.com", sshExecutable: script.path,
            environment: ProcessInfo.processInfo.environment)
        // Bound outside the catch: binding the typed error with `catch let
        // error as SFTPError` and switching on it in the same clause crashed
        // the CI toolchain's SILGen (Swift 6.3.3, Xcode 26.6).
        var caught: SFTPError?
        do {
            _ = try await client.connect()
        } catch {
            caught = error
        }
        guard let caught else {
            Issue.record("connect must fail against a refusing ssh")
            return
        }
        guard case .transport(.authenticationFailed(let diagnostics)) = caught else {
            Issue.record("expected .authenticationFailed, got \(caught)")
            return
        }
        #expect(diagnostics.contains("Permission denied"))
    }
}
