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

import Foundation
import Testing

@testable import Corta

struct ExportStagingTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("corta-export-recovery-\(UUID().uuidString)", isDirectory: true)
    private var journal: URL { root.appendingPathComponent("journal", isDirectory: true) }
    private var parent: URL { root.appendingPathComponent("exports", isDirectory: true) }

    @Test("recovery removes only a dead export recorded for this directory")
    func recoversAbandonedExports() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try PrivateFile.createDirectory(at: parent)
        let final = parent.appendingPathComponent("History.txt")
        try Data("previous export".utf8).write(to: final)
        let abandoned = try makeStaging(pid: .max)
        let live = try makeStaging(pid: getpid())
        let replacedParent = try makeStaging(pid: .max, wrongInode: true)
        let unrecorded = parent.appendingPathComponent(".corta-export-\(UUID().uuidString)")
        try PrivateFile.createDirectory(at: unrecorded)

        ExportStaging.removeAbandoned(in: journal)

        #expect(!FileManager.default.fileExists(atPath: abandoned.folder.path))
        #expect(!FileManager.default.fileExists(atPath: abandoned.entry.path))
        for kept in [live, replacedParent] {
            #expect(FileManager.default.fileExists(atPath: kept.folder.appendingPathComponent("payload").path))
            #expect(FileManager.default.fileExists(atPath: kept.entry.path))
        }
        #expect(FileManager.default.fileExists(atPath: unrecorded.path))
        #expect(try String(contentsOf: final, encoding: .utf8) == "previous export")
    }

    @Test("failed preparation discards the partial export and keeps the destination")
    func cleansUpFailedExport() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try PrivateFile.createDirectory(at: parent)
        let final = parent.appendingPathComponent("History.txt")
        try Data("previous export".utf8).write(to: final)

        #expect(throws: POSIXError(.ENOSPC)) {
            try ExportStaging.replace(final, journal: journal) { temporary in
                try PrivateFile.writeExclusively(Data("partial".utf8), at: temporary)
                throw POSIXError(.ENOSPC)
            }
        }
        #expect(try String(contentsOf: final, encoding: .utf8) == "previous export")
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path) == ["History.txt"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: journal.path).isEmpty)
    }

    private func makeStaging(pid: pid_t, wrongInode: Bool = false) throws -> (folder: URL, entry: URL) {
        let id = UUID()
        let folder = parent.appendingPathComponent(".corta-export-\(id.uuidString)", isDirectory: true)
        try PrivateFile.createDirectory(at: folder)
        try PrivateFile.writeExclusively(Data("partial".utf8), at: folder.appendingPathComponent("payload"))
        var info = stat()
        let parentPath = parent.resolvingSymlinksInPath().path
        guard fstatat(AT_FDCWD, parentPath, &info, 0) == 0 else { throw POSIXError(.EIO) }
        let record = ExportStaging.Record(
            pid: pid, parentPath: parentPath, device: info.st_dev, inode: wrongInode ? 0 : info.st_ino,
            volumeUUID: try parent.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
        let entry = journal.appendingPathComponent("\(id.uuidString).json")
        try PrivateFile.write(JSONEncoder().encode(record), to: entry)
        return (folder, entry)
    }
}
