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

/// Writes a user-owned file (rc file, config) without changing what the
/// path is. `String.write(to:atomically:)` replaces a symlink with a plain
/// file — a dotfiles `~/.zshrc` stops being the repository's — and resets
/// permissions. This follows the link, writes atomically there, and
/// restores the permission bits.
nonisolated enum UserFile {
    /// Beyond this a chain counts as a loop and is written in place.
    private static let maximumLinkDepth = 32

    /// Writes atomically to the final target, creating its directory and
    /// keeping permissions. A dangling link's target is created, and the link
    /// stays.
    static func write(_ text: String, to url: URL) throws {
        let target = resolvingLinks(url)
        let manager = FileManager.default
        let permissions = (try? manager.attributesOfItem(atPath: target.path))?[.posixPermissions]
        try manager.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: target, atomically: true, encoding: .utf8)
        if let permissions {
            try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
        }
    }

    /// Follows links, resolving relative targets against the link's
    /// directory; unlike `resolvingSymlinksInPath()` it follows a link to a
    /// missing file.
    static func resolvingLinks(_ url: URL) -> URL {
        var current = url.standardizedFileURL
        let manager = FileManager.default
        for _ in 0..<maximumLinkDepth {
            guard let attributes = try? manager.attributesOfItem(atPath: current.path),
                attributes[.type] as? FileAttributeType == .typeSymbolicLink,
                let destination = try? manager.destinationOfSymbolicLink(atPath: current.path)
            else { return current }
            if destination.hasPrefix("/") {
                current = URL(fileURLWithPath: destination).standardizedFileURL
            } else {
                current = current.deletingLastPathComponent()
                    .appendingPathComponent(destination).standardizedFileURL
            }
        }
        return current
    }
}
