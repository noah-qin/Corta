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

/// A bare symbol in the titlebar row that answers the pointer: a soft
/// round ground under it on hover, a deeper one while pressed — as the
/// tabs beside it do. A borderless toolbar item gives no hover at all.
final class TitlebarButton: NSButton {
    static let side: CGFloat = 28
    private var hovering = false {
        didSet {
            contentTintColor = hovering ? .labelColor : .secondaryLabelColor
            needsDisplay = true
        }
    }

    init(symbol: String, label: String, target: AnyObject?, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = .secondaryLabelColor
        self.target = target
        self.action = action
        toolTip = label
        setAccessibilityLabel(label)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isHighlighted ? 0.12 : hovering ? 0.07 : 0
        if alpha > 0 {
            NSColor.labelColor.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
        super.draw(dirtyRect)
    }
}
