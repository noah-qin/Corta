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
        try "ref: refs/heads/feature/login\n".write(to: git.appendingPathComponent("HEAD"), atomically: true,
            encoding: .utf8)
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
        try "gitdir: \(gitdir.path)\n".write(to: linked.appendingPathComponent(".git"), atomically: true,
            encoding: .utf8)
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
        let same = index(entries: [IndexEntry("same.txt", UInt32(info.st_size),
            UInt32(info.st_mtimespec.tv_sec))], version: 2)
        try same.write(to: git.appendingPathComponent("index"))
        #expect(GitStatusReader.read(directory: root.path)?.changedFiles == 0)
        let dirty = index(entries: [IndexEntry("same.txt", 1, 1)], version: 2)
        try dirty.write(to: git.appendingPathComponent("index"))
        #expect(GitStatusReader.read(directory: root.path)?.changedFiles == 1)
        let missing = index(entries: [IndexEntry("gone.txt", 1, 1), IndexEntry("same.txt",
            UInt32(info.st_size), UInt32(info.st_mtimespec.tv_sec))], version: 3)
        try missing.write(to: git.appendingPathComponent("index"))
        #expect(GitStatusReader.read(directory: root.path)?.changedFiles == 1)
        var many: [IndexEntry] = []
        for number in 0..<(GitFacts.maximumEntries + 1) { many.append(IndexEntry("f\(number)", 0, 0)) }
        try index(entries: many, version: 2).write(to: git.appendingPathComponent("index"))
        #expect(GitStatusReader.read(directory: root.path)?.unchecked == true)
        let compressed = index(entries: [IndexEntry("src/a.txt", 1, 1), IndexEntry("src/b.txt", 1, 1)], version: 4)
        try compressed.write(to: git.appendingPathComponent("index"))
        let parsed = try #require(GitStatusReader.read(directory: root.path))
        #expect(parsed.unchecked == false)
        #expect(parsed.changedFiles == 2)
    }

    @MainActor @Test func trackedWorktreeEditsRefreshWithoutGitMetadataChanges() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        let file = root.appendingPathComponent("tracked")
        try Data("first".utf8).write(to: file)
        var info = stat()
        try #require(lstat(file.path, &info) == 0)
        try index(entries: [IndexEntry("tracked", 5, UInt32(info.st_mtimespec.tv_sec))], version: 2)
            .write(to: git.appendingPathComponent("index"))
        let monitor = GitStatusMonitor()
        let session = UUID()
        var latest: GitFacts?
        monitor.onUpdate = { latest = $0[session] }
        monitor.update([session: root.path])
        let initialDeadline = SuspendingClock.now.advanced(by: .seconds(3))
        while latest == nil, SuspendingClock.now < initialDeadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(latest?.changedFiles == 0)
        try Data("untracked".utf8).write(to: root.appendingPathComponent("ignored"))
        try await Task.sleep(for: .milliseconds(800))
        #expect(latest?.changedFiles == 0)
        let start = SuspendingClock.now
        try Data("changed-size".utf8).write(to: file)
        // The one-second target is this machine's; a saturated CI runner
        // gets the suite's usual scale (`testTimeoutScale`).
        while latest?.changedFiles != 1, start.duration(to: .now) < .seconds(2) * testTimeoutScale {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(latest?.changedFiles == 1)
        #expect(start.duration(to: .now) < .seconds(1) * testTimeoutScale)
        print("Git tracked edit refresh: \(start.duration(to: .now))")
        monitor.update([:])
    }

    private struct IndexEntry {
        var path: String
        var size: UInt32
        var mtime: UInt32
        init(_ path: String, _ size: UInt32, _ mtime: UInt32) {
            self.path = path; self.size = size; self.mtime = mtime
        }
    }

    private func index(entries: [IndexEntry], version: Int) -> Data {
        var data = Data("DIRC".utf8)
        func u32(_ value: UInt32) { var big = value.bigEndian; data.append(Data(bytes: &big, count: 4)) }
        func u16(_ value: UInt16) { var big = value.bigEndian; data.append(Data(bytes: &big, count: 2)) }
        u32(UInt32(version))
        u32(UInt32(entries.count))
        var previous = ""
        for entry in entries {
            let start = data.count
            u32(0); u32(0)
            u32(entry.mtime); u32(0)
            u32(0); u32(0); u32(0); u32(0); u32(0)
            u32(entry.size)
            data.append(Data(count: 20))
            if version == 4 {
                u16(0)
                let previousBytes = Array(previous.utf8)
                let current = Array(entry.path.utf8)
                let shared = zip(previousBytes, current).prefix { $0 == $1 }.count
                let strip = previousBytes.count - shared
                data.append(UInt8(strip))
                data.append(contentsOf: current.dropFirst(shared))
                data.append(0)
            } else {
                let name = Array(entry.path.utf8)
                u16(UInt16(name.count))
                if version >= 3 { /* extended flag unset */ }
                data.append(contentsOf: name)
                data.append(0)
                let span = data.count - start
                let padded = (span + 7) & ~7
                if padded > span { data.append(Data(count: padded - span)) }
            }
            previous = entry.path
        }
        return data
    }
}
