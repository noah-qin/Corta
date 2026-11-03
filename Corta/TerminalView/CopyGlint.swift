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

/// The copy confirmation: a soft band of light sweeps once along the copied
/// cells, left to right, and is gone. Drawn over the canvas in its own
/// layer, never into the grid; it takes no clicks.
final class CopyGlintView: NSView {
    static let duration: CFTimeInterval = 0.42

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Sweeps along `rects` (in the terminal view's coordinates, one per
    /// visible row of the copy), then removes itself. With Reduce Motion the
    /// light does not travel; it brightens once in place.
    static func show(over host: NSView, rects: [CGRect]) {
        guard !rects.isEmpty else { return }
        host.subviews.filter { $0 is CopyGlintView }.forEach { $0.removeFromSuperview() }
        let glint = CopyGlintView(frame: host.bounds)
        glint.autoresizingMask = [.width, .height]
        glint.wantsLayer = true
        host.addSubview(glint)
        glint.run(rects: rects)
    }

    private func run(rects: [CGRect]) {
        guard let layer else { return }
        let area = rects.reduce(rects[0]) { $0.union($1) }
        let mask = CAShapeLayer()
        let path = CGMutablePath()
        for rect in rects {
            path.addRoundedRect(in: rect.insetBy(dx: -1, dy: 0), cornerWidth: 2, cornerHeight: 2)
        }
        mask.path = path
        mask.frame = bounds

        let light = CAGradientLayer()
        light.startPoint = CGPoint(x: 0, y: 0.5)
        light.endPoint = CGPoint(x: 1, y: 0.5)
        let white = NSColor.white
        light.colors = [white.withAlphaComponent(0).cgColor, white.withAlphaComponent(0.75).cgColor,
                        white.withAlphaComponent(0).cgColor]
        light.mask = mask
        layer.addSublayer(light)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.removeFromSuperview() }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            flash(light, mask: mask)
        } else {
            sweep(light, mask: mask, across: area)
        }
        CATransaction.commit()
    }

    /// Reduce Motion: the copy brightens once in place and fades.
    private func flash(_ light: CAGradientLayer, mask: CAShapeLayer) {
        let white = NSColor.white
        light.frame = bounds
        light.colors = [white.withAlphaComponent(0.45).cgColor, white.withAlphaComponent(0.45).cgColor]
        mask.frame = light.bounds
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = Self.duration
        light.opacity = 0
        light.add(fade, forKey: "corta.copy.flash")
    }

    /// A band a third as wide as the copy (at least a few cells), travelling
    /// from just before it to just past it. The mask stays on the text while
    /// the band moves, so it holds still in the band's own coordinates by
    /// moving the opposite way.
    private func sweep(_ light: CAGradientLayer, mask: CAShapeLayer, across area: CGRect) {
        let band = max(area.width / 3, 48)
        light.frame = CGRect(x: area.minX - band, y: 0, width: band, height: bounds.height)
        mask.frame = CGRect(x: -light.frame.minX, y: 0, width: bounds.width, height: bounds.height)
        let travel = area.width + band
        let lightStart = light.position.x
        let maskStart = mask.position.x
        let timing = CAMediaTimingFunction(name: .easeInEaseOut)
        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = lightStart
        move.toValue = lightStart + travel
        move.duration = Self.duration
        move.timingFunction = timing
        let hold = CABasicAnimation(keyPath: "position.x")
        hold.fromValue = maskStart
        hold.toValue = maskStart - travel
        hold.duration = Self.duration
        hold.timingFunction = timing
        light.position.x = lightStart + travel
        mask.position.x = maskStart - travel
        light.add(move, forKey: "corta.copy.sweep")
        mask.add(hold, forKey: "corta.copy.sweep")
    }
}
