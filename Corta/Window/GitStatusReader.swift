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

/// A repository's branch and whether tracked files differ, read from files only.
nonisolated struct GitFacts: Equatable, Sendable {
    var name: String
    var detached: Bool
    var worktree: Bool
    /// The main repository when this directory is a linked worktree.
    var mainRepository: String?
    /// Tracked files whose size or second-resolution mtime differs. Nil when unchecked.
    var changedFiles: Int?
    var unchecked: Bool

    static let maximumEntries = 20_000
}

/// Reads `.git` without running git. A missing repository is nil, never an error.
nonisolated enum GitStatusReader {
    static func read(directory: String) -> GitFacts? {
        guard let located = locate(URL(fileURLWithPath: directory, isDirectory: true)) else { return nil }
        guard let head = readHEAD(in: located.gitDir) else { return nil }
        let index = located.gitDir.appendingPathComponent("index")
        switch changedFiles(index: index, workTree: located.workTree) {
        case .counted(let count):
            return GitFacts(name: head.name, detached: head.detached, worktree: located.worktree,
                            mainRepository: located.main, changedFiles: count, unchecked: false)
        case .unchecked:
            return GitFacts(name: head.name, detached: head.detached, worktree: located.worktree,
                            mainRepository: located.main, changedFiles: nil, unchecked: true)
        }
    }

    struct Located: Equatable, Sendable {
        var gitDir: URL
        var workTree: URL
        var worktree: Bool
        var main: String?
    }

    static func locate(_ directory: URL) -> Located? {
        var current = directory.standardizedFileURL
        for _ in 0..<40 {
            let git = current.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: git.path, isDirectory: &isDirectory) else {
                let parent = current.deletingLastPathComponent()
                if parent.path == current.path { return nil }
                current = parent
                continue
            }
            if isDirectory.boolValue {
                return Located(gitDir: git, workTree: current, worktree: false, main: nil)
            }
            guard let target = gitdir(in: git) else { return nil }
            let resolved = URL(fileURLWithPath: target, relativeTo: git.deletingLastPathComponent())
                .standardizedFileURL
            return Located(gitDir: resolved, workTree: current, worktree: true, main: mainRepository(of: resolved))
        }
        return nil
    }

    /// `<main>/.git/worktrees/<name>` points back at `<main>`.
    static func mainRepository(of gitDir: URL) -> String? {
        let parts = gitDir.standardizedFileURL.pathComponents
        guard let worktrees = parts.lastIndex(of: "worktrees"), worktrees >= 2,
              parts[worktrees - 1] == ".git" else { return nil }
        return NSString(string: "/" + parts[1..<worktrees - 1].joined(separator: "/")).standardizingPath
    }

    private static func gitdir(in file: URL) -> String? {
        guard let data = try? Data(contentsOf: file, options: [.mappedIfSafe]), data.count <= 4096,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let line = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
        let prefix = "gitdir: "
        guard line.hasPrefix(prefix) else { return nil }
        let path = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, !path.contains("\0") else { return nil }
        return path
    }

    private struct Head {
        var name: String
        var detached: Bool
    }

    private static func readHEAD(in gitDir: URL) -> Head? {
        let file = gitDir.appendingPathComponent("HEAD")
        guard let data = try? Data(contentsOf: file), data.count <= 512,
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        let ref = "ref: refs/heads/"
        if text.hasPrefix(ref) {
            let name = String(text.dropFirst(ref.count))
            guard !name.isEmpty, !name.contains(".."), !name.hasPrefix("/") else { return nil }
            return Head(name: name, detached: false)
        }
        guard text.count >= 7, text.allSatisfy(\.isHexDigit) else { return nil }
        return Head(name: String(text.prefix(7)), detached: true)
    }

    private enum Changes { case counted(Int), unchecked }

    private static func changedFiles(index: URL, workTree: URL) -> Changes {
        guard let data = try? Data(contentsOf: index), data.count >= 12 else { return .counted(0) }
        guard data.prefix(4) == Data("DIRC".utf8) else { return .unchecked }
        let version = Int(integer(data, at: 4))
        let count = Int(integer(data, at: 8))
        guard (2...4).contains(version), count >= 0 else { return .unchecked }
        if count > GitFacts.maximumEntries { return .unchecked }
        var offset = 12
        var previous = ""
        var changed = 0
        let root = workTree.standardizedFileURL.path
        for _ in 0..<count {
            guard let entry = entry(data, at: &offset, version: version, previous: &previous) else { return .unchecked }
            let file = (root as NSString).appendingPathComponent(entry.path)
            guard file == root || file.hasPrefix(root + "/") else { continue }
            if differs(file, size: entry.size, mtime: entry.mtime) { changed += 1 }
        }
        return .counted(changed)
    }

    private struct Entry {
        var path: String
        var size: UInt32
        var mtime: UInt32
    }

    private static func entry(_ data: Data, at offset: inout Int, version: Int, previous: inout String) -> Entry? {
        let start = offset
        guard data.count >= start + 62 else { return nil }
        let mtime = integer(data, at: start + 8)
        let size = integer(data, at: start + 36)
        let flags = u16(data, at: start + 60)
        var cursor = start + 62
        if flags & 0x4000 != 0 {
            guard data.count >= cursor + 2 else { return nil }
            cursor += 2
        }
        let path: String
        if version == 4 {
            guard let decoded = compressedPath(data, at: &cursor, previous: previous) else { return nil }
            path = decoded
        } else {
            let marked = Int(flags & 0x0FFF)
            if marked == 0x0FFF {
                guard let end = data[cursor...].firstIndex(of: 0) else { return nil }
                path = String(decoding: data[cursor..<end], as: UTF8.self)
                cursor = end + 1
            } else {
                guard marked > 0, data.count >= cursor + marked else { return nil }
                path = String(decoding: data[cursor..<(cursor + marked)], as: UTF8.self)
                cursor += marked + 1
            }
            let span = cursor - start
            let padded = (span + 7) & ~7
            cursor = start + max(padded, span)
        }
        guard !path.isEmpty, !path.contains("\0"), !path.hasPrefix("/"), !path.contains("..") else { return nil }
        offset = cursor
        previous = path
        return Entry(path: path, size: size, mtime: mtime)
    }

    /// v4: a variable-width strip count, then the suffix up to NUL.
    private static func compressedPath(_ data: Data, at cursor: inout Int, previous: String) -> String? {
        var strip = 0
        var shift = 0
        while cursor < data.count {
            let byte = data[cursor]
            cursor += 1
            strip |= Int(byte & 0x7F) << shift
            shift += 7
            if byte & 0x80 == 0 { break }
            if shift > 28 { return nil }
        }
        guard let end = data[cursor...].firstIndex(of: 0), strip <= previous.utf8.count else { return nil }
        let suffix = String(decoding: data[cursor..<end], as: UTF8.self)
        cursor = end + 1
        let kept = String(decoding: previous.utf8.dropLast(strip), as: UTF8.self)
        return kept + suffix
    }

    private static func differs(_ path: String, size: UInt32, mtime: UInt32) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return true }
        return UInt32(truncatingIfNeeded: info.st_size) != size
            || UInt32(truncatingIfNeeded: info.st_mtimespec.tv_sec) != mtime
    }

    private static func integer(_ data: Data, at offset: Int) -> UInt32 {
        data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { UInt32(bigEndian: $0.load(as: UInt32.self)) }
    }

    private static func u16(_ data: Data, at offset: Int) -> UInt16 {
        data.subdata(in: offset..<(offset + 2)).withUnsafeBytes { UInt16(bigEndian: $0.load(as: UInt16.self)) }
    }
}
