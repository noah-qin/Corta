import Foundation
import Synchronization
import Testing

@testable import CortaTerminal

/// B14 against the real thing: `/usr/libexec/sftp-server` is on every Mac,
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
            host: "local", sshExecutable: server, arguments: ["-d", root.path])
        _ = try await client.connect()
        return client
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

        let down = root.appendingPathComponent("payload-down.bin")
        let receipt = try await client.download(
            remotePath: app.appendingPathComponent("payload.bin").path, to: down,
            policy: .fail, partialDisposition: .remove, progress: nil)
        #expect(receipt.bytesTransferred == UInt64(payload.count))
        #expect(try Data(contentsOf: down) == payload)
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

    @Test("a missing executable fails the spawn, not the connection")
    func missingExecutableFails() async {
        let client = SFTPConnection(host: "x", sshExecutable: "/nonexistent/ssh")
        await #expect(throws: SFTPError.self) { try await client.connect() }
    }
}
