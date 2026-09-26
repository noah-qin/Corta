import Foundation

/// Whole directories, built on the single-file transfers.
///
/// A directory transfer is a walk plus one ordinary transfer per regular
/// file, so every property the file transfers have — the `.corta-part`
/// partial renamed over the destination, resume validated at both ends,
/// the conflict policy, the bounded transport retry — holds file by file
/// here too, and nothing is re-implemented. What the walk adds:
///
/// - **Directories merge.** An existing directory at the destination is
///   not a conflict — the policy is asked about *files*, exactly as it
///   would be for each of them transferred alone. `.fail` therefore means
///   "stop at the first file that already exists", `.overwrite` replaces
///   files one at a time, `.resume` resumes each file that has a partial.
/// - **Only regular files and directories move.** Symbolic links (either
///   end), sockets, devices and the like are skipped and *reported* in the
///   receipt, never silently dropped or followed — following a link out of
///   the tree is how a "download this folder" walks off into `/etc`.
/// - **Names are checked.** A remote entry is one path component or it is
///   skipped; a hostile server's `../x` never becomes a local path.
/// - **Cancellation is between files.** The running file transfer is
///   cancelled through the same `Task` cancellation as always, and the walk
///   stops there; what completed stays complete, no partial is left where
///   the policy says none may be.
///
/// The tree is enumerated up front so progress can say "file 3 of 41" and
/// the total byte count from the first moment; a tree that changes under
/// the transfer is reported by the file transfers that notice, not guessed
/// around.
extension SFTPTransferEngine {
    public struct DirectoryTransferProgress: Equatable, Sendable {
        public var filesCompleted: Int
        public var filesTotal: Int
        public var completedBytes: UInt64
        /// The sum of the sizes the enumeration saw; `nil` when any file's
        /// size was not reported.
        public var totalBytes: UInt64?
        /// The file currently moving, relative to the transferred root.
        public var currentFile: String

        public init(
            filesCompleted: Int, filesTotal: Int, completedBytes: UInt64, totalBytes: UInt64?,
            currentFile: String
        ) {
            self.filesCompleted = filesCompleted
            self.filesTotal = filesTotal
            self.completedBytes = completedBytes
            self.totalBytes = totalBytes
            self.currentFile = currentFile
        }
    }

    public typealias DirectoryProgressHandler = @Sendable (DirectoryTransferProgress) -> Void

    public struct DirectoryTransferReceipt: Equatable, Sendable {
        public var filesTransferred: Int
        public var directoriesCreated: Int
        /// Bytes moved by this run, resumed partial content not counted
        /// again — the same rule as `SFTPTransferReceipt.bytesTransferred`.
        public var bytesTransferred: UInt64
        /// Entries that were not transferred and why, relative to the
        /// transferred root: symbolic links, special files, names that are
        /// not a single path component.
        public var skipped: [Skipped]

        public struct Skipped: Equatable, Sendable {
            public enum Reason: Equatable, Sendable {
                case symbolicLink
                case notARegularFile
                case unsafeName
            }
            public var relativePath: String
            public var reason: Reason
        }

        public init(
            filesTransferred: Int, directoriesCreated: Int, bytesTransferred: UInt64,
            skipped: [Skipped]
        ) {
            self.filesTransferred = filesTransferred
            self.directoriesCreated = directoriesCreated
            self.bytesTransferred = bytesTransferred
            self.skipped = skipped
        }
    }

    // MARK: - Download

