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
import QuartzCore
import Testing

@testable import Corta

/// The canvas a pane draws into: an opaque layer in the theme's background,
/// so nothing behind the window shows before the first frame, during a
/// resize or across a theme change, and a link that ticks exactly as long
/// as there is something to show.
@MainActor
@Suite("CanvasPresent")
struct CanvasPresentTests {
    private static func themeBackground() -> CGColor {
        let bg = TerminalColorPalette.defaultBackground
        return CGColor(srgbRed: CGFloat(bg.x), green: CGFloat(bg.y), blue: CGFloat(bg.z), alpha: 1)
    }

    /// The window shows its first frame a vsync after it orders front; what
    /// fills that gap is the layer's own colour. Opaque and the theme's —
    /// before, a transparent layer and window showed the desktop there.
    @Test func theCanvasIsOpaqueInTheThemeBackgroundBeforeAnyFrame() throws {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let layer = try #require(view.layer as? CAMetalLayer)
        #expect(layer.isOpaque)
        #expect(layer.backgroundColor == Self.themeBackground())
    }

    /// Found by watching a window go fullscreen: the text grew for the
    /// length of the animation and snapped back afterwards.
    ///
    /// Core Animation implicitly animates a layer's bounds and scales its
    /// contents to fit while it does, so the previous frame is drawn
    /// magnified until a new one lands — and asking for that frame does not
    /// help, because it arrives into a layer whose bounds are still
    /// animating. The canvas must not animate its geometry at all, and must
    /// pin rather than stretch what it is holding.
    @Test func theCanvasNeitherAnimatesNorStretchesItsGeometry() throws {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let layer = try #require(view.layer as? CAMetalLayer)
        // The dictionary, not `action(forKey:)`: that resolves an `NSNull`
        // entry to nil, so it cannot tell "explicitly no animation" from
        // "nothing configured, ask the delegate".
        let actions = try #require(layer.actions)
        for key in ["bounds", "position", "contentsScale"] {
            #expect(
                actions[key] is NSNull,
                "\(key) must not animate on the terminal canvas")
        }
        // `layerContentsPlacement`, not `contentsGravity`: AppKit owns the
        // layer's gravity for a layer-hosting view and derives it from this,
        // overwriting a direct assignment. Its default,
        // `.scaleAxesIndependently`, is what stretched the last frame over
        // the whole of a window zoom.
        #expect(view.layerContentsPlacement == .topLeft)
        #expect(view.layerContentsRedrawPolicy == .onSetNeedsDisplay)
        // Whatever corner AppKit resolves that to, it must not be the one
        // that scales.
        #expect(layer.contentsGravity != .resize)
        #expect(layer.contentsGravity != .resizeAspect)
        #expect(layer.contentsGravity != .resizeAspectFill)
    }

    /// Found by resizing a window and watching the text scale with it.
    ///
    /// `CAMetalLayer` stretches the frame it is holding when its bounds
    /// change, so a resize with no new frame drawn into it shows the previous
    /// frame at the wrong size — through a fullscreen animation the glyphs
    /// visibly grow and shrink and only come back when something else asks
    /// for a frame. The grid has not changed, so the damage diff has nothing
    /// to report; the request has to come from the size change itself.
    @Test func aResizedDrawableAsksForAFrame() {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        // Lay out once first, so the drawable already has its initial size.
        // Without this the test passes on the 0 → initial transition alone,
        // and the bug is about resizing a layer that is *already* holding a
        // frame.
        view.layoutSubtreeIfNeeded()
        var requests = 0
        view.onDrawableSizeChange = { requests += 1 }

        view.setBoundsSize(NSSize(width: 400, height: 300))
        view.layoutSubtreeIfNeeded()
        #expect(requests >= 1, "a changed drawable size must ask for a frame")

        // And only when it actually changed: layout runs far more often than
        // the size changes, and forcing a frame each time would defeat the
        // damage tracking the render loop is built on.
        let afterResize = requests
        view.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        #expect(requests == afterResize, "an unchanged size must not force a frame")
    }

    @Test func drawNowSizesTheDrawableAfterAResize() throws {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.drawNow()
        view.setBoundsSize(NSSize(width: 400, height: 300))
        view.drawNow()
        let layer = try #require(view.layer as? CAMetalLayer)
        #expect(layer.backgroundColor == Self.themeBackground())
        // No window, so the backing scale is 1 and points are pixels.
        #expect(layer.drawableSize == CGSize(width: 400, height: 300))
    }

    /// A frame the backend dropped showed a stale drawable, and the damage
    /// it carried was already taken — so the link must keep ticking until a
    /// frame draws, or the pane stays stale until the next output.
    @Test func aDroppedFrameKeepsTheLinkTickingUntilOneDraws() {
        #expect(!FrameScheduler.mayPause(stillPending: false, drawn: false))
        #expect(FrameScheduler.mayPause(stillPending: false, drawn: true))
        #expect(!FrameScheduler.mayPause(stillPending: true, drawn: true))
    }
    @Test func echoGateRespectsWindowPauseAndRefreshInterval() {
        #expect(FrameScheduler.mayPresentEcho(now: 10, lastInput: 9.96, lastPresent: nil, maximumFPS: 60, isPaused: true))
        #expect(!FrameScheduler.mayPresentEcho(now: 10, lastInput: 9.94, lastPresent: nil, maximumFPS: 60, isPaused: true))
        #expect(!FrameScheduler.mayPresentEcho(now: 10, lastInput: 10.01, lastPresent: nil, maximumFPS: 60, isPaused: true))
        #expect(!FrameScheduler.mayPresentEcho(now: 10, lastInput: nil, lastPresent: nil, maximumFPS: 60, isPaused: true))
        #expect(!FrameScheduler.mayPresentEcho(now: 10, lastInput: 9.99, lastPresent: 9.99, maximumFPS: 60, isPaused: true))
        #expect(FrameScheduler.mayPresentEcho(now: 10, lastInput: 9.99, lastPresent: 9.99, maximumFPS: 120, isPaused: true))
        #expect(!FrameScheduler.mayPresentEcho(now: 10, lastInput: 9.99, lastPresent: 9.96, maximumFPS: 20, isPaused: true))
        #expect(!FrameScheduler.mayPresentEcho(now: 10, lastInput: 9.99, lastPresent: nil, maximumFPS: 60, isPaused: false))
    }

    @Test func onDemandPacingDoesNotRetainTheScheduler() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = NSView(frame: window.contentLayoutRect)
        var scheduler: FrameScheduler? = FrameScheduler(metalLayer: CAMetalLayer(), driver: .ondemand)
        weak var released = scheduler
        scheduler?.attach(to: window)
        #expect(scheduler?.isAttached == true)
        scheduler = nil
        #expect(released == nil, "CADisplayLink must not retain its scheduler through its target")
    }

}
