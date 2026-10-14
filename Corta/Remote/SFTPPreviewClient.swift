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

#if DEBUG
import Foundation
import CortaSFTP

/// Read-only fixtures for the real browser. Never opens a channel or local file.
nonisolated final class SFTPPreviewClient: SFTPClient {
    var capabilities: SFTPServerCapabilities? {
        .init(version: 3, extensions: [:], supportsStatVFS: true, supportsPosixRename: false)
    }
    func connect() async throws(SFTPError) -> SFTPServerCapabilities { capabilities! }
    func realPath(path: String) async throws(SFTPError) -> String { "/home/demo" }
    func listDirectory(path: String) async throws(SFTPError) -> [SFTPEntry] {
        switch path {
        case "/": return [Self.entry("home", directory: true)]
        case "/home": return [Self.entry("demo", directory: true)]
        case "/home/demo":
            return [Self.entry("src", directory: true), Self.entry("docs", directory: true),
                    Self.entry("empty", directory: true), Self.entry("README.md", size: 2048),
                    Self.entry("archive.zip", size: 10_485_760), Self.entry("release-notes-2026.md", size: 5120),
                    Self.entry("项目说明.txt", size: 4096)]
        case "/home/demo/src": return [Self.entry("main.swift", size: 8192), Self.entry("Configuration.swift", size: 12_288)]
        case "/home/demo/docs": return [Self.entry("guide.md", size: 16_384)]
        case "/home/demo/empty": return []
        default: throw .server(SFTPStatus(code: .noSuchFile))
        }
    }
    private static func entry(_ name: String, directory: Bool = false, size: UInt64 = 0) -> SFTPEntry {
        .init(filename: Array(name.utf8), attributes: .init(size: directory ? nil : size,
            permissions: directory ? 0o040755 : 0o100644, modificationTime: 1_790_856_000))
    }
    func volumeInfo(path: String) async throws(SFTPError) -> SFTPVolumeInfo? {
        .init(blockSize: 4096, fragmentSize: 4096, blocks: 67_108_864, blocksFree: 29_360_128,
              blocksAvailable: 29_360_128, files: 1_000_000, filesFree: 900_000,
              filesAvailable: 900_000, filesystemID: 0, flags: 0, nameMaximum: 255)
    }
    func lstat(path: String) async throws(SFTPError) -> SFTPAttributes {
        throw .server(SFTPStatus(code: .permissionDenied))
    }
    func makeDirectory(path: String) async throws(SFTPError) { throw .server(SFTPStatus(code: .permissionDenied)) }
    func remove(path: String) async throws(SFTPError) { throw .server(SFTPStatus(code: .permissionDenied)) }
    func removeDirectory(path: String) async throws(SFTPError) { throw .server(SFTPStatus(code: .permissionDenied)) }
    func rename(from oldPath: String, to newPath: String) async throws(SFTPError) { throw .server(SFTPStatus(code: .permissionDenied)) }
    func download(remotePath: String, to localDestination: URL, policy: SFTPTransferEngine.ConflictPolicy,
                  partialDisposition: SFTPTransferEngine.PartialDisposition, progress: SFTPTransferEngine.ProgressHandler?) async throws(SFTPError) -> SFTPTransferEngine.SFTPTransferReceipt {
        throw .server(SFTPStatus(code: .permissionDenied))
    }
    func upload(from localSource: URL, to remotePath: String, policy: SFTPTransferEngine.ConflictPolicy,
                partialDisposition: SFTPTransferEngine.PartialDisposition, progress: SFTPTransferEngine.ProgressHandler?) async throws(SFTPError) -> SFTPTransferEngine.SFTPTransferReceipt {
        throw .server(SFTPStatus(code: .permissionDenied))
    }
    func downloadDirectory(remotePath: String, to localDirectory: URL, policy: SFTPTransferEngine.ConflictPolicy,
                           progress: SFTPTransferEngine.DirectoryProgressHandler?) async throws(SFTPError) -> SFTPTransferEngine.DirectoryTransferReceipt {
        throw .server(SFTPStatus(code: .permissionDenied))
    }
    func uploadDirectory(from localDirectory: URL, to remotePath: String, policy: SFTPTransferEngine.ConflictPolicy,
                         progress: SFTPTransferEngine.DirectoryProgressHandler?) async throws(SFTPError) -> SFTPTransferEngine.DirectoryTransferReceipt {
        throw .server(SFTPStatus(code: .permissionDenied))
    }
    func close() {}
}
#endif
