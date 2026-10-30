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

struct GitStatusReaderTests {
    private func temporary() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func headShapesGitdirAndAMissingRepository() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(GitStatusReader.read(directory: root.path) == nil)
        let git = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "ref: refs/heads/feature/login\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        let branch = try #require(GitStatusReader.read(directory: root.appendingPathComponent("src").path))
        #expect(branch.name == "feature/login")
        #expect(!branch.detached)
        #expect(!branch.worktree)
        try "0123456789abcdef\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        #expect(GitStatusReader.read(directory: root.path)?.detached == true)
        #expect(GitStatusReader.read(directory: root.path)?.name == "0123456")

        let linked = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        let gitdir = root.appendingPathComponent(".git/worktrees/linked")
        try FileManager.default.createDirectory(at: gitdir, withIntermediateDirectories: true)
        try "ref: refs/heads/side\n".write(to: gitdir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "gitdir: \(gitdir.path)\n".write(to: linked.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        let worktree = try #require(GitStatusReader.read(directory: linked.path))
        #expect(worktree.worktree)
        #expect(worktree.name == "side")
        #expect(worktree.mainRepository == root.path)
        try Data("not an index".utf8).write(to: git.appendingPathComponent("index"))
        #expect(GitStatusReader.read(directory: root.path)?.unchecked == true)
    }

    @Test func indexEntriesCompareSizeAndSecondMtimeAndStopAtTheCap() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        let file = root.appendingPathComponent("same.txt")
        try Data("hello".utf8).write(to: file)
        var info = stat()
        #expect(lstat(file.path, &info) == 0)
        let same = index(entries: [("same.txt", UInt32(info.st_size), UInt32(info.st_mtimespec.tv_sec))], version: 2)
        try same.write(to: git.appendingPathComponent("index"))
        #expect(GitStatusReader.read(directory: root.path)?.changedFiles == 0)
        let dirty = index(entries: [("same.txt", 1, 1)], version: 2)
        try dirty.write(to: git.appendingPathComponent("index"))
        #expect(GitStatusReader.read(directory: root.path)?.changedFiles == 1)
        let missing = index(entries: [("gone.txt", 1, 1), ("same.txt", UInt32(info.st_size), UInt32(info.st_mtimespec.tv_sec))], version: 3)
        try missing.write(to: git.appendingPathComponent("index"))
        #expect(GitStatusReader.read(directory: root.path)?.changedFiles == 1)
        var many: [(String, UInt32, UInt32)] = []
        for number in 0..<(GitFacts.maximumEntries + 1) { many.append(("f\(number)", 0, 0)) }
        try index(entries: many, version: 2).write(to: git.appendingPathComponent("index"))
        #expect(GitStatusReader.read(directory: root.path)?.unchecked == true)
        let compressed = index(entries: [("src/a.txt", 1, 1), ("src/b.txt", 1, 1)], version: 4)
        try compressed.write(to: git.appendingPathComponent("index"))
        let parsed = try #require(GitStatusReader.read(directory: root.path))
        #expect(parsed.unchecked == false)
        #expect(parsed.changedFiles == 2)
    }

    private func index(entries: [(String, UInt32, UInt32)], version: Int) -> Data {
        var data = Data("DIRC".utf8)
        func u32(_ value: UInt32) { var big = value.bigEndian; data.append(Data(bytes: &big, count: 4)) }
        func u16(_ value: UInt16) { var big = value.bigEndian; data.append(Data(bytes: &big, count: 2)) }
        u32(UInt32(version))
        u32(UInt32(entries.count))
        var previous = ""
        for entry in entries {
            let start = data.count
            u32(0); u32(0)
            u32(entry.2); u32(0)
            u32(0); u32(0); u32(0); u32(0); u32(0)
            u32(entry.1)
            data.append(Data(count: 20))
            if version == 4 {
                u16(0)
                let previousBytes = Array(previous.utf8)
                let current = Array(entry.0.utf8)
                let shared = zip(previousBytes, current).prefix { $0 == $1 }.count
                let strip = previousBytes.count - shared
                data.append(UInt8(strip))
                data.append(contentsOf: current.dropFirst(shared))
                data.append(0)
            } else {
                let name = Array(entry.0.utf8)
                u16(UInt16(name.count))
                if version >= 3 { /* extended flag unset */ }
                data.append(contentsOf: name)
                data.append(0)
                let span = data.count - start
                let padded = (span + 7) & ~7
                if padded > span { data.append(Data(count: padded - span)) }
            }
            previous = entry.0
        }
        return data
    }
}
