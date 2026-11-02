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
    static let side: CGFloat = 18
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
        let text = context.isEmpty ? name : name + "  " + context
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
            attachment.bounds = NSRect(x: 0, y: -4, width: image.size.width, height: side)
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: "  "))
        }
        result.append(NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]))
        if !context.isEmpty {
            result.append(NSAttributedString(string: "  " + context, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        window.tab.attributedTitle = result
    }

    static func image(for programs: [ProgramIcon]) -> NSImage? {
        guard let first = programs.first else { return nil }
        let key = programs.map(\.rawValue).joined(separator: ",")
        if let cached = compositions[key] { return cached }
        guard let lead = first.tabImage else { return nil }
        let width = side + (programs.count > 1 ? 8 : 0)
        let images = programs.map { $0.tabImage ?? lead }
        let image = NSImage(size: NSSize(width: width, height: side), flipped: false) { _ in
            for index in images.indices.reversed() {
                let offset = CGFloat(index) * 4
                let height = side - CGFloat(index)
                // Opaque tile edges separate the stacked brands at small sizes.
                images[index].draw(in: NSRect(x: offset, y: CGFloat(index) / 2,
                                             width: side, height: height))
            }
            return true
        }
        image.isTemplate = false
        if compositions.count >= 128 { compositions.removeAll(keepingCapacity: true) }
        compositions[key] = image
        return image
    }
}
