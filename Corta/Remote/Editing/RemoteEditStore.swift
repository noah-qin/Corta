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

import CortaPOSIX
import CryptoKit
import Darwin
import Foundation
import Synchronization

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
        var remoteDigest: String?
        /// The local content last decided on — downloaded, uploaded, or
        /// dismissed as "not this edit" — the baseline a reopened copy's
        /// change is measured against. Persisted, so a dismissed edit is not
        /// offered again after a relaunch, and an undecided one is.
        var approvedDigest: String?
        var lastOpenedAt: Date
        var openCount: Int

        var id: String { Self.key(host: host, remotePath: remotePath) }

        static func key(host: String, remotePath: String) -> String {
            host + "\u{0}" + remotePath
        }
    }

    static let shared: RemoteEditStore = {
        let store = RemoteEditStore(rootURL: RemoteEditStore.defaultRootURL)
        activeShared = store
        return store
    }()
    private static weak var activeShared: RemoteEditStore?

    /// The manifest writes already queued, left in `group` once written.
    static func flushSharedAtQuit(into group: DispatchGroup) {
        guard let queue = activeShared?.manifestWrites else { return }
        group.enter()
        queue.async { group.leave() }
    }

    /// The store's root — injected so tests point at a temporary directory
    /// instead of the user's real Application Support.
    let rootURL: URL

    /// Copies by `RemoteCopy.id`.
    private(set) var copies: [String: RemoteCopy] = [:]
    /// The manifest on disk is from a newer Corta: read as empty here, and
    /// never written, or this build's next save would drop every copy it
    /// does not know.
    private(set) var preservesNewerManifest = false
    private(set) var manifestReadError: (any Error)?
    private(set) var manifestWriteError: (any Error)?
    private let manifestWrites = DispatchQueue(label: "Corta.RemoteEditManifest", qos: .utility)
    var onManifestWriteFailure: ((any Error) -> Void)?

    /// Where approved-upload snapshots and pre-upload probes are written.
    let approvalsURL: URL

    static var defaultRootURL: URL {
        AppPaths.applicationSupportDirectory.appendingPathComponent("RemoteEdit", isDirectory: true)
    }

    private(set) var maintenanceTask: Task<Void, Never>?

    init(rootURL: URL) {
        self.rootURL = rootURL
        approvalsURL = rootURL.appendingPathComponent(".approvals-\(getpid())-\(UUID().uuidString)", isDirectory: true)
        load()
        let candidates = copies.values.shuffled()
        maintenanceTask = Task { [weak self] in
            await Self.removeAbandonedApprovals(in: rootURL)
            await self?.pruneStaleCopies(candidates: candidates)
        }
        // Reused copies are tightened on materialize, rather than walking
        // every cached directory on the main actor during initialization.
    }

    // MARK: - Retention

    /// How long a copy nobody opens or edits is kept.
    nonisolated static let retention: TimeInterval = 30 * 24 * 60 * 60

    /// Maintenance has a per-run count and byte budget. Opening a file waits
    /// asynchronously for this pass, so it cannot race deletion of its copy.
    func finishMaintenance() async {
        await maintenanceTask?.value
    }

    @concurrent
    private static func removeAbandonedApprovals(in root: URL) async {
        removeAbandonedApprovalsNow(in: root)
    }

    /// Retire only unchanged, approved copies past retention. Bound maintenance
    /// to 32 candidates and 256 MiB; undecided edits and excess work stay.
    func pruneStaleCopies(now: Date = Date(), candidates: [RemoteCopy]? = nil) async {
        guard !preservesNewerManifest else { return }
        var remainingBytes = 256 * 1024 * 1024
        var checked = 0
        var pruned = false
        for copy in candidates ?? Array(copies.values) {
            guard !Task.isCancelled, checked < 32, remainingBytes > 0 else { break }
            checked += 1
            let url = localURL(for: copy)
            guard Self.contains(url, in: rootURL) else { continue }
            let result = await Self.staleCopy(
                copy, at: url, now: now, byteLimit: remainingBytes)
            remainingBytes -= result.bytesRead
            guard let modified = result.modified, copies[copy.id] == copy,
                (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate]
                    as? Date
                    == modified
            else { continue }
            guard (try? FileManager.default.removeItem(at: url)) != nil else { continue }
            copies[copy.id] = nil
            pruned = true
            let parent = url.deletingLastPathComponent()
            if parent.standardizedFileURL != rootURL.standardizedFileURL, rmdir(parent.path) == 0 {
                let host = parent.deletingLastPathComponent()
                if host.standardizedFileURL != rootURL.standardizedFileURL { rmdir(host.path) }
            }
        }
        if pruned { save() }
    }

    @concurrent
    private static func staleCopy(
        _ copy: RemoteCopy, at url: URL, now: Date, byteLimit: Int
    ) async -> (modified: Date?, bytesRead: Int) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let modified = attributes[.modificationDate] as? Date,
            now.timeIntervalSince(max(copy.lastOpenedAt, modified)) > Self.retention,
            let baseline = copy.approvedDigest ?? copy.remoteDigest,
            let size = attributes[.size] as? NSNumber, size.uint64Value <= UInt64(byteLimit)
        else { return (nil, 0) }
        let result = Self.hashFile(at: url, byteLimit: byteLimit)
        return (result.digest == baseline ? modified : nil, result.bytesRead)
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
        host: String, remotePath: String, remoteSize: UInt64?, remoteMTime: UInt32?, remoteDigest: String? = nil
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
        copy.remoteDigest = remoteDigest
        copy.approvedDigest = remoteDigest
        copies[id] = copy
        save()
        return copy
    }

    /// Re-stamps the remote baseline after a successful upload: what the
    /// server reports now is what the next "remote changed?" compares
    /// against.
    func updateRemoteStamp(_ copy: RemoteCopy, size: UInt64?, mtime: UInt32?, digest: String? = nil) {
        guard var current = copies[copy.id] else { return }
        current.remoteSize = size
        current.remoteMTime = mtime
        current.remoteDigest = digest
        current.approvedDigest = digest
        copies[copy.id] = current
        save()
    }

    /// The local content the user decided on without uploading it.
    func recordApproved(_ copy: RemoteCopy, digest: String?) {
        guard var current = copies[copy.id] else { return }
        current.approvedDigest = digest
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

    /// Private directories and files, including copies downloaded by older
    /// builds. Mode checks do not make promises about administrator access.
    func secureCopy(at url: URL) throws {
        try Self.secureCopy(at: url, rootURL: rootURL)
    }

    nonisolated static func secureCopy(at url: URL, rootURL: URL) throws {
        guard contains(url, in: rootURL) else { throw POSIXError(.EACCES) }
        var directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        while directory.path.hasPrefix(rootURL.path), directory.path != "/" {
            guard Self.removeACL(at: directory), chmod(directory.path, 0o700) == 0 else {
                throw CocoaError(.fileWriteNoPermission)
            }
            if directory.standardizedFileURL == rootURL.standardizedFileURL { break }
            directory.deleteLastPathComponent()
        }
        if FileManager.default.fileExists(atPath: url.path),
            !Self.removeACL(at: url) || chmod(url.path, 0o600) != 0 {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    nonisolated private static func removeACL(at url: URL) -> Bool {
        clearExtendedACL(path: url.path) == 0
    }

    // MARK: - Persistence

    private nonisolated struct Persisted: Codable, Sendable {
        static let currentVersion = 1
        // periphery:ignore - the manifest's format version, written for a later reader
        var version: Int
        var copies: [RemoteCopy]
    }

    private func load() {
        let outcome = Self.takePrefetched(for: manifestURL) ?? Self.read(manifestURL)
        switch outcome {
        case .nothing:
            return
        case .unreadable(let error):
            manifestReadError = error
        case .newer:
            preservesNewerManifest = true
        case .copies(let stored):
            // `standardized`, not `standardizedFileURL`: the root exists and a
            // copy may not, and only an existing path loses its `/private`.
            let prefix = rootURL.standardized.path + "/"
            copies = Dictionary(
                stored.filter { localURL(for: $0).standardized.path.hasPrefix(prefix) }
                    .map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first })
        }
    }

    private var manifestURL: URL {
        rootURL.appendingPathComponent("manifest.json")
    }

    /// Only the version, so a newer shape is recognised as newer.
    private nonisolated struct VersionProbe: Decodable {
        var version: Int
    }

    /// Moves a copy the manifest does not name out of the way, beside it, as
    /// `<name> (local copy <date>)`; returns where it went.
    func setAsideOrphan(at url: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let stamp = formatter.string(from: Date())
        var candidate = url.deletingLastPathComponent().appendingPathComponent(
            "\(name) (local copy \(stamp))" + (ext.isEmpty ? "" : ".\(ext)"))
        var attempt = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent(
                "\(name) (local copy \(stamp) \(attempt))" + (ext.isEmpty ? "" : ".\(ext)"))
            attempt += 1
        }
        try FileManager.default.moveItem(at: url, to: candidate)
        return candidate
    }

    private func save() {
        guard !preservesNewerManifest, manifestReadError == nil else { return }
        let persisted = Persisted(version: Persisted.currentVersion, copies: Array(copies.values))
        // The manifest names hosts and paths: owner-only from its first
        // byte, not `chmod`ed after an `.atomic` write at the umask.
        let url = manifestURL
        manifestWrites.async { [weak self] in
            let result = Result { try PrivateFile.write(JSONEncoder().encode(persisted), to: url) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try result.get()
                    self.manifestWriteError = nil
                } catch {
                    let firstFailure = self.manifestWriteError == nil
                    self.manifestWriteError = error
                    if firstFailure { self.onManifestWriteFailure?(error) }
                }
            }
        }
    }

    func finishManifestWrites() async {
        await withCheckedContinuation { continuation in
            manifestWrites.async { continuation.resume() }
        }
    }
}

