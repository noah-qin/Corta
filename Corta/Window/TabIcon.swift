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

/// AppKit keeps ownership of selection, close buttons, dragging and renaming.
/// Only the tab's public attributed title is decorated here.
enum TabIcon {
    static let side: CGFloat = 20
    private static let stackStep: CGFloat = 7
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
        let image = NSImage(size: NSSize(width: width, height: side), flipped: false) { _ in
            // Back to front, like cards in a hand: every card behind is a
            // whole tile, a little smaller and further right. A white rim and
            // a soft shadow lift each card off the one behind it, so the
            // stack reads as a stack and the focused program in front is
            // unmistakable.
            for index in images.indices.reversed() {
                let size = side - 2 - CGFloat(index) * 1.5
                let frame = NSRect(x: 1 + CGFloat(index) * stackStep,
                                   y: (side - size) / 2, width: size, height: size)
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
                shadow.shadowBlurRadius = 1.5
                shadow.shadowOffset = NSSize(width: -0.5, height: -0.5)
                shadow.set()
                NSColor.white.setFill()
                let radius = size * 0.27
                NSBezierPath(roundedRect: frame.insetBy(dx: -1, dy: -1),
                             xRadius: radius + 1, yRadius: radius + 1).fill()
                NSGraphicsContext.restoreGraphicsState()
                images[index].draw(in: frame)
            }
            return true
        }
        image.isTemplate = false
        if compositions.count >= 128 { compositions.removeAll(keepingCapacity: true) }
        compositions[key] = image
        return image
    }
}
