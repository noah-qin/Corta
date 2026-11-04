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

import AppKit

/// Every terminal is an inset island, including a tab containing only one pane.
final class PaneSurfaceView: NSView {
    static let margin: CGFloat = 7
    static let gap: CGFloat = 8
    /// Concentric with the window's corner: its radius less the margin.
    static let radius: CGFloat = TerminalLayout.windowCornerRadius - margin

    static var canvasColor: NSColor {
        let color = TerminalColorPalette.defaultBackground
        return NSColor(srgbRed: CGFloat(color.x), green: CGFloat(color.y),
                       blue: CGFloat(color.z), alpha: 1)
    }

    static var gutterColor: NSColor {
        let color = canvasColor
        let light = color.redComponent + color.greenComponent + color.blueComponent > 1.5
        // The window's ground: a clear step darker than the cards on it, so
        // band, gaps and cards read as layers rather than one flat sheet.
        return color.blended(withFraction: light ? 0.045 : 0.22, of: .black) ?? color
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = Self.radius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        refreshAppearance()
    }

    func refreshAppearance() {
        let canvas = Self.canvasColor
        layer?.backgroundColor = canvas.cgColor
        let light = canvas.redComponent + canvas.greenComponent + canvas.blueComponent > 1.5
        layer?.borderColor = (light ? NSColor.black : .white).withAlphaComponent(0.1).cgColor
    }
}