    /// Downloads the tree at `remotePath` into `localDirectory` (created if
    /// absent, merged if present), one atomic file transfer at a time.
    @discardableResult
    public func downloadDirectory(
        remotePath: String,
        to localDirectory: URL,
        policy: ConflictPolicy = .fail,
        progress: DirectoryProgressHandler? = nil
    ) async throws(SFTPError) -> DirectoryTransferReceipt {
        let plan = try await enumerateRemote(root: remotePath)
        var receipt = DirectoryTransferReceipt(
            filesTransferred: 0, directoriesCreated: 0, bytesTransferred: 0,
            skipped: plan.skipped)

        for directory in plan.directories {
            let url = directory.isEmpty
                ? localDirectory : localDirectory.appendingPathComponent(directory)
            if !FileManager.default.fileExists(atPath: url.path) {
                do {
                    try FileManager.default.createDirectory(
                        at: url, withIntermediateDirectories: true)
                } catch {
                    throw SFTPError.localIOFailed(operation: "mkdir", code: Int32(errno))
                }
                receipt.directoriesCreated += 1
            }
        }

        var completedBytes: UInt64 = 0
        for (index, file) in plan.files.enumerated() {
            if Task.isCancelled { throw .cancelled }
            let completedSoFar = completedBytes
            progress?(
                DirectoryTransferProgress(
                    filesCompleted: index, filesTotal: plan.files.count,
                    completedBytes: completedSoFar, totalBytes: plan.totalBytes,
                    currentFile: file.relativePath))
            let fileReceipt = try await download(
                remotePath: Self.join(remotePath, file.relativePath),
                to: localDirectory.appendingPathComponent(file.relativePath),
                policy: policy,
                partialDisposition: .automatic,
                progress: progress.map { handler in
                    { @Sendable fileProgress in
                        handler(
                            DirectoryTransferProgress(
                                filesCompleted: index, filesTotal: plan.files.count,
                                completedBytes: completedSoFar + fileProgress.completedBytes,
                                totalBytes: plan.totalBytes, currentFile: file.relativePath))
                    }
                })
            completedBytes += fileReceipt.bytesTransferred
            receipt.filesTransferred += 1
            receipt.bytesTransferred += fileReceipt.bytesTransferred
        }
        progress?(
            DirectoryTransferProgress(
                filesCompleted: plan.files.count, filesTotal: plan.files.count,
                completedBytes: completedBytes, totalBytes: plan.totalBytes, currentFile: ""))
        return receipt
    }

    // MARK: - Upload

    /// Uploads the tree at `localDirectory` to `remotePath` (created if
    /// absent, merged if present), one atomic file transfer at a time.
    @discardableResult
    public func uploadDirectory(
        from localDirectory: URL,
        to remotePath: String,
        policy: ConflictPolicy = .fail,
        progress: DirectoryProgressHandler? = nil
    ) async throws(SFTPError) -> DirectoryTransferReceipt {
        let plan = try Self.enumerateLocal(root: localDirectory)
        var receipt = DirectoryTransferReceipt(
            filesTransferred: 0, directoriesCreated: 0, bytesTransferred: 0,
            skipped: plan.skipped)

        for directory in plan.directories {
            let path = directory.isEmpty ? remotePath : Self.join(remotePath, directory)
            if try await ensureRemoteDirectory(path) { receipt.directoriesCreated += 1 }
        }

        var completedBytes: UInt64 = 0
        for (index, file) in plan.files.enumerated() {
            if Task.isCancelled { throw .cancelled }
            let completedSoFar = completedBytes
            progress?(
                DirectoryTransferProgress(
                    filesCompleted: index, filesTotal: plan.files.count,
                    completedBytes: completedSoFar, totalBytes: plan.totalBytes,
                    currentFile: file.relativePath))
            let fileReceipt = try await upload(
                from: localDirectory.appendingPathComponent(file.relativePath),
                to: Self.join(remotePath, file.relativePath),
                policy: policy,
                partialDisposition: .automatic,
                progress: progress.map { handler in
                    { @Sendable fileProgress in
                        handler(
                            DirectoryTransferProgress(
                                filesCompleted: index, filesTotal: plan.files.count,
                                completedBytes: completedSoFar + fileProgress.completedBytes,
                                totalBytes: plan.totalBytes, currentFile: file.relativePath))
                    }
                })
            completedBytes += fileReceipt.bytesTransferred
            receipt.filesTransferred += 1
            receipt.bytesTransferred += fileReceipt.bytesTransferred
        }
        progress?(
            DirectoryTransferProgress(
                filesCompleted: plan.files.count, filesTotal: plan.files.count,
                completedBytes: completedBytes, totalBytes: plan.totalBytes, currentFile: ""))
        return receipt
    }

    // MARK: - Enumeration

    /// The tree as found before anything moves: directories in creation
    /// order (parents first, `""` for the root itself), regular files with
    /// their sizes, and what was skipped.
    struct TreePlan: Equatable, Sendable {
        var directories: [String] = [""]
        var files: [PlannedFile] = []
        var skipped: [DirectoryTransferReceipt.Skipped] = []
        var totalBytes: UInt64? = 0

