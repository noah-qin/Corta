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

import CortaTerminal
import Foundation
import Synchronization

/// Published by main on UI changes, read once by the frame. No views or stores.
nonisolated struct RenderInputs: Sendable, Equatable {
    var readsInputSourceMetadata = false
    var generation: UInt64 = 0
    var scrollOffset = 0
    var scrollAnchorTotalPushed: Int?
    var cursorVisible = true
    var cursorStyle: CursorStyle = .block
    var cursorBlinkVisible = true
    var selection: TerminalSelection?
    var searchMatches: [TerminalSelection] = []
    var currentSearchMatchIndex: Int?
    var hoveredLink: TerminalSelection?
    var drawsCommandMarks = true
    var topInset: CGFloat = 0
    var theme = Theme.corta.dark
}

nonisolated final class RenderInputMailbox: Sendable {
    private let value = Mutex(RenderInputs())
    @discardableResult
    func publish(_ inputs: RenderInputs) -> Bool {
        return value.withLock { previous in
            var inputs = inputs
            inputs.generation = previous.generation
            guard inputs != previous else { return false }
            inputs.generation &+= 1
            previous = inputs
            return true
        }
    }
    func read() -> RenderInputs { value.withLock { $0 } }
}

/// Captured under the same core lock as the grid it describes.
nonisolated struct RenderInputSourceMetadata: Sendable {
    var hasIntegration: Bool
    var promptRow: Int?
}