extension RemoteEditStore {
    /// Dead processes' approval snapshots and abandoned downloads. Also run
    /// at launch (`AppPaths.removeAbandonedStateFiles`): the store loads only
    /// when Remote Edit is first used, and until then they stayed on disk.
    nonisolated static func removeAbandonedApprovalsNow(in root: URL) {
        let manager = FileManager.default
        guard let children = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for child in children {
            let name = child.lastPathComponent
            if name.hasPrefix(".approvals-"),
                let separator = name.dropFirst(".approvals-".count).firstIndex(of: "-"),
                let pid = Int32(name[name.index(name.startIndex, offsetBy: ".approvals-".count)..<separator]),
                UUID(uuidString: String(name[name.index(after: separator)...])) != nil,
                pid > 0, kill(pid, 0) == -1, errno == ESRCH
            {
                try? manager.removeItem(at: child)
            } else if name.hasPrefix("Abandoned-"),
                UUID(uuidString: String(name.dropFirst("Abandoned-".count))) != nil,
                let files = try? manager.contentsOfDirectory(atPath: child.path),
                files.allSatisfy({ UUID(uuidString: $0.replacingOccurrences(of: ".corta-part", with: "")) != nil })
            {
                try? manager.removeItem(at: child)
            }
        }
    }
}

