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

import Foundation
import QuartzCore
import Synchronization

/// One serial run loop per window. The thread captures only its startup box,
/// so releasing the last pane owner stops the thread rather than retaining itself.
/// Sendability is limited to posting commands; RunLoop/links stay on this thread.
nonisolated final class RenderThread: @unchecked Sendable {
    private final class Startup: Sendable {
        // CFRunLoop's cross-thread perform/wake APIs explicitly support this use.
        struct Loop: @unchecked Sendable { let value: CFRunLoop }
        let loop = Mutex<Loop?>(nil)
        let ready = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
    }
    private let startup = Startup()
    init() {
        let startup = startup
        let thread = Thread {
            let loop = CFRunLoopGetCurrent()!
            let port = Port()
            RunLoop.current.add(port, forMode: .common)
            startup.loop.withLock { $0 = Startup.Loop(value: loop) }
            startup.ready.signal()
            CFRunLoopRun()
            startup.loop.withLock { $0 = nil }
            port.invalidate()
            startup.finished.signal()
        }
        thread.name = "com.corta.window.render"
        thread.qualityOfService = .userInteractive
        thread.start()
        precondition(
            startup.ready.wait(timeout: .now() + 5) == .success, "Render loop startup timed out")
    }
    var isCurrent: Bool {
        startup.loop.withLock { loop in
            loop.map { CFEqual(CFRunLoopGetCurrent(), $0.value) } ?? false
        }
    }

    func post(_ body: @escaping @Sendable () -> Void) {
        startup.loop.withLock { loop in
            guard let loop else { return }
            CFRunLoopPerformBlock(loop.value, RunLoop.Mode.common.rawValue as CFString, body)
            CFRunLoopWakeUp(loop.value)
        }
    }
    /// Commands execute between frames and never wait for main. Configuration,
    /// capture and teardown use a bounded barrier from the main thread.
    /// `false` when the thread did not get to `body` in time — a GPU hang
    /// holding a frame. `body` still runs, late, once the thread is free:
    /// the caller carries on rather than taking every window down.
    @discardableResult
    func barrier(_ body: @escaping @Sendable () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        post {
            body()
            done.signal()
        }
        return done.wait(timeout: .now() + 5) == .success
    }
    deinit {
        let onOwner = startup.loop.withLock { loop in
            guard let loop else { return false }
            let onOwner = CFEqual(CFRunLoopGetCurrent(), loop.value)
            CFRunLoopStop(loop.value)
            CFRunLoopWakeUp(loop.value)
            return onOwner
        }
        if !onOwner { _ = startup.finished.wait(timeout: .now() + 5) }
    }
}

@MainActor enum WindowRenderThreads {
    private final class WeakThread {
        weak var value: RenderThread?
        init(_ value: RenderThread) { self.value = value }
    }
    private static var threads: [ObjectIdentifier: WeakThread] = [:]
    static func thread(for window: AnyObject) -> RenderThread {
        threads = threads.filter { $0.value.value != nil }
        let key = ObjectIdentifier(window)
        if let existing = threads[key]?.value { return existing }
        let thread = RenderThread()
        threads[key] = WeakThread(thread)
        return thread
    }
}

