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

/// JSONDecoder keeps one value for a repeated key. Resume metadata must never
/// depend on which value it kept, including an escaped spelling of the key.
nonisolated enum SpaceConversationJSON {
    static func hasDuplicateKeys(_ data: Data) -> Bool {
        let bytes = Array(data)
        var objects: [Set<String>] = []
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case 123: objects.append([])
            case 125: if !objects.isEmpty { objects.removeLast() }
            case 34:
                let start = index
                index += 1
                while index < bytes.count {
                    if bytes[index] == 92 { index += 2; continue }
                    if bytes[index] == 34 { break }
                    index += 1
                }
                guard index < bytes.count else { return true }
                let end = index + 1
                var next = end
                while next < bytes.count, [9, 10, 13, 32].contains(bytes[next]) { next += 1 }
                if next < bytes.count, bytes[next] == 58, !objects.isEmpty,
                   let key = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<end])) {
                    if !objects[objects.count - 1].insert(key).inserted { return true }
                }
            default: break
            }
            index += 1
        }
        return false
    }
}
