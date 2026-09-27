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

/// The prepared inputs for one frame, computed once by
/// `ViewController.prepareFrame()` (the `FrameScheduler.shouldRenderFrame`
/// callback) and consumed by `ViewController.render(into:...)`
/// (`FrameScheduler.onRenderFrame`), which always runs immediately after it
/// in the same `FrameScheduler.metalDisplayLink` callback — see
/// `FrameScheduler`. Computing it once means one `session.snapshot()` and
/// one `searchMatches.map { ... }` pass per frame, not one per consumer.
struct FrameContext {
    var grid: Grid
    var scrollOffset: Int
    var cursorVisible: Bool
    var selection: TerminalSelection?
    var searchMatches: [TerminalSelection]
    var currentSearchMatchIndex: Int?
    var hoveredLink: TerminalSelection?
}
