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

/// AppKit keeps ownership of selection, close buttons, dragging and renaming.
/// Only the tab's public attributed title is decorated here.
enum TabIcon {
    static let side: CGFloat = 20
    private static let stackStep: CGFloat = 5
    private static var compositions: [String: NSImage] = [:]
    private static let signatures = NSMapTable<NSWindow, NSString>.weakToStrongObjects()

    static func apply(to window: NSWindow) {
        let split = window.contentViewController as? SplitViewController
        let focused = split?.focusedPane
        let label = focused?.windowTitle.tabLabel
            ?? ProgramTabLabel(icon: .terminal, name: window.title, context: "")
        let custom = (window.windowController as? TerminalWindowController)?.customTabTitle
        let name = custom ?? label.name
        let context = custom == nil ? label.context : ""
        let text = context.isEmpty ? name : name + " " + context
        // The focused program leads the stack; another branded program is
        // visible behind it even when a shell pane currently has the keyboard.
        let others = (split?.panes ?? []).filter { $0 !== focused }
            .map { $0.windowTitle.tabLabel.icon }
            .sorted { $0 != .terminal && $1 == .terminal }
        let programs = Array(([label.icon] + others).prefix(3))
        let signature = programs.map(\.rawValue).joined(separator: ",") + "|" + text
        if signatures.object(forKey: window) as String? == signature,
           window.tab.title == text, window.tab.attributedTitle != nil { return }
        signatures.setObject(signature as NSString, forKey: window)
        window.tab.title = text
        let result = NSMutableAttributedString(string: "")
        if let image = image(for: programs) {
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: -5, width: image.size.width, height: side)
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: " "))
        }
        result.append(NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5),
            .foregroundColor: NSColor.labelColor,
        ]))
        if !context.isEmpty {
            result.append(NSAttributedString(string: " " + context, attributes: [
                .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        }
        window.tab.attributedTitle = result
    }

    static func image(for programs: [ProgramIcon]) -> NSImage? {
        guard let first = programs.first else { return nil }
        let key = programs.map(\.rawValue).joined(separator: ",")
        if let cached = compositions[key] { return cached }
        guard let lead = first.tabImage else { return nil }
        let images = programs.map { $0.tabImage ?? lead }
        let width = side + CGFloat(images.count - 1) * stackStep
        // Cards behind the front one are turned away from the viewer, as in
        // a fanned deck seen at an angle: narrower, and shorter at the far
        // edge. Rendered once per composition, which is cached below.
        let backs = images.indices.dropFirst().map { index -> (NSImage, NSRect)? in
            let size = side - 2 - CGFloat(index)
            guard let card = tilted(card(images[index], size: size)) else { return nil }
            let right = side + CGFloat(index) * stackStep
            let frame = NSRect(x: right - card.size.width, y: (side - card.size.height) / 2,
                               width: card.size.width, height: card.size.height)
            return (card, frame)
        }
        let front = card(images[0], size: side - 2)
        let image = NSImage(size: NSSize(width: width, height: side), flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = 1.5
            shadow.shadowOffset = NSSize(width: 0.5, height: -0.5)
            shadow.set()
            for case let (back, frame)? in backs.reversed() { back.draw(in: frame) }
            front.draw(in: NSRect(x: 0, y: 0, width: front.size.width, height: front.size.height))
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = false
        if compositions.count >= 128 { compositions.removeAll(keepingCapacity: true) }
        compositions[key] = image
        return image
    }

    /// A tile on a white rim, one point wider on every side.
    private static func card(_ tile: NSImage, size: CGFloat) -> NSImage {
        let outer = size + 2
        let image = NSImage(size: NSSize(width: outer, height: outer), flipped: false) { rect in
            let radius = size * 0.27 + 1
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            tile.draw(in: rect.insetBy(dx: 1, dy: 1))
            return true
        }
        image.isTemplate = false
        return image
    }

    /// `card` turned about its leading edge: 62% as wide, its far edge 74%
    /// as tall. Core Image's perspective transform, on a 4× raster.
    private static func tilted(_ card: NSImage) -> NSImage? {
        let scale: CGFloat = 4
        let pixels = Int((card.size.width * scale).rounded())
        guard pixels > 0,
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        card.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        guard let source = bitmap.cgImage else { return nil }
        let side = CGFloat(pixels)
        let width = (side * 0.62).rounded()
        let inset = side * 0.13
        let filter = CIFilter(name: "CIPerspectiveTransform")
        filter?.setValue(CIImage(cgImage: source), forKey: kCIInputImageKey)
        filter?.setValue(CIVector(x: 0, y: side), forKey: "inputTopLeft")
        filter?.setValue(CIVector(x: width, y: side - inset), forKey: "inputTopRight")
        filter?.setValue(CIVector(x: width, y: inset), forKey: "inputBottomRight")
        filter?.setValue(CIVector(x: 0, y: 0), forKey: "inputBottomLeft")
        guard let output = filter?.outputImage,
              let result = CIContext().createCGImage(
                output, from: CGRect(x: 0, y: 0, width: width, height: side)) else { return nil }
        let image = NSImage(cgImage: result, size: NSSize(width: width / scale, height: side / scale))
        image.isTemplate = false
        return image
    }
}
