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
import OSLog

/// `os_signpost` across the keypress-to-pixel chain, so the number in
/// `PERFORMANCE.md` §1 can be attributed — parse, main-actor hop, drawable
/// wait or GPU each have different fixes.
///
/// | Stage | Interval | Where |
/// | --- | --- | --- |
/// | key event → bytes on the PTY | `keyDown` | `TerminalView.deliverBytes` (⌘/⌃ bypass, or declined by the IME), `.insertText` (most typing), `.doCommand(by:)` (Return, Delete, Escape, arrows) |
/// | reader wakes, parses, writes the grid | `output` | `PaneFrameLoop.noteOutput` |
/// | MainActor hop that wakes the display link | `wake` | `PaneFrameLoop.noteOutput` |
/// | vsync callback, damage diff, instance build | `frame` | `FrameScheduler.metalDisplayLink(_:needsUpdate:)` |
/// | encode + commit | `commit` | `PaneFrameLoop.render` |
/// | GPU work through to completion | `gpu` | `PaneFrameLoop.render` |
///
/// Every call sits behind `OSSignposter.isEnabled`, one atomic load when
/// no trace is recording, so it is safe in release builds.
///
/// Record every process while something else brings Corta forward —
/// launching through `xctrace` doesn't give the window focus, so no
/// `keyDown` is captured (`PERFORMANCE.md` §5.3):
///
/// ```sh
/// xcrun xctrace record --instrument os_signpost --all-processes \
///     --time-limit 90s --output .build/traces/signposts.trace
/// ```
///
/// Filter on subsystem `dev.noahqin.Corta`, category `input-latency`.
/// `nonisolated` because the chain crosses threads.
nonisolated enum InputLatencySignposts {
    static let subsystem = "dev.noahqin.Corta"
    static let category = "input-latency"

    /// `OSLog(subsystem:category:)` is the signpost-capable initialiser.
    static let signposter = OSSignposter(
        logHandle: OSLog(subsystem: subsystem, category: category))

    /// Whether a trace is recording; checked at every call site.
    static var isEnabled: Bool { signposter.isEnabled }

    /// Names are `StaticString`s, which can't be raw values, so each stage
    /// returns its literal from a property.
    enum Stage {
        case keyDown
        case output
        case wake
        case frame
        case commit
        case gpu

        var name: StaticString {
            switch self {
            case .keyDown: "keyDown"
            case .output: "output"
            case .wake: "wake"
            case .frame: "frame"
            case .commit: "commit"
            case .gpu: "gpu"
            }
        }
    }

    /// Nil when no trace is running.
    static func begin(_ stage: Stage) -> OSSignpostIntervalState? {
        guard isEnabled else { return nil }
        return signposter.beginInterval(stage.name, id: signposter.makeSignpostID())
    }

    static func end(_ stage: Stage, _ state: OSSignpostIntervalState?) {
        guard let state else { return }
        signposter.endInterval(stage.name, state)
    }

    /// A point event, for hand-offs across threads.
    static func emit(_ stage: Stage) {
        guard isEnabled else { return }
        signposter.emitEvent(stage.name, id: signposter.makeSignpostID())
    }

    /// An interval around `body`, so no early return skips `end`.
    @inline(__always)
    static func measure<T>(_ stage: Stage, _ body: () -> T) -> T {
        guard isEnabled else { return body() }
        let state = begin(stage)
        defer { end(stage, state) }
        return body()
    }
}
