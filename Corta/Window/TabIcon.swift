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
import CoreImage

/// What a tab shows in Corta's strip (D30): the focused pane's program in
/// front of the others', its name or the user's, and where it is.
enum TabIcon {
    static let side: CGFloat = 20
    private static let stackStep: CGFloat = 3.5
    private static let shadowPad: CGFloat = 2
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
            programs: programs, name: name, context: context,
            toolTip: full, status: tab.agentStatus, progress: tab.agentProgress)
    }

    static func image(for programs: [ProgramIcon]) -> NSImage? {
        guard let first = programs.first else { return nil }
        let key = programs.map(\.rawValue).joined(separator: ",")
        if let cached = compositions[key] { return cached }
        guard let lead = first.tabImage else { return nil }
        let images = programs.map { $0.tabImage ?? lead }
        let tile = ProgramIcon.tileSize
        let frontSize = NSSize(width: tile.width + 2, height: tile.height + 2)
        let width = frontSize.width + CGFloat(images.count - 1) * stackStep
        // Cards behind the front one are turned away from the viewer, as in
        // a fanned deck seen at an angle: narrower, and shorter at the far
        // edge. Rendered once per composition, which is cached below.
        let backs = images.indices.dropFirst().map { index -> (NSImage, NSRect)? in
            let shrink = CGFloat(index)
            // Nearly full height: the cards stand close behind the front one.
            let size = NSSize(width: tile.width - shrink * 2 / 3, height: tile.height - shrink / 2)
            guard let card = tilted(card(images[index], size: size, squash: tiltWidth)) else { return nil }
            let right = frontSize.width + CGFloat(index) * stackStep
            let frame = NSRect(x: right - card.size.width, y: (side - card.size.height) / 2,
                               width: card.size.width, height: card.size.height)
            return (card, frame)
        }
        let front = card(images[0], size: tile)
        // Room on every side for the shadow, which a tight bound cut off
        // into a hard edge.
        let pad = shadowPad
        let image = NSImage(size: NSSize(width: width + pad * 2, height: side + pad * 2), flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            let offset = NSAffineTransform()
            offset.translateX(by: pad, yBy: pad)
            offset.concat()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = 1.5
            shadow.shadowOffset = NSSize(width: 0.5, height: -0.5)
            shadow.set()
            for case let (back, frame)? in backs.reversed() { back.draw(in: frame) }
            front.draw(in: NSRect(x: 0, y: (side - front.size.height) / 2,
                                  width: front.size.width, height: front.size.height))
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = false
        if compositions.count >= 128 { compositions.removeAll(keepingCapacity: true) }
        compositions[key] = image
        return image
    }

    /// How wide a turned card is drawn, as a share of its width.
    private static let tiltWidth: CGFloat = 0.4

    /// A tile on a white rim, one point wider on every side. A card that
    /// will be squashed to `squash` of its width is drawn with corners
    /// stretched by the inverse, so they come out round, not clipped.
    private static func card(_ tile: NSImage, size: NSSize, squash: CGFloat = 1) -> NSImage {
        let outer = NSSize(width: size.width + 2, height: size.height + 2)
        let image = NSImage(size: outer, flipped: false) { rect in
            // One radius for both: the tile's corner is the rim's less the
            // rim's width, so the two curves are concentric.
            let radius = size.height * 0.27 + 1
            let rim = NSBezierPath(roundedRect: rect, xRadius: min(rect.width / 2, radius / squash),
                                   yRadius: radius)
            NSColor.white.setFill()
            rim.fill()
            let inner = rect.insetBy(dx: 1, dy: 1)
            let face = NSBezierPath(roundedRect: inner, xRadius: min(inner.width / 2, (radius - 1) / squash),
                                    yRadius: radius - 1)
            NSGraphicsContext.saveGraphicsState()
            face.addClip()
            tile.draw(in: inner)
            NSGraphicsContext.restoreGraphicsState()
            // A hairline where tile meets rim, so a white tile (Codex) still
            // has an edge.
            NSColor.black.withAlphaComponent(0.1).setStroke()
            face.lineWidth = 0.5
            face.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// `card` turned about its leading edge: 40% as wide, its far edge 74%
    /// as tall. Core Image's perspective transform, on a 4× raster.
    private static func tilted(_ card: NSImage) -> NSImage? {
        let scale: CGFloat = 4
        let pixelsWide = Int((card.size.width * scale).rounded())
        let pixelsHigh = Int((card.size.height * scale).rounded())
        guard pixelsWide > 0, pixelsHigh > 0,
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        card.draw(in: NSRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        NSGraphicsContext.restoreGraphicsState()
        guard let source = bitmap.cgImage else { return nil }
        let height = CGFloat(pixelsHigh)
        let width = (CGFloat(pixelsWide) * tiltWidth).rounded()
        let inset = height * 0.08
        let filter = CIFilter(name: "CIPerspectiveTransform")
        filter?.setValue(CIImage(cgImage: source), forKey: kCIInputImageKey)
        filter?.setValue(CIVector(x: 0, y: height), forKey: "inputTopLeft")
        filter?.setValue(CIVector(x: width, y: height - inset), forKey: "inputTopRight")
        filter?.setValue(CIVector(x: width, y: inset), forKey: "inputBottomRight")
        filter?.setValue(CIVector(x: 0, y: 0), forKey: "inputBottomLeft")
        guard let output = filter?.outputImage,
              let result = CIContext().createCGImage(
                output, from: CGRect(x: 0, y: 0, width: width, height: height)) else { return nil }
        let image = NSImage(cgImage: result, size: NSSize(width: width / scale, height: height / scale))
        image.isTemplate = false
        return image
    }
}