extension RemoteEditStore {
    // MARK: - Naming (pure)

    /// The deterministic relative path for a host+remotePath pair. The
    /// digest directory is what makes the mapping injective in practice;
    /// the basename is for the human who opens the folder in Finder.
    nonisolated static func localRelativePath(host: String, remotePath: String) -> String {
        let digest = sha256Hex(Data((host + "\u{0}" + remotePath).utf8)).prefix(16)
        // Named as the browser names a download: the editor and Finder show
        // this name, and the server chose it.
        var name = SFTPBrowserModel.localFileName((remotePath as NSString).lastPathComponent)
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
    nonisolated static func sha256Hex(ofFile url: URL, byteLimit: Int = .max) -> String? {
        hashFile(at: url, byteLimit: byteLimit).digest
    }

    nonisolated private static func hashFile(at url: URL, byteLimit: Int)
        -> (digest: String?, bytesRead: Int)
    {
        guard byteLimit >= 0, let handle = try? FileHandle(forReadingFrom: url) else { return (nil, 0) }
        defer { try? handle.close() }
        var hash = SHA256()
        var remaining = byteLimit
        do {
            // One extra byte distinguishes exact EOF from a file that grew
            // past its stat size. Charge actual reads, not that stale size.
            while let chunk = try handle.read(upToCount: min(64 * 1024, max(1, remaining))), !chunk.isEmpty {
                guard chunk.count <= remaining else { return (nil, byteLimit) }
                remaining -= chunk.count
                guard !Task.isCancelled else { return (nil, byteLimit - remaining) }
                hash.update(data: chunk)
            }
            return (hash.finalize().map { String(format: "%02x", $0) }.joined(), byteLimit - remaining)
        } catch { return (nil, byteLimit - remaining) }
    }
}

// MARK: - Reading the manifest ahead

extension RemoteEditStore {
    /// What reading the manifest found; read anywhere, applied on the main actor.
    nonisolated enum LoadOutcome: Sendable {
        case nothing
        case unreadable(any Error)
        case newer
        case copies([RemoteCopy])
    }

