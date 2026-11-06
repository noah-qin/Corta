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

/// Drives the divider rather than scaling a Metal layer: glyphs keep their
/// native size. The child PTYs receive only the settled grid, not spring samples.
@MainActor
final class SplitTransition {
    private var timer: Timer?
    private weak var node: NSSplitView?
    private var destination: CGFloat = 0
    private var completion: (() -> Void)?
    private weak var revealedView: NSView?
    private var revealMask: CALayer?
    private(set) var isRunning = false

    func start(node: NSSplitView, from start: CGFloat, to end: CGFloat,
               revealing view: NSView? = nil, collapsing: Bool = false, completion: @escaping () -> Void) {
        finish()
        installReveal(on: view, vertical: node.isVertical)
        self.node = node
        destination = end
        self.completion = completion
        isRunning = true
        let dividerThickness = node.dividerThickness
        let began = ProcessInfo.processInfo.systemUptime
        node.setPosition(start, ofDividerAt: 0)
        let timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] timer in
            guard self != nil else { timer.invalidate(); return }
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let node = self.node else { self.finish(); return }
                let elapsed = ProcessInfo.processInfo.systemUptime - began
                guard elapsed < 0.36, node.window != nil, !node.inLiveResize else {
                    self.finish()
                    return
                }
                let progress: Double
                if collapsing {
                    // A critically damped spring: overshooting a zero-sized
                    // pane hits AppKit's clamp and then visibly bounces back.
                    let response = 1 - exp(-24 * elapsed) * (1 + 24 * elapsed)
                    let settled = 1 - exp(-24 * 0.36) * (1 + 24 * 0.36)
                    progress = min(1, response / settled)
                    (node as? PaneSplitView)?.transitionDividerThickness = dividerThickness * (1 - progress)
                    node.needsDisplay = true
                } else {
                    progress = 1 - exp(-18 * elapsed) * (cos(23 * elapsed) + 18 / 23 * sin(23 * elapsed))
                }
                node.setPosition(start + (end - start) * progress, ofDividerAt: 0)
                node.layoutSubtreeIfNeeded()
                self.updateReveal(progress: progress, vertical: node.isVertical)
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func installReveal(on view: NSView?, vertical: Bool) {
        guard let view, let layer = view.layer else { return }
        revealedView = view
        let mask = CALayer()
        mask.backgroundColor = NSColor.black.cgColor
        layer.mask = mask
        revealMask = mask
        updateReveal(progress: 0, vertical: vertical)
        let spring = CASpringAnimation(keyPath: vertical ? "transform.translation.x" : "transform.translation.y")
        spring.fromValue = vertical ? 10 : -10
        spring.toValue = 0
        spring.mass = 1
        spring.stiffness = 850
        spring.damping = 36
        spring.duration = 0.36
        layer.add(spring, forKey: "corta.split.enter")
    }

    private func updateReveal(progress: Double, vertical: Bool) {
        guard let view = revealedView, let mask = revealMask else { return }
        let amount = CGFloat(min(1, max(0, progress)))
        let bounds = view.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = vertical
            ? NSRect(x: 0, y: 0, width: bounds.width * amount, height: bounds.height)
            : NSRect(x: 0, y: bounds.height * (1 - amount), width: bounds.width, height: bounds.height * amount)
        CATransaction.commit()
    }

    /// Settle before another structural command; stale callbacks cannot touch
    /// a closed split or overwrite a newer layout.
    func finish() {
        guard isRunning else { return }
        timer?.invalidate()
        timer = nil
        let settledNode = node
        if let split = settledNode as? PaneSplitView, split.transitionDividerThickness != nil {
            split.transitionDividerThickness = 0
        }
        settledNode?.setPosition(destination, ofDividerAt: 0)
        node = nil
        if revealedView?.layer?.mask === revealMask { revealedView?.layer?.mask = nil }
        revealedView?.layer?.removeAnimation(forKey: "corta.split.enter")
        revealedView = nil
        revealMask = nil
        isRunning = false
        let callback = completion
        completion = nil
        callback?()
        (settledNode as? PaneSplitView)?.transitionDividerThickness = nil
    }
}
