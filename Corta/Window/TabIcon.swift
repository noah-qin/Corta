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

/// What a tab shows in Corta's strip (D30): the focused pane's program in
/// front of the others', its name or the user's, and where it is.
enum TabIcon {
    static let side: CGFloat = 20
    /// Each card behind turns this much further, about a point this many
    /// card heights below the stack, and needs this much more width.
    private static let fanAngle: CGFloat = 8
    private static let fanPivotDepth: CGFloat = 1.1
    private static let fanStep: CGFloat = 8
    /// Room around the stack for the turned cards' corners.
    private static let margin: CGFloat = 3
    private static var compositions: [String: NSImage] = [:]

    static func item(for tab: TerminalTab) -> TabStripItem {
        let split = tab.split
        let focused = split.focusedPane
        let label = focused?.windowTitle.tabLabel
            ?? ProgramTabLabel(icon: .terminal, name: "Corta", context: "")
        let custom = tab.customTitle
        let name = custom ?? label.name
        let context = custom == nil ? label.context : ""
        // The focused program leads the stack; another branded program is
        // visible behind it even when a shell pane currently has the keyboard.
        let others = split.panes.filter { $0 !== focused }
            .map { $0.windowTitle.tabLabel.icon }
            .sorted { $0 != .terminal && $1 == .terminal }
        let programs = Array(([label.icon] + others).prefix(3))
        let full = focused?.windowTitle.composed ?? name
        return TabStripItem(
            id: tab.id, programs: programs, name: name, context: context,
            toolTip: full, status: tab.agentStatus, progress: tab.agentProgress)
    }

    static func image(for programs: [ProgramIcon]) -> NSImage? {
        guard let first = programs.first else { return nil }
        let key = programs.map(\.rawValue).joined(separator: ",")
        if let cached = compositions[key] { return cached }
        guard let lead = first.tabImage else { return nil }
        let images = programs.map { $0.tabImage ?? lead }
        let tile = ProgramIcon.tileSize
        let cardSize = NSSize(width: tile.width + 2, height: tile.height + 2)
        // Like a hand of playing cards: each card behind turns a few degrees
        // further about a point well below the stack, so it fans out from
        // behind the front card's right edge.
        let width = cardSize.width + CGFloat(images.count - 1) * fanStep
        let pad = margin
        let image = NSImage(size: NSSize(width: width + pad * 2, height: side + pad * 2), flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            let offset = NSAffineTransform()
            offset.translateX(by: pad, yBy: pad)
            offset.concat()
            let frame = NSRect(x: 0, y: (side - cardSize.height) / 2,
                               width: cardSize.width, height: cardSize.height)
            let pivot = NSPoint(x: frame.midX, y: frame.minY - frame.height * fanPivotDepth)
            // Drawn in place under the rotation, not rotated as bitmaps,
            // so the turned edges stay smooth.
            for (index, back) in images.dropFirst().enumerated().reversed() {
                NSGraphicsContext.saveGraphicsState()
                let turn = NSAffineTransform()
                turn.translateX(by: pivot.x, yBy: pivot.y)
                turn.rotate(byDegrees: -fanAngle * CGFloat(index + 1))
                turn.translateX(by: -pivot.x, yBy: -pivot.y)
                turn.concat()
                drawCard(back, in: frame, shaded: true)
                NSGraphicsContext.restoreGraphicsState()
            }
            drawCard(images[0], in: frame)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = false
        if compositions.count >= 128 { compositions.removeAll(keepingCapacity: true) }
        compositions[key] = image
        return image
    }

    /// A tile on a white rim, one point wide. Tile and rim are cut from one
    /// radius, so their corners are concentric. No blurred shadow: at this
    /// size a halo reads as a soft edge. Hairlines draw each edge instead —
    /// inside, where tile meets rim, so a white tile (Codex) has an edge;
    /// outside a card behind, so its rim shows on a white pill. A card
    /// behind is also `shaded`, a little in the front card's shadow.
    private static func drawCard(_ tile: NSImage, in rect: NSRect, shaded: Bool = false) {
        let radius = (rect.height - 2) * 0.27 + 1
        let rim = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor.white.setFill()
        rim.fill()
        let inner = rect.insetBy(dx: 1, dy: 1)
        let face = NSBezierPath(roundedRect: inner, xRadius: radius - 1, yRadius: radius - 1)
        NSGraphicsContext.saveGraphicsState()
        face.addClip()
        tile.draw(in: inner)
        if shaded {
            NSColor.black.withAlphaComponent(0.1).setFill()
            inner.fill(using: .sourceAtop)
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.12).setStroke()
        face.lineWidth = 0.5
        face.stroke()
        if shaded {
            let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25),
                                    xRadius: radius - 0.25, yRadius: radius - 0.25)
            edge.lineWidth = 0.5
            NSColor.black.withAlphaComponent(0.2).setStroke()
            edge.stroke()
        }
    }
}