    nonisolated static func read(_ manifestURL: URL) -> LoadOutcome {
        let data: Data
        do {
            guard let loaded = try PrivateFile.readBounded(manifestURL) else { return .nothing }
            data = loaded
        } catch {
            return .unreadable(error)
        }
        if let version = try? JSONDecoder().decode(VersionProbe.self, from: data).version,
            version > Persisted.currentVersion
        {
            return .newer
        }
        guard let persisted = try? JSONDecoder().decode(Persisted.self, from: data) else { return .nothing }
        return .copies(persisted.copies)
    }

    /// A manifest read ahead, with the file's identity when it was read.
    private nonisolated struct Prefetched: Sendable {
        let url: URL
        let stamp: FileStamp?
        let outcome: LoadOutcome
    }

    private nonisolated struct FileStamp: Equatable, Sendable {
        // periphery:ignore - read by the synthesised ==
        let size: off_t
        // periphery:ignore - read by the synthesised ==
        let seconds: Int
        // periphery:ignore - read by the synthesised ==
        let nanoseconds: Int

        init?(_ url: URL) {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return nil }
            size = info.st_size
            seconds = info.st_mtimespec.tv_sec
            nanoseconds = info.st_mtimespec.tv_nsec
        }
    }

    private nonisolated static let prefetched = Mutex<Prefetched?>(nil)

    /// Reads and decodes the shared store's manifest off the main thread at
    /// launch: the store itself is made on the main actor the first time
    /// Remote Edit is used, and read the file there. Used only if the file
    /// has not changed since (`takePrefetched`).
    nonisolated static func prefetchShared(rootURL: URL) {
        let url = rootURL.appendingPathComponent("manifest.json")
        let stamp = FileStamp(url)
        let outcome = read(url)
        prefetched.withLock { $0 = Prefetched(url: url, stamp: stamp, outcome: outcome) }
    }

    /// The read-ahead answer for `url`, once, when the file is as it was
    /// then; nil sends the caller to read it itself.
    private nonisolated static func takePrefetched(for url: URL) -> LoadOutcome? {
        guard let taken = prefetched.withLock({ value -> Prefetched? in
            guard value?.url == url else { return nil }
            defer { value = nil }
            return value
        }), taken.stamp == FileStamp(url) else { return nil }
        return taken.outcome
    }
}

// MARK: - Containment

extension RemoteEditStore {
    nonisolated static func contains(_ url: URL, in root: URL) -> Bool {
        guard let rootPath = canonicalPath(root), let path = canonicalPath(url) else { return false }
        return path.hasPrefix(rootPath + "/")
    }

    /// The path with every symbolic link resolved, for a file that may not
    /// exist yet: `realpath(3)` of its deepest existing ancestor, the rest
    /// appended. Foundation will not do for the comparison: both
    /// `standardizedFileURL` and `resolvingSymlinksInPath` drop a leading
    /// `/private` only from a path that exists, so under a root in `/tmp` or
    /// `/var/folders` a file about to be created and the root it goes in were
    /// spelled differently, and every new snapshot was refused as outside the
    /// store. `standardized` resolves `.` and `..` without that. Nil for an
    /// entry that exists but does not resolve, such as a dangling link:
    /// where it would write is unknown.
    nonisolated static func canonicalPath(_ url: URL) -> String? {
        var existing = url.standardized.path
        var missing: [String] = []
        while true {
            if let resolved = realpath(existing, nil) {
                defer { free(resolved) }
                return missing.reversed().reduce(String(cString: resolved)) { $0 == "/" ? "/" + $1 : $0 + "/" + $1 }
            }
            var info = stat()
            guard errno == ENOENT, lstat(existing, &info) != 0, existing != "/" else { return nil }
            missing.append((existing as NSString).lastPathComponent)
            existing = (existing as NSString).deletingLastPathComponent
        }
    }
}
