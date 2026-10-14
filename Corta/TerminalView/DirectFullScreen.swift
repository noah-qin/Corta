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

/// What a full-screen window with exactly one pane changes so the window
/// server can present its canvas directly instead of compositing it — a
/// frame less from keypress to glass (#285, `PERFORMANCE.md` §5.17).
///
/// `shipped` is what every launch does, and changes nothing visible. The
/// rest are #285's measured non-blockers, kept for a trace to re-check
/// (`CORTA_DIRECT_FULLSCREEN`, Debug / Benchmark only).
nonisolated struct DirectFullScreen: OptionSet, Sendable {
    let rawValue: Int

    /// Experimental: the toolbar and menu bar auto-hide in full screen.
    static let toolbar = DirectFullScreen(rawValue: 1 << 0)
    /// The canvas layer drops its rounded-corner mask; full screen has no
    /// rounded corners to follow, and a masked layer is composited.
    static let mask = DirectFullScreen(rawValue: 1 << 1)
    /// Experimental: AppKit views above the canvas, and the status bar, are hidden.
    static let overlays = DirectFullScreen(rawValue: 1 << 2)
    /// Experimental: the layer is tagged with the screen's colour space.
    /// Colours are not converted, so they render off while this is set.
    static let colorspace = DirectFullScreen(rawValue: 1 << 3)

    /// Frames render off-screen through Metal 4 and are copied into the
    /// drawable and presented by a classic queue: a drawable a Metal 4
    /// command buffer wrote is never presented directly.
    static let present = DirectFullScreen(rawValue: 1 << 4)

    static let shipped: DirectFullScreen = [.mask, .present]

    static let all: DirectFullScreen = [.toolbar, .mask, .overlays, .colorspace, .present]

    init(rawValue: Int) { self.rawValue = rawValue }

    init?(name: String) {
        switch name {
        case "toolbar": self = .toolbar
        case "mask": self = .mask
        case "overlays": self = .overlays
        case "colorspace": self = .colorspace
        case "present": self = .present
        default: return nil
        }
    }

    /// Read once: the launch environment does not change.
    @MainActor static let requested = DiagnosticsEnvironment.directFullScreen()

    /// The blockers to remove for a window in this state: none unless it is
    /// full screen with exactly one pane.
    func active(isFullScreen: Bool, paneCount: Int) -> DirectFullScreen {
        isFullScreen && paneCount == 1 ? self : []
    }
}
