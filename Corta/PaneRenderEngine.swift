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
import Foundation
import Metal
import QuartzCore
import Synchronization

/// Frame caches/backend are confined to the owning window render run loop.
/// The reader only sets atomics and posts a wake. Main publishes inputs,
/// suspends through an atomic, and consumes coalesced snapshot feedback.
nonisolated final class PaneRenderEngine: @unchecked Sendable {
    let inputs = RenderInputMailbox()
    let session: TerminalSession
    let renderer: TerminalRenderer
    private let cursorSignal: CursorHandoffMailbox
    private var lastCursorToken: UInt64 = 0
    private var cachedCursorVisible = false
    private var pendingBell = false
    private let wake: OutputWakeGate
    private let driver = Mutex<ThreadFrameDriver?>(nil)
    // False skips the driver mutex on the default main-thread output path.
    // A true value is only a hint: the mutex still resolves detach races.
    private let hasThreadDriver = Atomic<Bool>(false)
    private let forced = Atomic<Bool>(true)
    private let stopped = Atomic<Bool>(false)
    private var synchronized = false
    private var feedback = GPUFrameFeedback()
    private var watchdogArmed = false
    private var lastInputGeneration: UInt64 = 0
    private struct MainFeedback: Sendable {
        var grid: Grid?
        var cursorRevision: UInt64 = 0
        var inputMetadata: RenderInputSourceMetadata?
        var output = false
        var bell = false
        var enqueued = false
    }
    private let mainFeedback = Mutex(MainFeedback())
    private let afterFrame:
        @MainActor @Sendable (Grid, Bool, Bool, UInt64, RenderInputSourceMetadata?) -> Void
    private let presented: @MainActor @Sendable (UInt64) -> Void
    private let failure: @MainActor @Sendable (any Error) -> Void
    /// Built once: an interpolated label was a string allocation per frame.
    private let frameLabel = "Corta.frame.thread.\(PaneRenderEngine.nextLabel.wrappingAdd(1, ordering: .relaxed).newValue)"
    private static let nextLabel = Atomic<Int>(0)
    init(
        session: TerminalSession, renderer: TerminalRenderer, wake: OutputWakeGate,
        cursorSignal: CursorHandoffMailbox,
        afterFrame:
            @escaping @MainActor @Sendable (Grid, Bool, Bool, UInt64, RenderInputSourceMetadata?) ->
            Void,
        presented: @escaping @MainActor @Sendable (UInt64) -> Void,
        failure: @escaping @MainActor @Sendable (any Error) -> Void
    ) {
        self.cursorSignal = cursorSignal
        self.session = session
        self.renderer = renderer
        self.wake = wake
        self.afterFrame = afterFrame
        self.presented = presented
        self.failure = failure
        let deferred = renderer.onGlyphsDeferred
        let ready = renderer.kittyImageRenderer.onImagesReady
        renderer.onGlyphsDeferred = { [weak self] in
            if self?.driver.withLock({ $0 != nil }) == true {
                self?.invalidate()
            } else {
                deferred?()
            }
        }
        renderer.kittyImageRenderer.onImagesReady = { [weak self] in
            if self?.driver.withLock({ $0 != nil }) == true { self?.invalidate() } else { ready?() }
        }
    }
    func setDriver(_ driver: ThreadFrameDriver?) {
        self.driver.withLock {
            $0 = driver
            hasThreadDriver.store(driver != nil, ordering: .releasing)
        }
        renderer.setRenderOwner(driver?.owner)
    }
    func requestFrameIfThreaded() -> Bool {
        driver.withLock { driver in
            guard let driver else { return false }
            forced.store(true, ordering: .releasing)
            driver.resume()
            return true
        }
    }
    func invalidate() {
        forced.store(true, ordering: .releasing)
        driver.withLock { $0?.resume() }
    }
    func suspend() {
        stopped.store(true, ordering: .releasing)
        setDriver(nil)
    }
    func noteOutput() -> Bool {
        guard hasThreadDriver.load(ordering: .acquiring) else { return false }
        return driver.withLock { driver in
            guard let driver else { return false }
            InputLatencySignposts.emit(.output)
            RenderMetrics.noteOutputForKeystroke()
            if wake.noteOutput() { driver.resume() }
            return true
        }
    }
    private func sendToMain(
        grid: Grid, output: Bool, bell: Bool, cursorRevision: UInt64,
        inputMetadata: RenderInputSourceMetadata?
    ) {
        let enqueue = mainFeedback.withLock { state in
            state.grid = grid
            state.cursorRevision = cursorRevision
            state.inputMetadata = inputMetadata
            state.output = state.output || output
            state.bell = state.bell || bell
            guard !state.enqueued else { return false }
            state.enqueued = true
            return true
        }
        guard enqueue else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let state = self.mainFeedback.withLock { state in
                let result = state
                state = MainFeedback()
                return result
            }
            guard !self.stopped.load(ordering: .acquiring), let grid = state.grid else { return }
            self.afterFrame(
                grid, state.output, state.bell, state.cursorRevision, state.inputMetadata)
        }
    }
    private func fail(_ error: any Error) {
        stopped.store(true, ordering: .releasing)
        Task { @MainActor [failure] in failure(error) }
    }
    func frame(size: CGSize, drawable: CAMetalDrawable) -> (pending: Bool, drawn: Bool) {
        guard !stopped.load(ordering: .acquiring) else {
            drawable.present()
            return (false, true)
        }
        return renderer.withExclusiveAccess {
            let inputs = inputs.read()
            let hasOutput = wake.takePending()
            let cursor = cursorSignal.snapshot
            let bell = session.takeBell()
            pendingBell = pendingBell || bell
            let redraw =
                forced.exchange(false, ordering: .acquiringAndReleasing)
                || lastInputGeneration != inputs.generation
                || cursor.token != lastCursorToken
            if hasOutput || redraw || synchronized {
                if session.isSynchronizedOutputEnabled {
                    synchronized = true
                } else {
                    renderer.echoSnapshotAt = RenderMetrics.isEnabled ? CACurrentMediaTime() : nil
                    let inputSnapshot =
                        inputs.readsInputSourceMetadata ? session.inputLineSnapshot() : nil
                    let grid = inputSnapshot?.grid ?? session.snapshot()
                    let metadata = inputSnapshot.map {
                        RenderInputSourceMetadata(
                            hasIntegration: $0.hasIntegration, promptRow: $0.promptRow)
                    }
                    var offset = inputs.scrollOffset
                    if offset > 0, let anchor = inputs.scrollAnchorTotalPushed {
                        offset = ScrollbackCoordinates.reanchoredOffset(
                            offset, from: anchor,
                            to: grid.scrollback.totalPushed)
                    }
                    let palette = session.indexedPalette
                    renderer.themeVariant = inputs.theme
                    renderer.drawsCommandMarks = inputs.drawsCommandMarks
                    let style = grid.cursorStyleIsExplicit ? grid.cursorStyle : inputs.cursorStyle
                    cachedCursorVisible =
                        inputs.cursorVisible && grid.isCursorVisible && offset == 0
                        && (hasOutput || inputs.cursorBlinkVisible
                            || cursor.phase == .awaitingMetal)
                    _ = renderer.updateInstances(
                        grid: grid, scrollOffset: offset,
                        cursorVisible: cachedCursorVisible, selection: inputs.selection,
                        searchMatches: inputs.searchMatches,
                        currentSearchMatchIndex: inputs.currentSearchMatchIndex,
                        hoveredLink: inputs.hoveredLink,
                        indexedOverrides: palette.overrides,
                        indexedOverridesGeneration: palette.overridesGeneration, cursorStyle: style)
                    synchronized = false
                    lastInputGeneration = inputs.generation
                    lastCursorToken = cursor.token
                    sendToMain(
                        grid: grid, output: hasOutput, bell: pendingBell,
                        cursorRevision: cursor.outputRevision, inputMetadata: metadata)
                    pendingBell = false
                }
            }
            do {
                if try renderer.recoverBackendIfNeeded() { feedback = GPUFrameFeedback() }
            } catch {
                drawable.present()
                fail(error)
                return (false, true)
            }
            let submission = feedback.begin()
            let feedback = feedback
            let gpu = InputLatencySignposts.begin(.gpu)
            let start = RenderMetrics.isEnabled ? DispatchTime.now().uptimeNanoseconds : nil
            let background = inputs.theme.background
            let rect = PaneFrameLoop.contentRect(
                in: size, scale: renderer.scale,
                gridHeight: CGFloat(renderer.cachedRowCount) * renderer.metrics.cellHeight,
                topInset: inputs.topInset)
            let accepted = !synchronized && cursor.awaits(cursorDrawn: cachedCursorVisible)
                ? cursorSignal.trackPresentation(
                    of: drawable, token: cursor.token,
                    retry: { [weak self] in self?.invalidate() }, presented: presented)
                : nil
            let drawn = renderer.draw(
                rect: rect, drawableSize: size, target: drawable.texture,
                clearColor: MTLClearColorMake(
                    Double(background.x), Double(background.y),
                    Double(background.z), Double(background.w)), drawable: drawable,
                label: frameLabel
            ) { [weak self] error in
                feedback.complete(submission)
                InputLatencySignposts.end(.gpu, gpu)
                if let start {
                    RenderMetrics.record(
                        .gpu,
                        milliseconds:
                            Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                }
                if let error, case Metal4BackendError.frameDropped = error { return }
                if error != nil { self?.invalidate() }
            }
            accepted?.finishEncoding(drawn)
            armWatchdog()
            // Damage consumed by this draw is not work owed by the next draw.
            // The driver parks only once this quiet generation reaches glass.
            let pending = wake.hasPending || forced.load(ordering: .acquiring) || !drawn
            return (pending, drawn)
        }
    }
    private func armWatchdog() {
        guard !watchdogArmed, feedback.hasPending else { return }
        watchdogArmed = true
        driver.withLock { $0?.owner }?.post { [weak self] in
            let timer = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
                guard let self, !self.stopped.load(ordering: .acquiring) else { return }
                self.watchdogArmed = false
                if self.feedback.hasExpired() {
                    self.fail(Metal4BackendError.gpuCompletionTimedOut)
                } else {
                    self.armWatchdog()
                }
            }
            RunLoop.current.add(timer, forMode: .common)
        }
    }
}
