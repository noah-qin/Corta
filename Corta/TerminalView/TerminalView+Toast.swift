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
import Metal
import QuartzCore

// MARK: - Transient confirmation

extension TerminalView {

    /// A short-lived label in the pane's bottom-right corner ("Copied"),
    /// mainly so copy-on-select is never silent.
    ///
    /// A `CALayer`, since this view is layer-hosting; it never costs the
    /// Metal render loop a frame. `kind` sets symbol and fill: icon, word and
    /// colour, in that order, so hue is never the only signal.
    enum ToastKind {
        case confirmation
        case warning

        var symbolName: String {
            switch self {
            case .confirmation: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            }
        }

        var fill: NSColor {
            switch self {
            // Not a theme colour, which could vanish into the screen; not
            // `controlAccentColor`, which can be grey.
            case .confirmation: NSColor.systemBlue.withAlphaComponent(0.92)
            case .warning: NSColor.systemOrange.withAlphaComponent(0.94)
            }
        }
    }

    /// The toast's capsule — fill, rim, shadow — with the kind's symbol at
    /// its leading edge; the caller adds the text.
    private static func toastCapsule(
        size: CGSize, kind: ToastKind, font: NSFont, symbolSide: CGFloat, scale: CGFloat
    ) -> CALayer {
        let capsule = CALayer()
        capsule.bounds = CGRect(origin: .zero, size: size)
        capsule.anchorPoint = .zero
        capsule.cornerRadius = size.height / 2
        capsule.contentsScale = scale
        capsule.backgroundColor = kind.fill.cgColor
        capsule.borderColor = NSColor.white.withAlphaComponent(
            SystemAccessibility.increaseContrast ? 0.85 : 0.22
        ).cgColor
        capsule.borderWidth = 1
        capsule.shadowColor = NSColor.black.cgColor
        capsule.shadowOpacity = 0.28
        capsule.shadowRadius = 6
        capsule.shadowOffset = CGSize(width: 0, height: 1)
        if let symbol = NSImage(
            systemSymbolName: kind.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                .init(pointSize: font.pointSize + 1, weight: .semibold)
                    .applying(.init(paletteColors: [.white])))
        {
            let icon = CALayer()
            icon.frame = CGRect(
                x: Self.toastPadding.width,
                y: ((size.height - symbolSide) / 2).rounded(),
                width: symbolSide, height: symbolSide)
            icon.contentsScale = scale
            icon.contents = symbol.layerContents(forContentsScale: scale)
            icon.contentsGravity = .resizeAspect
            capsule.addSublayer(icon)
        }
        return capsule
    }

    func showToast(_ text: String, kind: ToastKind = .confirmation) {
        toastDismissal?.cancel()
        toastLayer?.removeFromSuperlayer()

        let scale = window?.backingScaleFactor ?? 2
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let label = CATextLayer()
        label.string = NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: NSColor.white])
        label.contentsScale = scale
        label.alignmentMode = .left

        let symbolSide = (font.pointSize + 3).rounded(.up)
        let symbolGap: CGFloat = 5
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let size = CGSize(
            width: (textSize.width).rounded(.up) + symbolSide + symbolGap
                + 2 * Self.toastPadding.width,
            height: max(symbolSide, textSize.height.rounded(.up))
                + 2 * Self.toastPadding.height)

        let capsule = Self.toastCapsule(size: size, kind: kind, font: font, symbolSide: symbolSide, scale: scale)
        label.frame = CGRect(
            x: Self.toastPadding.width + symbolSide + symbolGap,
            y: (size.height - textSize.height).rounded() / 2,
            width: textSize.width.rounded(.up) + 1, height: textSize.height.rounded(.up))
        capsule.addSublayer(label)

        layer?.addSublayer(capsule)
        toastLayer = capsule
        positionToast()

        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0.0
        appear.toValue = 1.0
        appear.duration = SystemAccessibility.duration(0.12)
        capsule.add(appear, forKey: "appear")

        // A cancellable work item leaves nothing behind if the pane goes.
        let dismissal = DispatchWorkItem { [weak self] in self?.dismissToast() }
        toastDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.toastDuration, execute: dismissal)
    }

    private func dismissToast() {
        guard let capsule = toastLayer else { return }
        toastLayer = nil
        toastDismissal = nil
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        fade.duration = SystemAccessibility.duration(0.25)
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { capsule.removeFromSuperlayer() }
        capsule.opacity = 0
        capsule.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    /// Bottom-right inside the text inset; flipped, so bottom is `maxY`.
    /// Re-run from `layout()` so a resize never strands it.
    func positionToast() {
        guard let capsule = toastLayer else { return }
        let size = capsule.bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        capsule.position = CGPoint(
            x: bounds.maxX - size.width - TerminalLayout.insets.right,
            y: bounds.maxY - size.height - TerminalLayout.insets.bottom)
        CATransaction.commit()
    }

    private static let toastDuration: TimeInterval = 1.1
    private static let toastPadding = CGSize(width: 10, height: 5)
}
