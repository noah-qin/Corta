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

/// Decorates the native tab title through the public NSWindowTab API.
/// AppKit owns the tab background, close button and drag behaviour.
enum TabIcon {
    static let side: CGFloat = 16

    private static let image: NSImage? = {
        guard let image = NSImage(named: "TerminalTabIcon")?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: side, height: side)
        image.isTemplate = false
        image.accessibilityDescription = nil
        return image
    }()

    /// Reuses the chosen artwork, drawing back to front at native tab height.
    private static let stackedImage: NSImage? = {
        guard let image else { return nil }
        let stack = NSImage(size: NSSize(width: 24, height: side), flipped: false) { _ in
            image.draw(in: NSRect(x: 8, y: 1, width: 16, height: 14))
            image.draw(in: NSRect(x: 4, y: 0, width: 16, height: 16))
            image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        stack.isTemplate = false
        stack.accessibilityDescription = nil
        return stack
    }()

    static func apply(to window: NSWindow) {
        window.tab.title = window.title
        let isSplit = (window.contentViewController as? SplitViewController)?.panes.count ?? 1 > 1
        window.tab.attributedTitle = title(window.title, isSplit: isSplit)
    }

    private static func title(_ title: String, isSplit: Bool) -> NSAttributedString {
        guard let image = isSplit ? stackedImage : image else { return NSAttributedString(string: title) }
        let attachment = NSTextAttachment()
        attachment.image = image
        // Align the icon to the small system font's visual centre.
        attachment.bounds = NSRect(x: 0, y: -4, width: image.size.width, height: side)
        let result = NSMutableAttributedString(attachment: attachment)
        result.append(NSAttributedString(string: "  " + title))
        return result
    }
}
