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
import CoreText
import Foundation
import Metal
import Synchronization
import Testing

@testable import Corta

/// `Metal4Backend`, the only renderer: pixel placement and the scissor,
/// frame-slot reuse across frames in flight, teardown with frames in
/// flight, and what a stalled GPU costs — dropped frames, never a blocked
/// render loop. Whole frames against 1.0.1's output are
/// `RenderReferenceTests`.
@Suite(
    "Metal4Backend", .serialized, .metalSerialized,
    .enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
struct Metal4BackendTests {
    /// Reads back one BGRA8 pixel from `texture` at `x, y`.
    private static func pixel(of texture: MTLTexture, x: Int, y: Int) -> (
        r: UInt8, g: UInt8, b: UInt8, a: UInt8
    ) {
        var bytes = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&bytes, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return (r: bytes[2], g: bytes[1], b: bytes[0], a: bytes[3])
    }

    private static let width = 40
    private static let height = 20
    private static let drawableSize = CGSize(width: width, height: height)

    @Test func theBackendAndTheRendererBuildOnThisDevice() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let backend = try Metal4Backend(device: device)
        #expect(backend.device === device)
        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        let renderer = try TerminalRenderer(device: device, font: font, scale: 1)
        #expect(renderer.backend.device === device)
    }

    @Test func aSolidQuadLandsAtItsCentrePixel() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let backend = try Metal4Backend(device: device)
        let texture = MetalRenderTarget.make(device: device, width: Self.width, height: Self.height)
        let red = QuadInstance(origin: .init(0, 0), size: .init(20, 20), color: .init(1, 0, 0, 1))
        #expect(
            backend.renderFrameAndWait(into: texture) {
                $0.drawSolidQuads(
                    [red], rect: CGRect(origin: .zero, size: Self.drawableSize),
                    drawableSize: Self.drawableSize)
            })
        let centre = Self.pixel(of: texture, x: 10, y: 10)
        #expect(centre.r == 255 && centre.g == 0 && centre.b == 0)
    }

    /// Two draws of one frame into two rects — how two panes' worth of the
    /// same content would land — share the frame's one pass.
    @Test func theSameQuadsDrawnIntoTwoRectsOfOneFrameLandInBoth() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let backend = try Metal4Backend(device: device)
        let texture = MetalRenderTarget.make(device: device, width: Self.width, height: Self.height)
        let green = [QuadInstance(origin: .init(0, 0), size: .init(20, 20), color: .init(0, 1, 0, 1))]
        #expect(
            backend.renderFrameAndWait(into: texture) {
                $0.drawSolidQuads(
                    green, rect: CGRect(x: 0, y: 0, width: 20, height: 20),
                    drawableSize: Self.drawableSize)
                $0.drawSolidQuads(
                    green, rect: CGRect(x: 20, y: 0, width: 20, height: 20),
                    drawableSize: Self.drawableSize)
            })
        #expect(Self.pixel(of: texture, x: 5, y: 10).g == 255)
        #expect(Self.pixel(of: texture, x: 25, y: 10).g == 255)
    }

    @Test func aQuadNeverPaintsOutsideItsRect() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let backend = try Metal4Backend(device: device)
        let texture = MetalRenderTarget.make(device: device, width: Self.width, height: Self.height)
        // Geometry past the rect: the scissor, not the instance data, clips it.
        let overflowing = [
            QuadInstance(origin: .init(0, 0), size: .init(100, 100), color: .init(0, 0, 1, 1))
        ]
        #expect(
            backend.renderFrameAndWait(into: texture) {
                $0.drawSolidQuads(
                    overflowing, rect: CGRect(x: 0, y: 0, width: 10, height: 10),
                    drawableSize: Self.drawableSize)
            })
        #expect(Self.pixel(of: texture, x: 5, y: 5).b == 255)
        #expect(Self.pixel(of: texture, x: 20, y: 15).b == 0)
    }

    /// Eight frames through one backend, none waited for until the last: the
    /// command buffers, allocators and every ring slot are each reused while
    /// earlier frames are in flight. The last frame's opaque quad must win
    /// intact — a premature slot rewrite shows up as the wrong colour.
    @Test func ringSlotsAreReusedAcrossFramesInFlight() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // A generous slot wait, so a slow machine waits rather than drops.
        let backend = try Metal4Backend(device: device, slotWaitLimit: frameCompletionTimeout)
        let target = MetalRenderTarget.make(device: device, width: 64, height: 48)
        let colors: [SIMD4<Float>] = [
            .init(1, 0, 0, 1), .init(0, 1, 0, 1), .init(0, 0, 1, 1), .init(1, 1, 0, 1),
            .init(1, 0, 1, 1), .init(0, 1, 1, 1), .init(0.5, 0.25, 1, 1), .init(0.25, 0.5, 1, 1),
        ]
        let size = CGSize(width: 64, height: 48)
        for color in colors.dropLast() {
            backend.beginFrame(target: target, clearColor: MTLClearColorMake(0, 0, 0, 1), label: "Corta.test")
            backend.drawSolidQuads(
                [QuadInstance(origin: .zero, size: .init(64, 48), color: color)],
                rect: CGRect(origin: .zero, size: size), drawableSize: size)
            backend.endFrame(presenting: nil, onCompleted: nil)
        }
        let last = colors.last!
        #expect(
            backend.renderFrameAndWait(into: target) {
                $0.drawSolidQuads(
                    [QuadInstance(origin: .zero, size: .init(64, 48), color: last)],
                    rect: CGRect(origin: .zero, size: size), drawableSize: size)
            })
        #expect(backend.droppedFrameCount == 0)
        let pixel = Self.pixel(of: target, x: 8, y: 8)
        #expect(abs(Int(pixel.b) - Int((last.z * 255).rounded())) <= 1)
        #expect(abs(Int(pixel.g) - Int((last.y * 255).rounded())) <= 1)
        #expect(abs(Int(pixel.r) - Int((last.x * 255).rounded())) <= 1)
        #expect(pixel.a == 255)
    }

    /// A ring buffer that has to grow mid-frame retires the old one rather
    /// than overwrite what an earlier draw of the same frame recorded.
    @Test func aRingThatGrowsMidFrameKeepsTheEarlierDraw() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let backend = try Metal4Backend(device: device)
        let texture = MetalRenderTarget.make(device: device, width: Self.width, height: Self.height)
        let left = [QuadInstance(origin: .init(0, 0), size: .init(10, 20), color: .init(1, 0, 0, 1))]
        // Thousands of instances force the second draw past the first's buffer.
        let many = Array(
            repeating: QuadInstance(origin: .init(20, 0), size: .init(20, 20), color: .init(0, 0, 1, 1)),
            count: 5000)
        #expect(
            backend.renderFrameAndWait(into: texture) {
                $0.drawSolidQuads(left, rect: CGRect(origin: .zero, size: Self.drawableSize), drawableSize: Self.drawableSize)
                $0.drawSolidQuads(many, rect: CGRect(origin: .zero, size: Self.drawableSize), drawableSize: Self.drawableSize)
            })
        #expect(Self.pixel(of: texture, x: 5, y: 10).r == 255)
        #expect(Self.pixel(of: texture, x: 30, y: 10).b == 255)
    }

    /// Releasing the backend while the GPU is still running its frames must
    /// not crash, and the last frame's feedback still arrives.
    @Test func theBackendDeallocatesWithFramesInFlight() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let completion = DispatchSemaphore(value: 0)
        do {
            let backend = try Metal4Backend(device: device)
            let target = MetalRenderTarget.make(device: device, width: Self.width, height: Self.height)
            for index in 0..<5 {
                backend.beginFrame(target: target, clearColor: MTLClearColorMake(0, 0, 0, 1), label: "Corta.test")
                backend.drawSolidQuads(
                    [QuadInstance(origin: .zero, size: .init(20, 20), color: .init(1, 0, 0, 1))],
                    rect: CGRect(origin: .zero, size: Self.drawableSize), drawableSize: Self.drawableSize)
                if index == 4 {
                    backend.endFrame(presenting: nil) { _ in completion.signal() }
                } else {
                    backend.endFrame(presenting: nil, onCompleted: nil)
                }
            }
        }
        #expect(completion.wait(timeout: .now() + frameCompletionTimeout) == .success)
    }

    /// The acceptance test for the completion wait: with the GPU held, the
    /// frame that finds every slot busy waits at most `slotWaitLimit` and is
    /// dropped; the ones after it drop without waiting at all; and once the
    /// GPU moves again, frames draw again. No `Date` deadline, no second-long
    /// stall, no frozen window.
    @Test func aStalledGPUDropsFramesInsteadOfBlocking() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let slotWait = DispatchTimeInterval.milliseconds(50)
        let backend = try Metal4Backend(device: device, slotWaitLimit: slotWait)
        let target = MetalRenderTarget.make(device: device, width: Self.width, height: Self.height)
        let gate = try #require(device.makeSharedEvent())
        backend.holdQueue(until: gate, reaches: 1)

        let dropped = Mutex(0)
        let completed = Mutex(0)
        func frame() -> Double {
            let start = DispatchTime.now()
            backend.beginFrame(target: target, clearColor: MTLClearColorMake(0, 0, 0, 1), label: "Corta.test")
            backend.drawSolidQuads(
                [QuadInstance(origin: .zero, size: .init(20, 20), color: .init(1, 0, 0, 1))],
                rect: CGRect(origin: .zero, size: Self.drawableSize), drawableSize: Self.drawableSize)
            backend.endFrame(presenting: nil) { error in
                if case Metal4BackendError.frameDropped? = error {
                    dropped.withLock { $0 += 1 }
                } else {
                    completed.withLock { $0 += 1 }
                }
            }
            return Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        }

        // Every slot now holds a frame the GPU will not run.
        for _ in 0..<Metal4Backend.frameSlotCount { _ = frame() }
        let firstDrop = frame()
        let laterDrops = (0..<5).map { _ in frame() }
        #expect(dropped.withLock { $0 } == 6)
        #expect(completed.withLock { $0 } == 0)
        #expect(firstDrop >= 40 && firstDrop < 1000, "the first dropped frame waited \(firstDrop) ms")
        #expect(laterDrops.allSatisfy { $0 < 20 }, "later dropped frames waited \(laterDrops) ms")

        // Released, the GPU catches up; until the slot is free a frame still
        // drops without waiting, as the next display-link tick would, and
        // then one draws.
        gate.signaledValue = 1
        let deadline = DispatchTime.now() + frameCompletionTimeout
        var drew = false
        while !drew && DispatchTime.now() < deadline {
            drew = backend.renderFrameAndWait(into: target)
        }
        #expect(drew, "no frame drew after the GPU was released")
        #expect(completed.withLock { $0 } == Metal4Backend.frameSlotCount)
        #expect(backend.droppedFrameCount >= 6)
    }
}

