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

import CortaTerminal
import Metal
import QuartzCore

/// One pane's render loop: whether a frame is owed, the diff that decides
/// it, and the draw.
///
/// The reader thread calls `noteOutput` per parse batch; the vsync calls
/// `prepareFrame` and then `render` (`FrameScheduler`). With nothing new,
/// `prepareFrame` reports nothing pending and the scheduler pauses (idle
/// ~0% CPU, `PERFORMANCE.md` §3); otherwise it runs the output-batch stage
/// once and diffs the pane's content into the renderer, and a frame is
/// drawn only on damage.
///
/// The loop owns the cadence, not the content. What a frame shows — the
/// grid, selection, search highlights, the cursor — comes from `content`;
/// what a batch of output changes beyond the grid — the title,
/// notifications, accessibility, history — is `onOutputBatch`'s.
final class PaneFrameLoop {
    /// What one frame draws, decided by the pane after the batch stage.
    struct Content {
        var grid: Grid
        var scrollOffset: Int
        var cursorVisible: Bool
        var selection: TerminalSelection?
        var searchMatches: [TerminalSelection] = []
        var currentSearchMatchIndex: Int?
        var hoveredLink: TerminalSelection?
        var cursorStyle: CursorStyle?
    }

    private(set) var session: TerminalSession?
    private(set) var renderer: TerminalRenderer?

    /// A session's callbacks capture the generation they were installed
    /// for, so a batch from a session a retry has since replaced is a no-op
    /// — `[weak self]` only says the loop is alive, not that the session is
    /// still its own.
    private(set) var generation = 0
    /// For changes the damage diff cannot see: drawable size, scale,
    /// scrolling.
    private var needsRedraw = true
    /// `?2026` withheld a frame, so the next one presents even if the diff
    /// finds nothing.
    private var wasSynchronizedOutputActive = false
    /// An idle frame costs this one check, not a diff. One per session,
    /// replaced with it.
    private(set) var outputWake = OutputWakeGate()

    /// `BEL` arrived since the last frame.
    var onBell: (() -> Void)?
    /// Output arrived since the last frame; runs once per frame, before the
    /// diff, whatever the batch held.
    var onOutputBatch: (() -> Void)?
    /// This frame's content; `hasOutput` says whether a batch arrived.
    var content: ((_ hasOutput: Bool) -> Content?)?
    /// Asks the view for a vsync (`TerminalView.setNeedsRedraw`).
    var onNeedsDisplay: (() -> Void)?
    private var renderEchoOnDemand: (() -> Bool)?
    var onRenderingFailure: ((any Error) -> Void)?
    private var renderingStopped = false
    private var feedback = GPUFrameFeedback()
    private var watchdog: DispatchWorkItem?
    /// The pane's top inset, which only a pane under the window's chrome
    /// has (`ViewController.topInset`).
    var topInset: () -> CGFloat = { 0 }

    /// Starts drawing `session` with `renderer`, replacing any previous
    /// pair, and routes the session's output here. Returns the generation,
    /// for the pane's other session callbacks to check with `isCurrent`.
    @discardableResult
    func attach(session: TerminalSession, renderer: TerminalRenderer) -> Int {
        generation += 1
        let generation = generation
        let wake = OutputWakeGate()
        outputWake = wake
        self.session = session
        self.renderer = renderer
        needsRedraw = true
        wasSynchronizedOutputActive = false
        renderingStopped = false
        watchdog?.cancel()
        watchdog = nil
        feedback = GPUFrameFeedback()
        session.onOutput = { [weak self] in
            self?.noteOutput(generation: generation, wake: wake)
        }
        return generation
    }

    /// Makes `view`'s display link drive this loop.
    func install(on view: TerminalView) {
        renderEchoOnDemand = { [weak view] in view?.renderEchoOnDemand() ?? false }
        view.onRenderFrame = { [weak self] drawableSize, drawable in
            guard let self else {
                // Never hold a drawable: an unpresented one is never recycled.
                drawable.present()
                return true
            }
            return render(drawableSize: drawableSize, drawable: drawable)
        }
        view.shouldRenderFrame = { [weak self] in
            self?.prepareFrame() ?? false
        }
    }

