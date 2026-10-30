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

extension ConversationProcess {
    /// Only HOME is decoded. No environment dictionary or other value escapes
    /// the bounded kernel buffer, and there is no account-home fallback.
    static func homeDirectory(_ pid: pid_t) -> URL? {
        var query: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var length = 64 * 1024
        var bytes = [UInt8](repeating: 0, count: length)
        guard sysctl(&query, UInt32(query.count), &bytes, &length, nil, 0) == 0 else { return nil }
        return homeDirectory(bytes: Array(bytes.prefix(length)))
    }

    static func homeDirectory(bytes: [UInt8]) -> URL? {
        let offset = MemoryLayout<Int32>.size
        guard bytes.count > offset else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= bytes.count,
              let pathEnd = bytes[offset...].firstIndex(of: 0) else { return nil }
        var cursor = pathEnd
        while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }
        // Skip each argument as bytes; a HOME= argument is never an environment value.
        for _ in 0..<argc {
            guard cursor < bytes.count, let end = bytes[cursor...].firstIndex(of: 0) else { return nil }
            cursor = end + 1
        }
        while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }
        let key = Array("HOME=".utf8)
        var home: URL?
        while cursor < bytes.count, let end = bytes[cursor...].firstIndex(of: 0), end > cursor {
            let entry = bytes[cursor..<end]
            if entry.starts(with: key) {
                guard home == nil, let value = String(bytes: entry.dropFirst(key.count), encoding: .utf8),
                      value.hasPrefix("/") else { return nil }
                home = URL(fileURLWithPath: value, isDirectory: true)
            }
            cursor = end + 1
        }
        return home
    }

    /// One environment value. Other entries are skipped as bytes and not returned.
    public static func environmentValue(_ pid: pid_t, key: String) -> String? {
        var query: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var length = 64 * 1024
        var bytes = [UInt8](repeating: 0, count: length)
        guard sysctl(&query, UInt32(query.count), &bytes, &length, nil, 0) == 0 else { return nil }
        return environmentValue(bytes: Array(bytes.prefix(length)), key: key)
    }

    static func environmentValue(bytes: [UInt8], key: String) -> String? {
        let offset = MemoryLayout<Int32>.size
        guard bytes.count > offset, !key.isEmpty, !key.contains("=") else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= bytes.count,
              let pathEnd = bytes[offset...].firstIndex(of: 0) else { return nil }
        var cursor = pathEnd
        while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }
        for _ in 0..<argc {
            guard cursor < bytes.count, let end = bytes[cursor...].firstIndex(of: 0) else { return nil }
            cursor = end + 1
        }
        while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }
        let needle = Array((key + "=").utf8)
        var found: String?
        while cursor < bytes.count, let end = bytes[cursor...].firstIndex(of: 0), end > cursor {
            let entry = bytes[cursor..<end]
            if entry.starts(with: needle) {
                guard found == nil else { return nil }
                found = String(bytes: entry.dropFirst(needle.count), encoding: .utf8)
            }
            cursor = end + 1
        }
        return found
    }
}
