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
import Foundation

/// Keeps each export on the destination volume for atomic replacement. The
/// private journal lets the next launch find a partial export without
/// scanning any user directory or recording the chosen output filename.
nonisolated enum ExportStaging {
    static var journalDirectory: URL {
        AppPaths.applicationSupportDirectory.appendingPathComponent("ExportStaging", isDirectory: true)
    }

    struct Record: Codable {
        let pid: pid_t
        let parentPath: String
        let device: dev_t
        let inode: ino_t
        let volumeUUID: String?
    }

    private static let payloadName = "payload"

    static func replace(
        _ destination: URL, journal: URL = journalDirectory, prepare: (URL) throws -> Void
    ) throws {
        let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath()
        let parentFD = openDirectory(parent.path)
        guard parentFD >= 0 else { throw lastError }
        defer { close(parentFD) }
        var info = stat()
        guard fstat(parentFD, &info) == 0 else { throw lastError }

        let id = UUID()
        let entry = journal.appendingPathComponent(id.uuidString).appendingPathExtension("json")
        let record = Record(
            pid: getpid(), parentPath: parent.path, device: info.st_dev, inode: info.st_ino,
            volumeUUID: volumeUUID(parent))
        try PrivateFile.write(JSONEncoder().encode(record), to: entry)

        let name = stagingName(id)
        guard mkdirat(parentFD, name, 0o700) == 0 else {
            let error = lastError
            try? PrivateFile.removeIfPresent(entry)
            throw error
        }
        defer {
            let removed = removeStaging(name, in: parentFD)
            _ = fsync(parentFD)
            if removed { try? PrivateFile.removeIfPresent(entry) }
        }
        let staging = parent.appendingPathComponent(name, isDirectory: true)
        let stagingFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stagingFD >= 0 else { throw lastError }
        defer { close(stagingFD) }
        let aclError = clearExtendedACL(path: staging.path)
        guard aclError == 0 else { throw POSIXError(POSIXErrorCode(rawValue: aclError) ?? .EIO) }
        guard fchmod(stagingFD, 0o700) == 0 else { throw lastError }

        try prepare(staging.appendingPathComponent(payloadName))
        guard renameat(stagingFD, payloadName, parentFD, destination.lastPathComponent) == 0 else {
            throw lastError
        }
    }

    static func removeAbandoned(in journal: URL = journalDirectory) {
        PrivateFile.removeAbandonedTemporaries(in: journal, olderThan: AppPaths.abandonedStateFileAge)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: journal.path) else { return }
        for name in names where name.hasSuffix(".json") {
            guard let id = UUID(uuidString: String(name.dropLast(5))), name == id.uuidString + ".json" else {
                continue
            }
            let entry = journal.appendingPathComponent(name)
            guard let data = try? PrivateFile.read(entry),
                let record = try? JSONDecoder().decode(Record.self, from: data),
                record.pid > 0, kill(record.pid, 0) != 0, errno == ESRCH,
                record.parentPath.hasPrefix("/")
            else { continue }
            if removeAbandoned(id, record: record) { try? PrivateFile.removeIfPresent(entry) }
        }
    }

    private static func removeAbandoned(_ id: UUID, record: Record) -> Bool {
        let parentFD = openDirectory(record.parentPath)
        guard parentFD >= 0 else { return false }
        defer { close(parentFD) }
        var info = stat()
        guard fstat(parentFD, &info) == 0, info.st_ino == record.inode else { return false }
        if let originalVolume = record.volumeUUID {
            guard volumeUUID(URL(fileURLWithPath: record.parentPath)) == originalVolume else { return false }
        } else {
            guard info.st_dev == record.device else { return false }
        }
        // Keep the record when the original directory is unavailable.
        guard removeStaging(stagingName(id), in: parentFD) else { return false }
        _ = fsync(parentFD)
        return true
    }

    private static func volumeUUID(_ url: URL) -> String? {
        try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    }

    private static func removeStaging(_ name: String, in parentFD: Int32) -> Bool {
        let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return errno == ENOENT }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { return false }

        // unlinkat doesn't follow links or recursively remove unexpected contents.
        guard unlinkat(fd, payloadName, 0) == 0 || errno == ENOENT else { return false }
        var current = stat()
        guard fstatat(parentFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0 else { return errno == ENOENT }
        guard current.st_ino == info.st_ino, current.st_dev == info.st_dev else { return false }
        return unlinkat(parentFD, name, AT_REMOVEDIR) == 0 || errno == ENOENT
    }

    private static func stagingName(_ id: UUID) -> String { ".corta-export-" + id.uuidString }

    private static func openDirectory(_ path: String) -> Int32 {
        open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }

    private static var lastError: POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