    /// Whether `generation` is the attached session's.
    func isCurrent(_ generation: Int) -> Bool {
        generation == self.generation
    }

    func detach() {
        suspendRendering()
        generation += 1
        session = nil
        renderer = nil
        outputWake = OutputWakeGate()
    }

    func suspendRendering() {
        renderingStopped = true
        watchdog?.cancel()
        watchdog = nil
    }

    private func watchGPU(generation: Int, backendGeneration: Int) {
        guard watchdog == nil, feedback.hasPending else { return }
        let feedback = feedback
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.renderingStopped, self.generation == generation,
                    self.renderer?.backendGeneration == backendGeneration else { return }
                self.watchdog = nil
                if feedback.hasExpired() {
                    // No drawable callback may arrive to recover this queue.
                    // Offer explicit session recovery rather than silently hang.
                    self.suspendRendering()
                    self.onRenderingFailure?(Metal4BackendError.gpuCompletionTimedOut)
                } else {
                    self.watchGPU(generation: generation, backendGeneration: backendGeneration)
                }
            }
        }
        watchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// For local changes that produce no output.
    func invalidate() {
        needsRedraw = true
        onNeedsDisplay?()
    }

    /// Per vsync. Returns whether a frame is owed: forced by `invalidate`
    /// or a `?2026` release, or damage the diff found.
    func prepareFrame() -> Bool {
        guard !renderingStopped, let session, let renderer else { return false }
        if session.takeBell() {
            onBell?()
        }
        let hasOutput = outputWake.takePending()
        guard needsRedraw || hasOutput else { return false }
        if hasOutput {
            onOutputBatch?()
        }
        if session.isSynchronizedOutputEnabled {
            // Owe a present until the DECRST, or a torn state shows.
            wasSynchronizedOutputActive = true
            return false
        }
        let forced = needsRedraw || wasSynchronizedOutputActive
        needsRedraw = false
        wasSynchronizedOutputActive = false
        guard let content = content?(hasOutput) else { return forced }
        let indexedPalette = session.indexedPalette
        let damaged = renderer.updateInstances(
            grid: content.grid, scrollOffset: content.scrollOffset,
            cursorVisible: content.cursorVisible, selection: content.selection,
            searchMatches: content.searchMatches,
            currentSearchMatchIndex: content.currentSearchMatchIndex,
            hoveredLink: content.hoveredLink,
            indexedOverrides: indexedPalette.overrides,
            indexedOverridesGeneration: indexedPalette.overridesGeneration,
            cursorStyle: content.cursorStyle)
        return forced || damaged
    }

    /// On the reader thread, per parse batch; `generation` guards against a
    /// replaced session. Hops to the main actor only when `wake` was idle:
    /// the frame that takes the flag re-arms it, so a flood costs one hop a
    /// frame, not one a batch.
    nonisolated private func noteOutput(generation: Int, wake: OutputWakeGate) {
        // A point, not an interval: the interval began on another thread.
        InputLatencySignposts.emit(.output)
        RenderMetrics.noteOutputForKeystroke()
        guard wake.noteOutput() else { return }
        // Measured apart: a busy main thread lengthens this stage.
        let wakeStart = RenderMetrics.isEnabled ? DispatchTime.now().uptimeNanoseconds : nil
        let interval = InputLatencySignposts.begin(.wake)
        // On the keypress-to-pixel chain; the default priority has no claim.
        Task(priority: .userInitiated) { @MainActor [weak self] in
            if let wakeStart {
                RenderMetrics.record(.wakeHop, milliseconds:
                    Double(DispatchTime.now().uptimeNanoseconds - wakeStart) / 1_000_000)
            }
            RenderMetrics.noteMainHopForKeystroke()
            InputLatencySignposts.end(.wake, interval)
            guard let self, self.generation == generation else { return }
            if self.renderEchoOnDemand?() != true { self.onNeedsDisplay?() }
        }
    }

    /// Right after `prepareFrame()` in the same callback, drawing its cached
    /// context; never blocks the reader (`PERFORMANCE.md` §2.1). Draws the
    /// renderer's cached instances, which `prepareFrame` last diffed, as one
    /// Metal 4 render pass; the backend commits and presents the drawable.
    /// Returns false for a frame the backend dropped, which the scheduler
    /// owes another tick.
    func render(drawableSize: CGSize, drawable: CAMetalDrawable) -> Bool {
        guard !renderingStopped, let renderer else {
            // Never hold a drawable: an unpresented one is never recycled.
            drawable.present()
            return true
        }
        do {
            if try renderer.recoverBackendIfNeeded() {
                watchdog?.cancel()
                watchdog = nil
                feedback = GPUFrameFeedback()
            }
        } catch {
            renderingStopped = true
            drawable.present()
            onRenderingFailure?(error)
            return true
        }
        let generation = generation
        let backendGeneration = renderer.backendGeneration
        let feedback = feedback
        let submission = feedback.begin()
        let rect = Self.contentRect(
            in: drawableSize, scale: renderer.scale,
            gridHeight: CGFloat(renderer.cachedRowCount) * renderer.metrics.cellHeight,
            topInset: topInset())
        let gpu = InputLatencySignposts.begin(.gpu)
        let gpuStart = RenderMetrics.isEnabled ? DispatchTime.now() : nil
        // `gpu` spans submission to completion — the only place GPU time and a
        // drawable wait become visible.
        let onCompleted: @Sendable ((any Error)?) -> Void = { [weak self] error in
            feedback.complete(submission)
            InputLatencySignposts.end(.gpu, gpu)
            if let gpuStart {
                let ms =
                    Double(DispatchTime.now().uptimeNanoseconds - gpuStart.uptimeNanoseconds)
                    / 1_000_000
                RenderMetrics.record(.gpu, milliseconds: ms)
            }
            // Feedback may arrive after the scheduler parks. A callback
            // from an old session/queue must not invalidate a replacement.
            guard let error else { return }
            if case Metal4BackendError.frameDropped = error { return }
            Task(priority: .userInitiated) { @MainActor [weak self] in
                guard let self, self.generation == generation,
                    self.renderer?.backendGeneration == backendGeneration else { return }
                self.invalidate()
            }
        }
        let background = TerminalColorPalette.clearColor
        let commit = InputLatencySignposts.begin(.commit)
        let drawn = renderer.draw(
            rect: rect, drawableSize: drawableSize, target: drawable.texture,
            clearColor: MTLClearColorMake(
                Double(background.x), Double(background.y), Double(background.z),
                Double(background.w)),
            // For Metal System Trace: ties a command buffer to its pane.
            drawable: drawable, label: "Corta.frame.\(ObjectIdentifier(self).hashValue)",
            onCompleted: onCompleted)
        InputLatencySignposts.end(.commit, commit)
        watchGPU(generation: generation, backendGeneration: backendGeneration)
        return drawn
    }

    /// Top-anchored when the grid fits, so the rounding remainder sits at the
    /// bottom, not under the titlebar; bottom-anchored when mid-drag the grid is
    /// taller, so the prompt stays put (top-pinning was the "text jumps").
    nonisolated static func contentRect(
        in drawableSize: CGSize, scale: CGFloat, gridHeight: CGFloat, topInset: CGFloat
    ) -> CGRect {
        let bottom = drawableSize.height - TerminalLayout.insets.bottom * scale
        let fits = topInset * scale + gridHeight <= bottom
        return CGRect(
            x: TerminalLayout.insets.left * scale,
            y: fits ? topInset * scale : bottom - gridHeight,
            width: max(0, drawableSize.width - TerminalLayout.insetWidth * scale),
            height: gridHeight)
    }
}