/// The per-device pipeline cache and its binary archive.
@Suite(
    .serialized, .metalSerialized,
    .enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
struct QuadPipelineCacheTests {
    /// A cold pipeline-set creation writes the `MTLBinaryArchive` a later
    /// launch compiles through; this checks the file lands where
    /// `binaryArchiveURL` says. Whether a pipeline was looked up or compiled
    /// is not something Metal exposes to a test.
    @Test func aColdCreationWritesThePipelineArchive() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        guard let url = QuadPipelineCache.binaryArchiveURL else {
            Issue.record("No cache directory available in this environment")
            return
        }
        try? FileManager.default.removeItem(at: url)
        QuadPipelineCache.discardPipelines()
        _ = try Metal4Backend(device: device)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// A second backend is a cache hit and builds with an archive already on
    /// disk. The test plans keep the archive from being read back
    /// (`QuadPipelineCache.readsPreviousArchive` explains why).
    @Test func aSecondBackendBuildsWithTheArchiveOnDisk() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        guard let url = QuadPipelineCache.binaryArchiveURL else {
            Issue.record("No cache directory available in this environment")
            return
        }
        try? FileManager.default.removeItem(at: url)
        QuadPipelineCache.discardPipelines()
        let first = try Metal4Backend(device: device)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let second = try Metal4Backend(device: device)
        #expect(first.device === second.device)
    }
}

/// Needs no GPU family: only the arithmetic of the render target's size.
@Suite struct RenderTargetScaleTests {
    @Test func oneXAndTwoXProduceExpectedPixelDimensions() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        for scale in [1, 2] {
            let texture = MetalRenderTarget.make(device: device, width: 80 * scale, height: 24 * scale)
            #expect(texture.width == 80 * scale)
            #expect(texture.height == 24 * scale)
        }
    }

    @Test func isSupportedAnswersOnAnyDevice() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        _ = Metal4Backend.isSupported(by: device)
    }
}
