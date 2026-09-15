import Foundation
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

    @Test("a missing executable fails the spawn, not the connection")
    func missingExecutableFails() async {
        let client = SFTPConnection(host: "x", sshExecutable: "/nonexistent/ssh")
        await #expect(throws: SFTPError.self) { try await client.connect() }
    }
}
