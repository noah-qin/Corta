import CryptoKit
import Foundation

/// Remote editing — the managed local copies of remote files, and the
/// manifest that remembers what each copy is a copy *of*.
///
/// A copy lives under `RemoteEdit/<host>/<hash>/<name>`, where the hash is
/// of `host + remotePath`: the same remote file always maps to the same
/// local copy (a second open reuses it rather than downloading again), and
/// two remote files that share a basename never collide.
///
/// The manifest records the remote size and mtime at download, which is
/// what makes "did the remote change since?" an answerable question at
/// upload time (`RemoteEditCoordinator` re-`lstat`s and compares) rather
/// than a guess. It is machine-produced state, not a setting, so it lives
/// in Application Support as versioned JSON with `SessionRestore`/
/// `DirectoryHistoryStore`'s discipline: a manifest this build cannot
/// read — wrong shape, or a version from the future — degrades to empty,
/// never to a guess at a format that changed underneath the fields.
@MainActor
final class RemoteEditStore {
    /// One managed copy, as the manifest records it.
    nonisolated struct RemoteCopy: Codable, Equatable, Identifiable {
        var host: String
        var remotePath: String
        /// The copy's path relative to the store root — never absolute, so
        /// the whole store can be moved without invalidating it.
        var localFile: String
        /// What the remote `lstat` said at the last download or upload —
        /// the baseline "remote changed?" compares against.
        var remoteSize: UInt64?
        var remoteMTime: UInt32?
        var lastOpenedAt: Date
        var openCount: Int

        var id: String { Self.key(host: host, remotePath: remotePath) }

        static func key(host: String, remotePath: String) -> String {
            host + "\u{0}" + remotePath
        }
    }

    static let shared = RemoteEditStore(rootURL: RemoteEditStore.defaultRootURL)

    /// The store's root — injected so tests point at a temporary directory
    /// instead of the user's real Application Support.
    let rootURL: URL

    /// Copies by `RemoteCopy.id`.
    private(set) var copies: [String: RemoteCopy] = [:]

    static var defaultRootURL: URL {
        AppPaths.applicationSupportDirectory.appendingPathComponent("RemoteEdit", isDirectory: true)
    }

    init(rootURL: URL) {
        self.rootURL = rootURL
        load()
    }

    // MARK: - Naming (pure)

    /// The deterministic relative path for a host+remotePath pair. The
    /// digest directory is what makes the mapping injective in practice;
    /// the basename is for the human who opens the folder in Finder.
    nonisolated static func localRelativePath(host: String, remotePath: String) -> String {
        let digest = sha256Hex(Data((host + "\u{0}" + remotePath).utf8)).prefix(16)
        var name = (remotePath as NSString).lastPathComponent
        // A trailing "/.." or "/" makes the basename a path instruction or
        // empty; the copy must stay inside its digest directory.
        if name.isEmpty || name == "." || name == ".." { name = "file" }
        return "\(hostDirectoryName(host))/\(digest)/\(name)"
    }

    /// The per-host directory: hostnames are near-safe already, and this
    /// replaces everything that is not, so a hostile `~/.ssh/config` alias
    /// cannot escape the store root with a `../`.
    nonisolated static func hostDirectoryName(_ host: String) -> String {
        let safe = host.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "." || $0 == "_"
                ? Character($0) : "_"
        }
        let name = String(safe)
        // A lone "." or ".." is still a path instruction, scalars or not.
        guard name != ".", name != ".." else { return "_" }
        return name.isEmpty ? "_" : name
    }

    nonisolated static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The digest of a file's contents, or `nil` if it cannot be read.
    /// This is the local-change signal: compared against the digest
    /// approved at download/upload time, a difference is an edit.
    nonisolated static func sha256Hex(ofFile url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return sha256Hex(data)
    }

    // MARK: - Queries and updates

    func copy(host: String, remotePath: String) -> RemoteCopy? {
        copies[RemoteCopy.key(host: host, remotePath: remotePath)]
    }

    func localURL(for copy: RemoteCopy) -> URL {
        rootURL.appendingPathComponent(copy.localFile)
    }

    /// Records a fresh download — creating the entry or re-stamping an
    /// existing one (the open history survives a re-download). Returns the
    /// up-to-date copy.
    @discardableResult
    func recordDownload(
        host: String, remotePath: String, remoteSize: UInt64?, remoteMTime: UInt32?
    ) -> RemoteCopy {
        let id = RemoteCopy.key(host: host, remotePath: remotePath)
        var copy = copies[id]
            ?? RemoteCopy(
                host: host, remotePath: remotePath,
                localFile: Self.localRelativePath(host: host, remotePath: remotePath),
                remoteSize: nil, remoteMTime: nil,
                lastOpenedAt: .distantPast, openCount: 0)
        copy.remoteSize = remoteSize
        copy.remoteMTime = remoteMTime
        copies[id] = copy
        save()
        return copy
    }

    /// Re-stamps the remote baseline after a successful upload: what the
    /// server reports now is what the next "remote changed?" compares
    /// against.
    func updateRemoteStamp(_ copy: RemoteCopy, size: UInt64?, mtime: UInt32?) {
        guard var current = copies[copy.id] else { return }
        current.remoteSize = size
        current.remoteMTime = mtime
        copies[copy.id] = current
        save()
    }

    func recordOpen(_ copy: RemoteCopy, at date: Date = Date()) {
        guard var current = copies[copy.id] else { return }
        current.openCount += 1
        current.lastOpenedAt = date
        copies[copy.id] = current
        save()
    }

    // MARK: - Persistence

    private struct Persisted: Codable {
        static let currentVersion = 1
        var version: Int
        var copies: [RemoteCopy]
    }

    private func load() {
        guard let data = try? Data(contentsOf: manifestURL),
            let persisted = try? JSONDecoder().decode(Persisted.self, from: data),
            persisted.version <= Persisted.currentVersion
        else { return }
        copies = Dictionary(
            persisted.copies.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var manifestURL: URL {
        rootURL.appendingPathComponent("manifest.json")
    }

    private func save() {
        let persisted = Persisted(version: Persisted.currentVersion, copies: Array(copies.values))
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try? data.write(to: manifestURL, options: .atomic)
    }
}
