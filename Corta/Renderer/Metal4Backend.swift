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

import CoreGraphics
import Foundation
import Metal
import OSLog
import QuartzCore
import Synchronization

enum Metal4BackendError: Error {
    /// The GPU has no `MTLGPUFamily.metal4` — a virtual machine's
    /// paravirtual device; every Apple silicon Mac has it (D21).
    case metal4Unsupported
    case commandBufferUnavailable
    case commandAllocatorUnavailable
    /// Handed to `onCompleted` for a frame that was presented without being
    /// drawn, because its slot's previous frame had not completed.
    case frameDropped
    case recoveryExhausted
    case commandEncoderUnavailable
    case gpuCompletionTimedOut
}

/// Where backend faults are logged; the silent failure mode would be a
/// window that renders nothing.
nonisolated enum Metal4Diagnostics {
    static let log = OSLog(subsystem: "dev.noahqin.Corta", category: "render")

    /// Bounded, or a faulting queue logs once per frame forever.
    private static let reportedFaults = Atomic<Int>(0)
    private static let faultReportLimit = 8

    static func reportCommitFault(_ error: any Error) {
        // Claim a slot below the limit; at the limit the counter stops.
        var reported = reportedFaults.load(ordering: .relaxed)
        while reported < faultReportLimit {
            let (exchanged, original) = reportedFaults.compareExchange(
                expected: reported, desired: reported + 1, ordering: .relaxed)
            if exchanged { break }
            reported = original
        }
        guard reported < faultReportLimit else { return }
        os_log(.error, log: log, "Metal 4 commit faulted: %{public}@", String(describing: error))
    }

    static func reportStalledQueue(droppedFrames: Int) {
        os_log(
            .fault, log: log,
            """
            Metal 4 GPU work has not completed across %d consecutive frames (commit fault or hung GPU); \
            dropping frames instead of blocking the render loop
            """,
            droppedFrames)
    }
}

