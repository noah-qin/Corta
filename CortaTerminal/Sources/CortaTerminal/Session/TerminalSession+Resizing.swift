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
import Synchronization

/// Resizing: the grid first, then the child's signal. Any thread.
extension TerminalSession {
    /// The child must never see (`TIOCGWINSZ`/`SIGWINCH`) a size the grid has
    /// not adopted, or its redraw is parsed into old-size cells — lasting, on the
    /// alternate screen, which is never reflowed. So on `resizeQueue`, in order:
    /// the rebuilt grid commits under the reader's lock, then `TIOCSWINSZ`
    /// signals.
    ///
    /// That delays `SIGWINCH` by one reflow (50–90 ms at 100k lines,
    /// `PERFORMANCE.md` §5.18), so queued requests coalesce to the latest; the
    /// work stays off the caller's thread. Frames meanwhile draw the old size.
    /// Bytes written before the signal may land at the new width — bounded by
    /// one batch, and repainted by the child. `onOutput` then wakes a redraw.
    public func resize(to size: TerminalSize) {
        let serial = requestedResize.withLock { requested -> UInt64 in
            let next = (requested?.serial ?? 0) + 1
            requested = (serial: next, size: size)
            return next
        }
        resizeQueue.async { [self] in
            resizeWorkGate?()
            guard requestedResize.withLock({ $0?.serial == serial }) else { return }
            guard rebuildGrid(for: size, serial: serial) else { return }
            scheduleCompression()
            try? pty.resize(to: size)
            callbacks.withLock { $0.onOutput }?()
        }
    }

    /// The reflow outside the lock, which every frame's snapshot needs: with
    /// the reader parked (`State.isResizing`) nothing should touch the grid,
    /// so a copy is rebuilt and swapped in. What can still touch it — a clear,
    /// a reset, a scale change on the main thread — moves `gridGeneration`, and
    /// the resize is then redone from the current grid in the commit's lock:
    /// slower, and it loses nothing. False when a newer request supersedes this
    /// one; that request does the commit and the signal.
    private func rebuildGrid(for size: TerminalSize, serial: UInt64) -> Bool {
        let rows = Int(size.rows), columns = Int(size.columns)
        // Registered: `SIGWINCH` waits on this commit.
        let (original, generation) = registerStateWaiter {
            state.withLock { current in
                current.isResizing = true
                return (current.terminal.grid, current.terminal.gridGeneration)
            }
        }
        var rebuilt = original
        rebuilt.resize(rows: rows, columns: columns)
        resizeCommitGate?()
        let finished = rebuilt
        let current = requestedResize.withLock { $0?.serial == serial }
        registerStateWaiter {
            state.withLock { locked in
                defer { locked.isResizing = false }
                guard current else { return }
                if locked.terminal.gridGeneration == generation {
                    locked.terminal.grid = finished
                } else {
                    locked.terminal.resize(rows: rows, columns: columns)
                }
                // Set after, and even with rows and columns unchanged:
                // a font change alters only the pixels.
                locked.terminal.grid.cellPixelHeight = size.cellPixelHeight
                locked.terminal.grid.cellPixelWidth = size.cellPixelWidth
            }
        }
        // Freed here rather than in the lock: a whole scrollback's arenas.
        withExtendedLifetime(original) {}
        return current
    }
}
