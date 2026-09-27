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

/// Coalesces resizes so a live drag doesn't send `TIOCSWINSZ`/`SIGWINCH`
/// per mouse motion (`CONFORMANCE.md` §2.3). The latest size always
/// arrives: when the drag goes quiet, or at once via `flush()`.
@MainActor
final class ResizeDebouncer {
    private let delay: TimeInterval
    private let handler: (TerminalSize) -> Void
    private var pending: DispatchWorkItem?

    init(delay: TimeInterval = 0.1, handler: @escaping (TerminalSize) -> Void) {
        self.delay = delay
        self.handler = handler
    }

    /// Delivers now unless `coalesce` (a live drag), which replaces the
    /// pending size and waits for `delay` of quiet.
    func resize(to size: TerminalSize, coalesce: Bool) {
        pending?.cancel()
        pending = nil
        guard coalesce else {
            handler(size)
            return
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            self.handler(size)
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Delivers the pending size now, at the end of a live resize.
    func flush() {
        guard let item = pending, !item.isCancelled else { return }
        pending = nil
        // Perform before cancelling: a cancelled item won't perform, and a
        // performed one won't fire again.
        item.perform()
        item.cancel()
    }
}