/// The renderer's GPU backend: Metal 4 submission (`MTL4CommandQueue`,
/// per-slot `MTL4CommandBuffer`s and `MTL4CommandAllocator`s, one
/// `MTL4RenderCommandEncoder` per frame, one reused `MTL4ArgumentTable`).
///
/// **One render pass per frame.** `beginFrame` opens the pass and its
/// clear; every draw of the frame — backgrounds, glyphs, colour glyphs,
/// each Kitty placement — encodes into that one encoder; `endFrame` ends it
/// and commits. No draw pays a tile load/store round trip of its own.
///
/// Draws bind by address through the argument table (MTL4 has no
/// `setVertexBytes`, so uniforms ride in the ring buffers), and the drawable
/// is presented via `signalDrawable`. Pipelines are `MTLRenderPipelineState`s
/// from `QuadPipelineCache`, which is the type an MTL4 encoder takes.
///
/// **Frame slots.** A frame writes its slot's command buffer, allocator and
/// ring buffers, so it may begin only once the frame that last used the
/// slot has completed. Each slot has a semaphore; the commit-feedback
/// handler of the slot's frame signals it — the completion is an event, not
/// something polled. `beginFrame` waits for it at most `slotWaitLimit`, one
/// display frame; past that it drops the frame (presented, not drawn), and
/// while the slot stays busy later frames drop without waiting at all. So a
/// stalled GPU costs dropped frames, never a blocked main thread. Feedback
/// rather than a queue-signalled `MTLSharedEvent`: the event was observed
/// never to advance against a live `CAMetalDisplayLink` stream
/// (the B12 Metal 4 backend record, 2026-09-15, in the repository's history).
///
/// **Residency.** Ring buffers and every texture bound by resource ID
/// (`boundTextures`) live in the queue's `MTLResidencySet`: MTL4 neither
/// retains nor keeps resident a texture bound by `gpuResourceID`, and a
/// non-resident one page-faults at read time. Address bindings aren't
/// retained by the command buffer either, so `deinit` waits, bounded, for
/// the frames in flight (`metal4BackendDeallocatesWithFramesInFlight`).
///
/// Every method runs on the main thread; only the commit feedback
/// handler runs elsewhere, and it touches only `completion` and the slot
/// semaphores.
public nonisolated final class Metal4Backend {
    let device: MTLDevice

    private let queue: any MTL4CommandQueue
    /// One per slot: re-beginning a command buffer whose previous commit is
    /// still executing faults intermittently (`IOGPUMetalError` on launch).
    private let commandBuffers: [any MTL4CommandBuffer]
    /// One per slot: an allocator may be reset only after its work completes.
    private let allocators: [any MTL4CommandAllocator]
    /// Metal snapshots the table at each draw, so rebinding between draws and
    /// frames is safe.
    let argumentTable: any MTL4ArgumentTable
    let residencySet: any MTLResidencySet

    private let solidPass: DrawPass
    private let glyphPass: DrawPass
    /// Premultiplied-source blending, for colour glyphs and images.
    private let colorGlyphPass: DrawPass
    let sampler: MTLSamplerState

    /// Created once and re-pointed each frame: no per-frame allocation.
    private let renderPassDescriptor = MTL4RenderPassDescriptor()

    /// A drawable a Metal 4 command buffer wrote is never presented
    /// directly to the display; the window server composites it, which
    /// costs a frame (measured on macOS 27, `PERFORMANCE.md` §5.17). While
    /// set — a full-screen window with one pane, `SplitViewController` —
    /// a frame renders into `copyStaging` instead, and a classic
    /// `MTLCommandQueue` copies it to the target and presents that, which
    /// the display may take directly. A target that is framebuffer-only
    /// cannot be copied into and is rendered as before.
    var presentsByCopy = false
    private lazy var copyQueue: MTLCommandQueue? = device.makeCommandQueue()
    /// Metal 4 → copy: the frame is rendered.
    private lazy var copyRendered: MTLSharedEvent? = device.makeSharedEvent()
    /// Copy → Metal 4: the staging texture may be rendered into again.
    private lazy var copyCompleted: MTLSharedEvent? = device.makeSharedEvent()
    /// Frames copied so far; also the copy events' latest value.
    private(set) var copyFrame: UInt64 = 0
    private var copyStaging: MTLTexture?
    /// The current frame's real target, when it was redirected.
    private var copyTarget: MTLTexture?

    private func copyStagingTexture(like target: MTLTexture) -> MTLTexture? {
        if let copyStaging, copyStaging.width == target.width,
            copyStaging.height == target.height, copyStaging.pixelFormat == target.pixelFormat
        {
            return copyStaging
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: target.pixelFormat, width: target.width, height: target.height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        guard let fresh = device.makeTexture(descriptor: descriptor) else { return nil }
        // A queued frame may still render into the old one: it leaves the
        // residency set when that frame completes, like a retired buffer.
        if let copyStaging { retired.append((frame: frameNumber, allocation: copyStaging)) }
        residencySet.addAllocation(fresh)
        residencySet.commit()
        copyStaging = fresh
        return fresh
    }

    /// Frames in flight: the depth of every per-slot ring.
    static let frameSlotCount = 3

    /// How long `beginFrame` may wait for a busy slot: one frame at 60 Hz,
    /// the longest a display-link frame waits for its drawable.
    public static let defaultSlotWaitLimit: DispatchTimeInterval = .microseconds(16_667)
    private let slotWaitLimit: DispatchTimeInterval

    /// Signalled by the feedback handler of the frame that last used the
    /// slot; a slot is free when its semaphore can be taken.
    private let slotSemaphores: [DispatchSemaphore]
    /// The highest completed frame, for releasing retired resources.
    private let completion = FrameCompletion()

    /// Written by the feedback handler, read by `beginFrame`.
    private final class FrameCompletion: Sendable {
        private let completedFrame = Atomic<UInt64>(0)
        let failed = Atomic(false)

        var completed: UInt64 { completedFrame.load(ordering: .acquiring) }

        func note(_ frame: UInt64) {
            completedFrame.max(frame, ordering: .releasing)
        }
    }

    /// 1-based count of frames committed; what a frame's feedback records.
    var frameNumber: UInt64 = 0
    /// The slot the next committed frame uses. Advances only on a commit, so
    /// a dropped frame leaves the ring where it was.
    private var nextSlot = 0
    var currentSlot = 0
    /// Frames dropped in a row; while non-zero, the next frame does not wait.
    private var consecutiveDroppedFrames = 0
    /// When a dropped frame found the queue busy, and how far the GPU had
    /// got then. On `SuspendingClock`: a lid closed with a frame in flight
    /// is not a second of stalled GPU.
    private var stall: (since: SuspendingClock.Instant, completed: UInt64)?
    private static let stalledQueueReportThreshold = 3
    private(set) var droppedFrameCount = 0

    /// A few slow frames are not a failed queue, and neither is a dropped
    /// frame followed by a pause — an occluded or minimised window, a Space
    /// switch, display sleep — while the GPU caught up: only a queue that
    /// has completed nothing for a second while frames wait is stalled.
    /// Read on the main thread.
    var requiresRecovery: Bool {
        if completion.failed.load(ordering: .acquiring) { return true }
        guard let stall, hasFramesInFlight, completion.completed == stall.completed else { return false }
        return stall.since.duration(to: .now) >= .seconds(1)
    }

    var hasFramesInFlight: Bool { completion.completed < frameNumber }
    /// Frames this queue has finished, for judging whether a rebuilt queue
    /// has proved itself.
    var completedFrameCount: UInt64 { completion.completed }

    /// Valid between `beginFrame` and `endFrame`; nil for a dropped frame.
    var encoder: (any MTL4RenderCommandEncoder)?
    /// The encoder's last state, so draws sharing one encoder skip redundant
    /// changes. Reset in `beginFrame`.
    var lastScissor: MTLScissorRect?
    var lastViewport: MTLViewport?
    var lastPipeline: (any MTLRenderPipelineState)?

    /// Textures bound by resource ID, with their last binding frame. Retained
    /// and resident, since MTL4 does neither for `gpuResourceID` bindings;
    /// `dropRetired` releases image textures once that frame completes;
    /// persistent atlases retain a `textureRetentionFrames` grace period.
    var boundTextures: [ObjectIdentifier: BoundTexture] = [:]
    struct BoundTexture {
        var texture: MTLTexture
        var lastFrame: UInt64
        var retentionFrames: UInt64
    }
    /// Grace frames before an unbound texture leaves the residency set. Zero
    /// would be correct but would commit the residency set twice a frame for
    /// an atlas bound every frame.
    static let textureRetentionFrames: UInt64 = 60

    /// Replaced allocations — outgrown ring buffers, a superseded rectangle
    /// table, a resized present-by-copy staging texture — tagged with the
    /// frame that last used them; they leave the residency set once the GPU
    /// completes it.
    var retired: [(frame: UInt64, allocation: any MTLAllocation)] = []

    var uploadedInstanceBytes = 0
    var uploadedRectangleBytes = 0

    /// The glyph atlas's rectangle table by version: uploaded once per change,
    /// not copied with every draw of every frame. A change gets a fresh
    /// buffer, so a queued frame keeps reading the table it recorded.
    private var rectangleTable: (version: UInt64, buffer: MTLBuffer)?

    func rectangleTableAddress(_ rects: [SIMD4<UInt16>], version: UInt64) -> MTLGPUAddress? {
        if let rectangleTable, rectangleTable.version == version {
            return rectangleTable.buffer.gpuAddress
        }
        let byteCount = rects.count * MemoryLayout<SIMD4<UInt16>>.stride
        guard let buffer = device.makeBuffer(length: max(16, byteCount), options: .storageModeShared)
        else { return nil }
        rects.withUnsafeBytes { raw in
            if let base = raw.baseAddress { buffer.contents().copyMemory(from: base, byteCount: raw.count) }
        }
        if let old = rectangleTable?.buffer {
            retired.append((frame: frameNumber, allocation: old))
        }
        residencySet.addAllocation(buffer)
        residencySet.commit()
        rectangleTable = (version, buffer)
        uploadedRectangleBytes += byteCount
        return buffer.gpuAddress
    }

    static func isSupported(by device: MTLDevice) -> Bool {
        device.supportsFamily(.metal4)
    }

    /// - Parameter device: a GPU in `MTLGPUFamily.metal4`.
    /// - Parameter slotWaitLimit: the longest `beginFrame` waits for a busy
    ///   slot before dropping the frame.
    public init(device: MTLDevice, slotWaitLimit: DispatchTimeInterval = Metal4Backend.defaultSlotWaitLimit)
        throws
    {
        guard Self.isSupported(by: device) else { throw Metal4BackendError.metal4Unsupported }
        self.device = device
        self.slotWaitLimit = slotWaitLimit
        let queueDescriptor = MTL4CommandQueueDescriptor()
        queueDescriptor.label = "Corta.metal4"
        self.queue = try device.makeMTL4CommandQueue(descriptor: queueDescriptor)
        self.commandBuffers = try (0..<Self.frameSlotCount).map { _ in
            guard let commandBuffer: any MTL4CommandBuffer = device.makeCommandBuffer() else {
                throw Metal4BackendError.commandBufferUnavailable
            }
            return commandBuffer
        }
        self.allocators = try (0..<Self.frameSlotCount).map { _ in
            guard let allocator: any MTL4CommandAllocator = device.makeCommandAllocator() else {
                throw Metal4BackendError.commandAllocatorUnavailable
            }
            return allocator
        }
        // Created at zero and signalled once, not created at one: libdispatch
        // traps when a semaphore is freed below its initial value, which is
        // exactly the state `deinit` leaves every slot in.
        self.slotSemaphores = (0..<Self.frameSlotCount).map { _ in
            let semaphore = DispatchSemaphore(value: 0)
            semaphore.signal()
            return semaphore
        }

        self.argumentTable = try device.makeArgumentTable(descriptor: Self.argumentTableDescriptor())

        let residencyDescriptor = MTLResidencySetDescriptor()
        residencyDescriptor.label = "Corta.metal4"
        let residencySet = try device.makeResidencySet(descriptor: residencyDescriptor)
        self.residencySet = residencySet
        queue.addResidencySet(residencySet)

        // One compile per process, shared by every pane.
        let pipelines = try QuadPipelineCache.entry(for: device)
        func pass(_ pipeline: MTLRenderPipelineState, label: String) -> DrawPass {
            DrawPass(
                ring: InstanceBufferRing(device: device, residencySet: residencySet), pipeline: pipeline,
                label: label)
        }
        self.solidPass = pass(pipelines.solidPipeline, label: "Corta.solid")
        self.glyphPass = pass(pipelines.glyphPipeline, label: "Corta.glyph")
        self.colorGlyphPass = pass(pipelines.colorGlyphPipeline, label: "Corta.colorGlyph")
        self.sampler = pipelines.sampler
    }

    /// buffer(0) instances, buffer(1) uniforms, buffer(2) pixel rectangles,
    /// texture(0) atlas, sampler(0) — as `Shaders.metal` declares.
    private static func argumentTableDescriptor() -> MTL4ArgumentTableDescriptor {
        let descriptor = MTL4ArgumentTableDescriptor()
        descriptor.maxBufferBindCount = 3
        descriptor.maxTextureBindCount = 1
        descriptor.maxSamplerStateBindCount = 1
        descriptor.initializeBindings = true
        descriptor.label = "Corta.quad"
        return descriptor
    }

    /// Releasing address-bound resources mid-execution is an `Invalid
    /// Resource` fault, so wait for every slot's last frame — bounded to a
    /// second in all, since a hung GPU must not hang teardown with it.
    deinit {
        let deadline = DispatchTime.now() + .seconds(1)
        for semaphore in slotSemaphores {
            _ = semaphore.wait(timeout: deadline)
        }
    }

}

// MARK: - Frames

nonisolated extension Metal4Backend {

    /// Opens a frame into `target`, clearing it, so an empty frame still
    /// clears. `label` names the capture. A frame whose slot is still busy is
    /// dropped: nothing encodes, and `endFrame` presents without drawing.
    /// - Returns: whether the frame will be drawn; false for a dropped one.
    @discardableResult
    func beginFrame(target: MTLTexture, clearColor: MTLClearColor, label: String) -> Bool {
        // A frame left open is a bug in `TerminalRenderer.draw`; close it
        // rather than trap.
        if encoder != nil { endFrame(presenting: nil, onCompleted: nil) }
        dropRetired(through: completion.completed)

        let slot = nextSlot
        let wait: DispatchTime = consecutiveDroppedFrames > 0 ? .now() : .now() + slotWaitLimit
        guard slotSemaphores[slot].wait(timeout: wait) == .success else {
            noteDroppedFrame()
            return false
        }
        consecutiveDroppedFrames = 0
        stall = nil
        frameNumber += 1
        currentSlot = slot
        nextSlot = (slot + 1) % Self.frameSlotCount

        let allocator = allocators[slot]
        allocator.reset()
        let commandBuffer = commandBuffers[slot]
        commandBuffer.label = label
        commandBuffer.beginCommandBuffer(allocator: allocator)
        copyTarget = nil
        var target = target
        if presentsByCopy, !target.isFramebufferOnly, let staging = copyStagingTexture(like: target) {
            copyTarget = target
            target = staging
        }
        renderPassDescriptor.colorAttachments[0].texture = target
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = clearColor
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else {
            // Nothing will commit, so the slot is free again.
            commandBuffer.endCommandBuffer()
            slotSemaphores[slot].signal()
            completion.note(frameNumber)
            completion.failed.store(true, ordering: .releasing)
            Metal4Diagnostics.reportCommitFault(Metal4BackendError.commandEncoderUnavailable)
            return false
        }
        encoder.label = label
        self.encoder = encoder
        lastScissor = nil
        lastViewport = nil
        lastPipeline = nil
        uploadedInstanceBytes = 0
        uploadedRectangleBytes = 0
        solidPass.ring.beginFrame()
        glyphPass.ring.beginFrame()
        colorGlyphPass.ring.beginFrame()
        return true
    }

    /// Keeps the existing submission-to-callback metric intact. Native
    /// timestamps distinguish execution from a delayed feedback thread.
    private static func recordGPUTimes(of feedback: any MTL4CommitFeedback) {
        guard RenderMetrics.isEnabled, feedback.gpuStartTime > 0,
            feedback.gpuEndTime >= feedback.gpuStartTime
        else { return }
        RenderMetrics.record(.gpuExecution, milliseconds: (feedback.gpuEndTime - feedback.gpuStartTime) * 1000)
        RenderMetrics.record(
            .gpuFeedbackDelay, milliseconds: max(0, CACurrentMediaTime() - feedback.gpuEndTime) * 1000)
    }

    /// The frame's slot stayed busy past the wait: nothing encodes, and a
    /// run of drops is reported once.
    private func noteDroppedFrame() {
        if stall == nil { stall = (SuspendingClock.now, completion.completed) }
        consecutiveDroppedFrames += 1
        droppedFrameCount += 1
        if consecutiveDroppedFrames == Self.stalledQueueReportThreshold {
            Metal4Diagnostics.reportStalledQueue(droppedFrames: consecutiveDroppedFrames)
        }
        encoder = nil
    }

    func drawSolidQuads(_ instances: ContiguousArray<QuadInstance>, rect: CGRect, drawableSize: CGSize) {
        draw(
            instances, as: solidPass, atlas: nil, rect: rect, drawableSize: drawableSize)
    }

    /// `atlasRectsVersion`: `atlasRects` is the glyph atlas's table at that
    /// version (`GlyphAtlas.atlasRectsVersion`), kept resident between
    /// changes. Without it the table is copied with the draw.
    func drawGlyphQuads(
        _ instances: ContiguousArray<QuadInstance>, atlas: MTLTexture, atlasRects: [SIMD4<UInt16>] = [],
        atlasRectsVersion: UInt64? = nil, rect: CGRect, drawableSize: CGSize
    ) {
        draw(
            instances, as: glyphPass, atlas: atlas, atlasRects: atlasRects, atlasRectsVersion: atlasRectsVersion,
            rect: rect, drawableSize: drawableSize)
    }

    /// Untinted premultiplied sampling: colour glyphs and Kitty images.
    func drawColorQuads(
        _ instances: ContiguousArray<QuadInstance>, atlas: MTLTexture, atlasRects: [SIMD4<UInt16>] = [],
        atlasRectsVersion: UInt64? = nil, rect: CGRect, drawableSize: CGSize,
        imageUVRect: SIMD4<Float> = .zero, transient: Bool = false
    ) {
        draw(
            instances, as: colorGlyphPass, atlas: atlas, atlasRects: atlasRects,
            atlasRectsVersion: atlasRectsVersion, imageUVRect: imageUVRect,
            rect: rect, drawableSize: drawableSize, transientTexture: transient)
    }

    /// Commits and presents `drawable` (nil offscreen). `onCompleted` runs
    /// after the GPU finishes, with the commit's error — or at once with
    /// `.frameDropped` for a frame that was not drawn.
    func endFrame(
        presenting drawable: (any MTLDrawable)?, echoSnapshotAt: TimeInterval? = nil,
        onCompleted: (@Sendable ((any Error)?) -> Void)?
    ) {
        guard let encoder else {
            // An unpresented drawable is never recycled (`FrameScheduler`),
            // so a dropped frame still presents; it shows the drawable's last
            // contents for one refresh.
            if let drawable {
                drawable.present()
            }
            onCompleted?(Metal4BackendError.frameDropped)
            return
        }
        encoder.endEncoding()
        self.encoder = nil
        let commandBuffer = commandBuffers[currentSlot]
        commandBuffer.endCommandBuffer()

        let copyTarget = self.copyTarget
        self.copyTarget = nil
        if copyTarget != nil, let copyCompleted {
            // The staging texture is free once the previous copy finished.
            queue.waitForEvent(copyCompleted, value: copyFrame)
        } else if let drawable {
            // `MTL4CommandQueue`'s contract; a queue-side ordering, not a CPU block.
            queue.waitForDrawable(drawable)
        }
        let options = MTL4CommitOptions()
        let frame = frameNumber
        let completion = completion
        let slotReleased = slotSemaphores[currentSlot]
        // A copied frame completes when both its render and its copy have,
        // with the first error of either: a faulted render under a clean
        // copy must not report the frame as drawn.
        let join = copyTarget == nil ? nil : onCompleted.map(FrameCompletionJoin.init)
        options.addFeedbackHandler { feedback in
            if let error = feedback.error {
                completion.failed.store(true, ordering: .releasing)
                Metal4Diagnostics.reportCommitFault(error)
            }
            completion.note(frame)
            slotReleased.signal()
            if let join { join.complete(feedback.error) } else { onCompleted?(feedback.error) }
            Self.recordGPUTimes(of: feedback)
        }
        queue.commit([commandBuffer], options: options)
        if let copyTarget {
            var copyCompleted: (@Sendable ((any Error)?) -> Void)?
            if let join { copyCompleted = { error in join.complete(error) } }
            copyStaging(
                into: copyTarget, presenting: drawable, echoSnapshotAt: echoSnapshotAt,
                onCompleted: copyCompleted)
        } else if let drawable {
            // After the commits targeting it, before presenting (MTL4 contract).
            queue.signalDrawable(drawable)
            RenderMetrics.notePresent(of: drawable, snapshotAt: echoSnapshotAt)
            drawable.present()
        }
    }

    /// The classic queue's half of `presentsByCopy`: waits for the Metal 4
    /// commit, copies the staging texture to `target`, and presents.
    private func copyStaging(
        into target: MTLTexture, presenting drawable: (any MTLDrawable)?,
        echoSnapshotAt: TimeInterval?, onCompleted: (@Sendable ((any Error)?) -> Void)?
    ) {
        guard let copyQueue, let copyRendered, let copyCompleted, let staging = copyStaging,
            let copy = copyQueue.makeCommandBuffer()
        else {
            // As a dropped frame: the drawable still presents, stale.
            drawable?.present()
            onCompleted?(Metal4BackendError.commandBufferUnavailable)
            return
        }
        copyFrame += 1
        queue.signalEvent(copyRendered, value: copyFrame)
        copy.label = "Corta.presentByCopy"
        // Before any encoder: a wait cannot be encoded while one is open.
        copy.encodeWaitForEvent(copyRendered, value: copyFrame)
        let blit = copy.makeBlitCommandEncoder()
        blit?.copy(from: staging, to: target)
        blit?.endEncoding()
        copy.encodeSignalEvent(copyCompleted, value: copyFrame)
        if let drawable {
            RenderMetrics.notePresent(of: drawable, snapshotAt: echoSnapshotAt)
            copy.present(drawable)
        }
        if let onCompleted { copy.addCompletedHandler { onCompleted($0.error) } }
        copy.commit()
    }

    /// Test seam: the GPU runs no later commit until `event` reaches `value`
    /// — a stalled GPU on demand, for `Metal4BackendTests`.
    func holdQueue(until event: any MTLEvent, reaches value: UInt64) {
        queue.waitForEvent(event, value: value)
    }

}

/// A frame presented by copy finishes on two queues, in either order. Its
/// handler runs once, after both, with the first error either reported.
nonisolated private final class FrameCompletionJoin: Sendable {
    private struct State {
        var remaining = 2
        var error: (any Error)?
    }
    private let state = Mutex(State())
    private let onCompleted: @Sendable ((any Error)?) -> Void
    init(_ onCompleted: @escaping @Sendable ((any Error)?) -> Void) { self.onCompleted = onCompleted }
    func complete(_ error: (any Error)?) {
        let finished = state.withLock { state -> (done: Bool, error: (any Error)?) in
            if state.error == nil { state.error = error }
            state.remaining -= 1
            return (state.remaining == 0, state.error)
        }
        if finished.done { onCompleted(finished.error) }
    }
}
