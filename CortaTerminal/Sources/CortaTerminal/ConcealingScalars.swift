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

/// The scalars that let text display as something other than what it is
/// (`SECURITY.md` §2.5): bidi embeddings, overrides and isolates, and the
/// zero-width characters that hide content — ZWSP, the Mongolian vowel
/// separator, the word joiner and invisible operators, the deprecated format
/// controls, BOM, and the tag characters that smuggle ASCII invisibly. ZWJ,
/// ZWNJ and LRM/RLM are not here: emoji sequences and real bidi text break
/// without them. Tags are text only inside a subdivision flag
/// (U+1F3F4 followed by tags, 🏴󠁧󠁢󠁳󠁣󠁴󠁿), which `isTag` lets callers allow.
///
/// One list for every place a stream's text is shown or handed on: the grid
/// draws each as U+FFFD, and OSC 52 strips them before the pasteboard.
public enum ConcealingScalars {
    public static func contains(_ value: UInt32) -> Bool {
        switch value {
        case 0x180E, 0x200B, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x206F, 0xFEFF,
            0xE0001, 0xE0020...0xE007F:
            return true
        default:
            return false
        }
    }

    /// The tag characters, legitimate only continuing a U+1F3F4 flag.
    public static func isTag(_ value: UInt32) -> Bool {
        value == 0xE0001 || (0xE0020...0xE007F).contains(value)
    }

    /// The black flag that subdivision-flag tags continue.
    public static let flagBase: UInt32 = 0x1F3F4

    /// Whether `next` may continue `cluster` as part of a subdivision flag:
    /// the flag, at most seven tags (`gbsct` and its cancel tag is six), and
    /// nothing after the cancel tag U+E007F. A flag is no envelope for an
    /// arbitrary hidden message.
    public static func continuesFlag(_ cluster: some BidirectionalCollection<UInt32>, with next: UInt32) -> Bool {
        guard isTag(next), cluster.first == flagBase, cluster.count <= 7,
            cluster.dropFirst().allSatisfy(isTag), cluster.last != 0xE007F
        else { return false }
        return true
    }
}
