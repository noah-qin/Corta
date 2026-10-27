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
import Synchronization
import Testing
@testable import CortaSFTP

extension FakeSFTPServer {
    func respondOpendir(_ message: SFTPMessage) {
        guard case .opendir(let path) = message.payload else { return }
        let requestID = message.requestID
        let fail = failure(requestID: requestID)
        let name = String(decoding: path, as: UTF8.self)
        guard let children = fileSystem.children(of: name) else {
            fail(.noSuchFile, "no such directory")
            return
        }
        let entries = children.map { child -> SFTPEntry in
            let full = name == "/" ? "/\(child)" : "\(name)/\(child)"
            let attributes: SFTPAttributes
            if let file = fileSystem.file(full) {
                attributes = SFTPAttributes(
                    size: UInt64(file.data.count), permissions: file.permissions,
                    modificationTime: file.modificationTime)
            } else {
                attributes = SFTPAttributes(permissions: 0o040_755)
            }
            return SFTPEntry(filename: Array(child.utf8), attributes: attributes)
        }
        let handle = newHandle(.directory(path: name, entries: entries, position: 0))
        send(.handle(Array(handle.utf8)), requestID: requestID)
    }

    func respondReaddir(_ message: SFTPMessage) {
        guard case .readdir(let handle) = message.payload else { return }
        let requestID = message.requestID
        let fail = failure(requestID: requestID)
        let name = String(decoding: handle, as: UTF8.self)
        guard var info = state.withLock({ $0.handles[name] }),
            case .directory(_, let entries, let position) = info.kind
        else {
            fail(.failure, "no such handle")
            return
        }
        if position >= entries.count {
            fail(.endOfFile, "eof")
            return
        }
        let end = min(position + readDirBatchSize, entries.count)
        let batch = Array(entries[position..<end])
        info.kind = .directory(path: name, entries: entries, position: end)
        state.withLock { $0.handles[name] = info }
        send(.name(batch), requestID: requestID)
    }

    func respondRename(_ message: SFTPMessage) {
        guard case .rename(let oldPath, let newPath) = message.payload else { return }
        let requestID = message.requestID
        let fail = failure(requestID: requestID)
        let oldName = String(decoding: oldPath, as: UTF8.self)
        let newName = String(decoding: newPath, as: UTF8.self)
        // Version 3 semantics: fail when the destination exists.
        if fileSystem.exists(newName) {
            fail(.failure, "destination exists")
            return
        }
        renameOnFileSystem(from: oldName, to: newName)
        fail(.ok, "")
    }

    func respondExtended(_ message: SFTPMessage) {
        guard case .extended(let name, let data) = message.payload else { return }
        let requestID = message.requestID
        let fail = failure(requestID: requestID)
        let extensionName = String(decoding: name, as: UTF8.self)
        if extensionName == SFTPCodec.statVFSExtensionName {
            guard advertisedExtensions.contains(extensionName), let info = statVFSReply else {
                fail(.operationUnsupported, "unsupported")
                return
            }
            var writer = SFTPWriter()
            for value in [
                info.blockSize, info.fragmentSize, info.blocks, info.blocksFree,
                info.blocksAvailable, info.files, info.filesFree, info.filesAvailable,
                info.filesystemID, info.flags, info.nameMaximum,
            ] {
                writer.writeUInt64(value)
            }
            _ = data
            send(.extendedReply(writer.bytes), requestID: requestID)
        } else if extensionName == SFTPCodec.posixRenameExtensionName {
            guard advertisedExtensions.contains(extensionName) else {
                fail(.operationUnsupported, "unsupported")
                return
            }
            var reader = SFTPReader(bytes: data)
            guard let oldPath = try? reader.readString(),
                let newPath = try? reader.readString()
            else {
                fail(.badMessage, "bad posix-rename body")
                return
            }
            renameOnFileSystem(
                from: String(decoding: oldPath, as: UTF8.self),
                to: String(decoding: newPath, as: UTF8.self))
            fail(.ok, "")
        } else {
            fail(.operationUnsupported, "unsupported")
        }
    }

    func newHandle(_ kind: HandleState.Kind) -> String {
        state.withLock { state in
            state.nextHandle += 1
            let name = "handle-\(state.nextHandle)"
            state.handles[name] = HandleState(kind: kind)
            return name
        }
    }

    private func renameOnFileSystem(from oldName: String, to newName: String) {
        fileSystem.rename(from: oldName, to: newName)
    }
}
