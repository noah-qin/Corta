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

extension Performer {
    /// Erasure — ECMA-48 §8.3: ED and EL.
    ///
    /// Returns false when `final` is not an erase sequence, so the dispatch
    /// table in `Performer.swift` can fall through to the next category.
    mutating func performErase(final: UInt8, parameters: Parameters) -> Bool {
        switch final {
        case 0x4A:  // ED
            switch parameters[0] {
            case 0: grid.eraseDisplay(.toEnd)
            case 1: grid.eraseDisplay(.toStart)
            case 2:
                grid.eraseDisplay(.all)
                promptFollowsErase()
            // ED 3 (xterm): erase the scrollback, and the images anchored in
            // it. Not in ECMA-48, but tmux and clear(1) both send it.
            case 3: grid.clearScrollback()
            default: break
            }
        case 0x4B:  // EL
            switch parameters[0] {
            case 0: grid.eraseLine(.toEnd)
            case 1: grid.eraseLine(.toStart)
            case 2: grid.eraseLine(.all)
            default: break
            }
        default:
            return false
        }
        return true
    }
}