/// All mutable fields are owned by `owner`'s run loop. Main and reader threads
/// may only post commands. Main synchronously detaches before dropping an owner.
nonisolated final class ThreadFrameDriver: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable
{
    let owner: RenderThread
    private let layer: CAMetalLayer
    private let render: @Sendable (CGSize, CAMetalDrawable) -> (pending: Bool, drawn: Bool)
    private let visible = Atomic<Bool>(true)
    private var link: CAMetalDisplayLink?
    private var wakeEpoch: UInt64 = 0
    private var quietEligible = false
    private var resumedAt: CFTimeInterval?
    private var previousTarget: CFTimeInterval?
    private var range = CAFrameRateRange.default
    init(
        owner: RenderThread, layer: CAMetalLayer,
        render: @escaping @Sendable (CGSize, CAMetalDrawable) -> (pending: Bool, drawn: Bool)
    ) {
        self.owner = owner
        self.layer = layer
        self.render = render
        super.init()
    }
    func attach(range: CAFrameRateRange) {
        owner.post { [self] in
            let link = CAMetalDisplayLink(metalLayer: layer)
            link.delegate = self
            link.preferredFrameRateRange = range
            self.range = range
            if let latency = DiagnosticsEnvironment.frameLatency() {
                link.preferredFrameLatency = latency
            }
            link.add(to: .current, forMode: .common)
            link.isPaused = true
            self.link = link
        }
    }
    func detach() {
        owner.barrier { [self] in
            link?.invalidate()
            link = nil
            previousTarget = nil
        }
    }
    func resume() {
        guard visible.load(ordering: .acquiring) else { return }
        owner.post { [self] in
            if visible.load(ordering: .acquiring) {
                wakeEpoch &+= 1
                quietEligible = false
                link?.preferredFrameRateRange = range
                if link?.isPaused == true { resumedAt = CACurrentMediaTime() }
                link?.isPaused = false
            }
        }
    }
    func setVisible(_ value: Bool) {
        visible.store(value, ordering: .releasing)
        if value { resume() } else { pause() }
    }
    func pause() {
        owner.post { [self] in
            link?.isPaused = true
            previousTarget = nil
        }
    }
    func setRange(_ range: CAFrameRateRange) {
        owner.post { [self] in
            self.range = range
            link?.preferredFrameRateRange = quietEligible ? Self.waitingRange(for: range) : range
        }
    }
    /// Keep the link active until the last frame reaches glass, without
    /// submitting unchanged replacements every vsync while it is in flight.
    static func waitingRange(for range: CAFrameRateRange) -> CAFrameRateRange {
        let ceiling: Float = range.maximum > 0 ? min(15, range.maximum) : 15
        return CAFrameRateRange(minimum: ceiling, maximum: ceiling, preferred: ceiling)
    }
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update)
    {
        autoreleasepool { renderUpdate(link, update: update) }
    }
    private func renderUpdate(_ link: CAMetalDisplayLink, update: CAMetalDisplayLink.Update) {
        let signpost = InputLatencySignposts.begin(.frame)
        defer { InputLatencySignposts.end(.frame, signpost) }
        if RenderMetrics.isEnabled {
            let now = CACurrentMediaTime()
            let lead = (update.targetPresentationTimestamp - now) * 1000
            RenderMetrics.record(.callbackLead, milliseconds: lead)
            if let resumedAt {
                RenderMetrics.record(.firstAfterResume, milliseconds: lead)
                RenderMetrics.record(.resumeToCallback, milliseconds: (now - resumedAt) * 1000)
                self.resumedAt = nil
            }
            if let previousTarget {
                RenderMetrics.record(
                    .frameInterval,
                    milliseconds: (update.targetPresentationTimestamp - previousTarget) * 1000
                )
            }
            previousTarget = update.targetPresentationTimestamp
            RenderMetrics.notePresentationTarget(
                of: update.drawable, at: update.targetPresentationTimestamp)
            RenderMetrics.noteConditions(
                minimum: range.minimum, maximum: range.maximum,
                preferred: range.preferred, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        }
        let epoch = wakeEpoch
        let acceptedQuietFrame = Atomic<Bool>(false)
        update.drawable.addPresentedHandler { [weak self] drawable in
            guard drawable.presentedTime > 0, acceptedQuietFrame.load(ordering: .acquiring), let self else { return }
            owner.post { [weak self] in
                guard let self, wakeEpoch == epoch, quietEligible,
                    visible.load(ordering: .acquiring) else { return }
                self.link?.isPaused = true
                previousTarget = nil
            }
        }
        let result = RenderMetrics.measure(.cpuFrame) {
            render(
                CGSize(
                    width: update.drawable.texture.width, height: update.drawable.texture.height),
                update.drawable)
        }
        // Pausing on submission can discard the last drawable and leave the
        // latest pixels unseen. Stay paced until an idle frame reaches glass;
        // a later wake invalidates the old frame's permission to park.
        quietEligible = !result.pending && result.drawn
        acceptedQuietFrame.store(quietEligible, ordering: .releasing)
        link.preferredFrameRateRange = quietEligible ? Self.waitingRange(for: range) : range
    }
}