        struct PlannedFile: Equatable, Sendable {
            var relativePath: String
            var size: UInt64?
        }

        mutating func addFile(_ relativePath: String, size: UInt64?) {
            files.append(PlannedFile(relativePath: relativePath, size: size))
            if let size, let total = totalBytes { totalBytes = total + size } else { totalBytes = nil }
        }
    }

    /// Breadth-first over READDIR. The file-type bits of `permissions`
    /// decide what an entry is; an entry without them is taken for a
    /// regular file, which is what the file transfer will then verify.
    func enumerateRemote(root: String) async throws(SFTPError) -> TreePlan {
        var plan = TreePlan()
        var pending = [""]
        var nextDirectory = 0
        while nextDirectory < pending.count {
            if Task.isCancelled { throw .cancelled }
            let directory = pending[nextDirectory]
            nextDirectory += 1
            let path = directory.isEmpty ? root : Self.join(root, directory)
            for entry in try await listDirectory(path: path) {
                let name = entry.filenameUTF8
                if name == "." || name == ".." { continue }
                let relative = directory.isEmpty ? name : "\(directory)/\(name)"
                guard Self.isPlainComponent(name) else {
                    plan.skipped.append(.init(relativePath: relative, reason: .unsafeName))
                    continue
                }
                switch Self.fileType(of: entry.attributes.permissions) {
                case .directory:
                    plan.directories.append(relative)
                    pending.append(relative)
                case .regular:
                    plan.addFile(relative, size: entry.attributes.size)
                case .symbolicLink:
                    plan.skipped.append(.init(relativePath: relative, reason: .symbolicLink))
                case .other:
                    plan.skipped.append(.init(relativePath: relative, reason: .notARegularFile))
                }
            }
        }
        return plan
    }

    /// Depth-first over the local tree without following symbolic links;
    /// the plan lists directories parents-first so remote `MKDIR`s land in
    /// order.
    static func enumerateLocal(root: URL) throws(SFTPError) -> TreePlan {
        var plan = TreePlan()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: Array(keys),
                options: [.producesRelativePathURLs])
        else { throw .localIOFailed(operation: "opendir", code: ENOENT) }
        let rootPath = root.standardizedFileURL.path
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: keys)
            let absolute = url.standardizedFileURL.path
            let relative =
                absolute.hasPrefix(rootPath + "/")
                ? String(absolute.dropFirst(rootPath.count + 1)) : url.relativePath
            if values?.isSymbolicLink == true {
                plan.skipped.append(.init(relativePath: relative, reason: .symbolicLink))
                enumerator.skipDescendants()
            } else if values?.isDirectory == true {
                plan.directories.append(relative)
            } else if values?.isRegularFile == true {
                plan.addFile(relative, size: values?.fileSize.map(UInt64.init))
            } else {
                plan.skipped.append(.init(relativePath: relative, reason: .notARegularFile))
            }
        }
        // The enumerator yields in traversal order, so parents precede
        // their children already; sorting by depth keeps that true for
        // any enumerator that does not promise it.
        let root = plan.directories.removeFirst()
        plan.directories.sort { $0.split(separator: "/").count < $1.split(separator: "/").count }
        plan.directories.insert(root, at: 0)
        return plan
    }

    /// `MKDIR`, tolerating a directory that is already there: returns
    /// whether it was created. Anything else at the path is a failure the
    /// caller hears about.
    private func ensureRemoteDirectory(_ path: String) async throws(SFTPError) -> Bool {
        if let existing = try? await lstat(path: path) {
            if Self.fileType(of: existing.permissions) == .directory { return false }
            throw .destinationConflict(path: path)
        }
        try await makeDirectory(path: path)
        return true
    }

    enum FileType { case regular, directory, symbolicLink, other }

    static func fileType(of permissions: UInt32?) -> FileType {
        guard let permissions else { return .regular }
        switch permissions & 0o170000 {
        case 0o040000: return .directory
        case 0o100000: return .regular
        case 0o120000: return .symbolicLink
        default: return .other
        }
    }

    static func isPlainComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    static func join(_ directory: String, _ relative: String) -> String {
        directory == "/" ? "/\(relative)" : "\(directory)/\(relative)"
    }
}
