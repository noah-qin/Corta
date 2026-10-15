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

import Darwin
import Foundation

extension SFTPTransferEngine {
    // MARK: - Directory operations

    /// The whole directory: READDIR batches until the server answers EOF.
    public func listDirectory(path: String) async throws(SFTPError) -> [SFTPEntry] {
        let session = self.session
        let handle = try await session.openDirectory(path: path)
        var entries: [SFTPEntry] = []
        var retainedBytes = 0
        do throws(SFTPError) {
            while true {
                let batch = try await session.readDirectory(handle: handle)
                if batch.isEmpty { break }
                guard entries.count <= configuration.maximumDirectoryEntries,
                    batch.count <= configuration.maximumDirectoryEntries - entries.count
                else { throw SFTPError.protocolViolation("directory entry limit exceeded") }
                // Charge retained strings and extension objects before append.
                // The count cap also bounds empty entries and array overhead.
                for entry in batch {
                    func charge(_ count: Int) throws(SFTPError) {
                        guard retainedBytes <= configuration.maximumDirectoryBytes,
                            count <= configuration.maximumDirectoryBytes - retainedBytes
                        else { throw .protocolViolation("directory byte limit exceeded") }
                        retainedBytes += count
                    }
                    try charge(128)
                    try charge(entry.filename.count)
                    try charge(entry.longname.count)
                    for item in entry.attributes.extended {
                        try charge(32)
                        try charge(item.name.count)
                        try charge(item.data.count)
                    }
                }
                entries.append(contentsOf: batch)
            }
        } catch {
            // A listing that failed mid-way still owes the server a CLOSE.
            await cleanUpRemote { try? await session.close(handle) }
            throw error
        }
        try await session.close(handle)
        return entries
    }

    public func makeDirectory(
        path: String, attributes: SFTPAttributes = .init()
    ) async throws(SFTPError) {
        try await session.makeDirectory(path: path, attributes: attributes)
    }

    public func remove(path: String) async throws(SFTPError) {
        try await session.remove(path: path)
    }

    public func removeDirectory(path: String) async throws(SFTPError) {
        try await session.removeDirectory(path: path)
    }

    public func rename(from oldPath: String, to newPath: String) async throws(SFTPError) {
        try await session.rename(from: oldPath, to: newPath)
    }

    public func lstat(path: String) async throws(SFTPError) -> SFTPAttributes {
        try await session.lstat(path: path)
    }

    /// Filesystem capacity, or `nil` when the server does not support
    /// `statvfs@openssh.com` — reported unavailable, never guessed.
    public func volumeInfo(path: String = "/") async throws(SFTPError) -> SFTPVolumeInfo? {
        try await session.volumeInfo(path: path)
    }
}
