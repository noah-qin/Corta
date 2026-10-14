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

import CryptoKit
import Darwin
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
        var remoteDigest: String? = nil
        /// The local content last decided on — downloaded, uploaded, or
        /// dismissed as "not this edit" — the baseline a reopened copy's
        /// change is measured against. Persisted, so a dismissed edit is not
        /// offered again after a relaunch, and an undecided one is.
        var approvedDigest: String? = nil
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
    /// The manifest on disk is from a newer Corta: read as empty here, and
    /// never written, or this build's next save would drop every copy it
    /// does not know.
    private(set) var preservesNewerManifest = false

    /// Where approved-upload snapshots and pre-upload probes are written.
    var approvalsURL: URL { rootURL.appendingPathComponent("Approvals", isDirectory: true) }

    static var defaultRootURL: URL {
        AppPaths.applicationSupportDirectory.appendingPathComponent("RemoteEdit", isDirectory: true)
    }

    init(rootURL: URL) {
        self.rootURL = rootURL
        // Approval snapshots and content probes belong to one run: the
        // decisions they back are in memory and do not survive a relaunch,
        // so whatever a quit left behind is only a stale copy of a file.
        try? FileManager.default.removeItem(at: approvalsURL)
        load()
        pruneStaleCopies()
        try? secureCopy(at: manifestURL)
        for copy in copies.values { try? secureCopy(at: localURL(for: copy)) }
    }

    // MARK: - Retention

    /// How long a copy nobody opens or edits is kept.
    static let retention: TimeInterval = 30 * 24 * 60 * 60

    /// Removes copies left alone for `retention`: a remote `.env` opened once
    /// was otherwise kept for good, and backed up with Application Support.
    /// Only a copy whose content is what was last decided on — downloaded,
    /// uploaded or dismissed — so an edit never uploaded waits for its
    /// decision however old it is. Copies set aside beside it stay too.
    func pruneStaleCopies(now: Date = Date()) {
        guard !preservesNewerManifest else { return }
        var pruned = false
        for (id, copy) in copies {
            let url = localURL(for: copy)
            guard
                let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[
                    .modificationDate] as? Date,
                now.timeIntervalSince(max(copy.lastOpenedAt, modified)) > Self.retention,
                let baseline = copy.approvedDigest ?? copy.remoteDigest,
                Self.sha256Hex(ofFile: url) == baseline
            else { continue }
            guard (try? FileManager.default.removeItem(at: url)) != nil else { continue }
            let folder = url.deletingLastPathComponent()
            if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: folder)
            }
            copies[id] = nil
            pruned = true
        }
        if pruned { save() }
    }

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
    nonisolated static func sha256Hex(ofFile url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hash = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                hash.update(data: chunk)
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        } catch { return nil }
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

    /// Clears any extended ACL. A volume without ACL support (ENOTSUP) has
    /// none to inherit, so that counts as cleared rather than as a failure.
    private static func removeACL(at url: URL) -> Bool {
        guard let acl = acl_init(0) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        if acl_set_file(url.path, ACL_TYPE_EXTENDED, acl) == 0 { return true }
        return errno == ENOTSUP || errno == EOPNOTSUPP
    }

    // MARK: - Persistence

    private struct Persisted: Codable {
        static let currentVersion = 1
        var version: Int
        var copies: [RemoteCopy]
    }

    private func load() {
        guard let data = try? Data(contentsOf: manifestURL) else { return }
        if let version = try? JSONDecoder().decode(VersionProbe.self, from: data).version,
            version > Persisted.currentVersion
        {
            preservesNewerManifest = true
            return
        }
        guard let persisted = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        copies = Dictionary(
            persisted.copies.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var manifestURL: URL {
        rootURL.appendingPathComponent("manifest.json")
    }

    /// Only the version, so a newer shape is recognised as newer.
    private struct VersionProbe: Decodable {
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
        guard !preservesNewerManifest else { return }
        let persisted = Persisted(version: Persisted.currentVersion, copies: Array(copies.values))
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        try? secureCopy(at: manifestURL)
        try? data.write(to: manifestURL, options: .atomic)
        try? secureCopy(at: manifestURL)
    }
}
