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
/// zero-width characters that hide content — ZWSP, the word joiner and the
/// invisible operators, BOM. ZWJ, ZWNJ and LRM/RLM are not here: emoji
/// sequences and real bidi text break without them.
///
/// One list for every place a stream's text is shown or handed on: the grid
/// draws each as U+FFFD, and OSC 52 strips them before the pasteboard.
public enum ConcealingScalars {
    public static func contains(_ value: UInt32) -> Bool {
        switch value {
        case 0x200B, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x2069, 0xFEFF:
            return true
        default:
            return false
        }
    }
}
