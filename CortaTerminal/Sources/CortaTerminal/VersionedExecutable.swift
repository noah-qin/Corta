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

/// Some self-updating tools install each release as an executable named
/// after its version: Claude Code's native installer runs
/// `~/.local/share/claude/versions/2.1.316`, so the kernel's process name is
/// "2.1.316". A title, a close confirmation and a tab icon all want the
/// tool, which is the directory that holds `versions`.
///
/// Only the kernel's executable path is read — never terminal output, and
/// never argv, which a process can rewrite.
enum VersionedExecutable {
    /// "2.1.316", "1.0", "0.47.2": digits separated by single dots, at
    /// least one dot, so a plain number such as "7" stays itself.
    static func looksLikeVersion(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.count <= 6 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.count <= 9 && part.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }

    /// `…/<tool>/versions/<version>` → `<tool>`; anything else → `nil`.
    static func toolName(executablePath path: String) -> String? {
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 3,
              looksLikeVersion(components[components.count - 1]),
              components[components.count - 2] == "versions" else { return nil }
        let tool = components[components.count - 3]
        guard !tool.isEmpty, !tool.hasPrefix("."), tool.utf8.count <= 64 else { return nil }
        return tool
    }

    /// The tool behind a version-named process, or `nil` to keep `name`.
    static func resolve(pid: pid_t, name: String) -> String? {
        guard looksLikeVersion(name) else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return toolName(executablePath: String(decoding: bytes, as: UTF8.self))
    }
}
