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

/// The compositing blockers the #285 spike can remove while a window is full
/// screen with exactly one pane (`CORTA_DIRECT_FULLSCREEN`). Each is one
/// suspected reason the window server composites the canvas instead of
/// presenting it directly; removing them one at a time is how the spike finds
/// which ones matter. Empty — every shipped launch — changes nothing.
nonisolated struct DirectFullScreen: OptionSet, Sendable {
    let rawValue: Int

    /// The toolbar and menu bar auto-hide in full screen.
    static let toolbar = DirectFullScreen(rawValue: 1 << 0)
    /// The canvas layer drops its rounded-corner mask.
    static let mask = DirectFullScreen(rawValue: 1 << 1)
    /// AppKit views above the canvas, and the status bar, are hidden.
    static let overlays = DirectFullScreen(rawValue: 1 << 2)
    /// The layer is tagged with the screen's colour space. The spike does not
    /// convert colours, so they render off while this is set.
    static let colorspace = DirectFullScreen(rawValue: 1 << 3)

    static let all: DirectFullScreen = [.toolbar, .mask, .overlays, .colorspace]

    init(rawValue: Int) { self.rawValue = rawValue }

    init?(name: String) {
        switch name {
        case "toolbar": self = .toolbar
        case "mask": self = .mask
        case "overlays": self = .overlays
        case "colorspace": self = .colorspace
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
