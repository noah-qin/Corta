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

enum QuadRendererError: Error {
    case libraryUnavailable
    case functionUnavailable
    case samplerUnavailable
}

/// Draws instanced quads — solid backgrounds or atlas glyphs — into a
/// caller-given rect of a caller-given target, never "the window" (D07).
/// A typical frame is two draw calls (backgrounds, glyphs), plus a third
/// for color glyphs when any exist; "one draw call per screen"
/// (`CONFORMANCE.md` §2.2) forbids a call per cell or row.
///
/// **Colour space.** Colours and the atlas are sRGB-encoded and blend in
/// that space: the target is `.bgra8Unorm`, not `_srgb`, as in xterm,
/// Alacritty and Ghostty. Linear blending waits on stem darkening
/// (`DESIGN.md` §7, hard part 5).
public nonisolated final class QuadRenderer {
    let device: MTLDevice
    private let solidPipeline: MTLRenderPipelineState
    private let glyphPipeline: MTLRenderPipelineState
    /// Returns the premultiplied sample untinted and blends
    /// premultiplied-over.
    private let colorGlyphPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    /// A ring of instance buffers per pipeline kind, so a draw never writes
    /// the buffer an in-flight command buffer reads (`PERFORMANCE.md` §3).
    private final class InstanceBufferRing {
        private var buffers: [MTLBuffer?] = [nil, nil, nil]
        private var next = 0

        /// The next slot holding `bytes`, grown but never shrunk: no steady-state
        /// allocation (`PERFORMANCE.md` §3).
        func buffer(bytes: UnsafeRawPointer, byteCount: Int, device: MTLDevice) -> MTLBuffer? {
            guard byteCount > 0 else { return nil }
            let slot = next
            next = (next + 1) % buffers.count
            if let existing = buffers[slot], existing.length >= byteCount {
                existing.contents().copyMemory(from: bytes, byteCount: byteCount)
                return existing
            }
            guard let fresh = device.makeBuffer(bytes: bytes, length: byteCount, options: .storageModeShared)
            else { return nil }
            buffers[slot] = fresh
            return fresh
        }
    }

    private let solidBufferRing = InstanceBufferRing()
    private let glyphBufferRing = InstanceBufferRing()
    private let colorGlyphBufferRing = InstanceBufferRing()

    /// Every render target's format; the pipelines are built against it.
    public static let pixelFormat: MTLPixelFormat = .bgra8Unorm

    /// Pipelines and sampler come from `QuadPipelineCache`: one compile per
    /// device per process, shared by every pane and `Metal4Backend`.
    public init(device: MTLDevice) throws {
        self.device = device
        let entry = try QuadPipelineCache.entry(for: device)
        self.solidPipeline = entry.solidPipeline
        self.glyphPipeline = entry.glyphPipeline
        self.colorGlyphPipeline = entry.colorGlyphPipeline
        self.sampler = entry.sampler
    }

    /// The compiled-pipeline archive, in `AppPaths.cacheDirectory`: purgeable
    /// and per bundle id, so pruning only touches this build's archives (D22).
    /// Named by `buildFingerprint`, so a rebuild never reads an older build's
    /// cache. Internal for `QuadRendererTests`.
    static var binaryArchiveURL: URL? {
        guard let directory = AppPaths.cacheDirectory else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pruneStaleBinaryArchives(in: directory)
        return directory.appendingPathComponent("QuadRenderer-\(buildFingerprint).metallib-archive")
    }

    /// The executable's modification time, which changes on every rebuild.
    /// A stable `"unknown"` if unreadable still caches correctly.
    private static var buildFingerprint: String {
        guard let url = Bundle.main.executableURL,
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let modified = attributes[.modificationDate] as? Date
        else { return "unknown" }
        return String(Int(modified.timeIntervalSince1970))
    }

    /// Removes other builds' archives, which would otherwise pile up.
    /// Best-effort.
    private static func pruneStaleBinaryArchives(in directory: URL) {
        let current = "QuadRenderer-\(buildFingerprint).metallib-archive"
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else { return }
        for entry in entries
        where entry.lastPathComponent.hasPrefix("QuadRenderer-")
            && entry.lastPathComponent != current
        {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// Writes via a temp file and an atomic `replaceItemAt`, so a reader never
    /// sees a half-written archive. Called from `QuadPipelineCache.makeEntry`.
    static func serialize(_ archive: any MTLBinaryArchive, to url: URL) {
        let temporaryURL =
            url.deletingLastPathComponent()
            .appendingPathComponent("\(UUID().uuidString).tmp")
        guard (try? archive.serialize(to: temporaryURL)) != nil else {
            try? FileManager.default.removeItem(at: temporaryURL)
            return
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
    }

    /// True under XCTest (`XCTestConfigurationFilePath`), where reading an
    /// archive back segfaults inside Metal
    /// (`-[_MTLDevice recordBinaryArchiveUsage:]`, a null C string reaching
    /// `strlen`). Neither a standalone repro nor two real launches crash, and
    /// an upstream report ties the signature to `MTLGetShaderCachePath()`
    /// returning nil — plausibly the hosted-test launch. Only that harness
    /// skips the read.
    private static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Opens the previous launch's archive, or a fresh one under XCTest;
    /// `QuadPipelineCache.makeEntry` adds this launch's pipelines and
    /// re-serialises it. Nil on failure, falling back to a plain compile.
    static func loadOrCreateBinaryArchive(device: MTLDevice) -> (any MTLBinaryArchive)? {
        let descriptor = MTLBinaryArchiveDescriptor()
        if !isRunningUnderXCTest, let url = binaryArchiveURL,
            FileManager.default.fileExists(atPath: url.path)
        {
            descriptor.url = url
        }
        return try? device.makeBinaryArchive(descriptor: descriptor)
    }

    /// Draws solid `instances` into `rect`, in target pixels.
    func drawSolidQuads(
        _ instances: [QuadInstance],
        rect: CGRect,
        drawableSize: CGSize,
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) {
        draw(
            instances, ring: solidBufferRing, pipeline: solidPipeline, atlas: nil, rect: rect,
            drawableSize: drawableSize, renderPassDescriptor: renderPassDescriptor,
            commandBuffer: commandBuffer, label: "Corta.solid")
    }

    func drawGlyphQuads(
        _ instances: [QuadInstance],
        atlas: MTLTexture,
        rect: CGRect,
        drawableSize: CGSize,
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) {
        draw(
            instances, ring: glyphBufferRing, pipeline: glyphPipeline, atlas: atlas, rect: rect,
            drawableSize: drawableSize, renderPassDescriptor: renderPassDescriptor,
            commandBuffer: commandBuffer, label: "Corta.glyph")
    }

    /// Draws from the color atlas: same quads, untinted premultiplied
    /// fragment and blend (`colorGlyphPipeline`).
    func drawColorQuads(
        _ instances: [QuadInstance],
        atlas: MTLTexture,
        rect: CGRect,
        drawableSize: CGSize,
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) {
        draw(
            instances, ring: colorGlyphBufferRing, pipeline: colorGlyphPipeline, atlas: atlas,
            rect: rect, drawableSize: drawableSize, renderPassDescriptor: renderPassDescriptor,
            commandBuffer: commandBuffer, label: "Corta.colorGlyph")
    }

    private func draw(
        _ instances: [QuadInstance],
        ring: InstanceBufferRing,
        pipeline: MTLRenderPipelineState,
        atlas: MTLTexture?,
        rect: CGRect,
        drawableSize: CGSize,
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer,
        label: String
    ) {
        // An empty `.clear` pass still runs, or a blank frame keeps the last one
        // on screen. An empty `.load` pass changes nothing, so skip its tile
        // load/store round trip.
        if instances.isEmpty,
            renderPassDescriptor.colorAttachments[0].loadAction == .load
        {
            return
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else { return }
        encoder.label = label
        encoder.pushDebugGroup(label)
        defer {
            encoder.popDebugGroup()
            encoder.endEncoding()
        }
        guard !instances.isEmpty else { return }

        // The scissor keeps every instance inside `rect`.
        let x = max(0, Int(rect.minX.rounded(.down)))
        let y = max(0, Int(rect.minY.rounded(.down)))
        let maxWidth = max(0, Int(drawableSize.width) - x)
        let maxHeight = max(0, Int(drawableSize.height) - y)
        let width = min(Int(rect.width.rounded(.up)), maxWidth)
        let height = min(Int(rect.height.rounded(.up)), maxHeight)
        guard width > 0, height > 0 else { return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setScissorRect(MTLScissorRect(x: x, y: y, width: width, height: height))
        encoder.setViewport(
            MTLViewport(
                originX: 0, originY: 0,
                width: Double(drawableSize.width), height: Double(drawableSize.height),
                znear: 0, zfar: 1))

        var uniforms = QuadUniforms(
            rectOrigin: SIMD2<Float>(Float(rect.minX), Float(rect.minY)),
            rectSize: SIMD2<Float>(Float(rect.width), Float(rect.height)),
            drawableSize: SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))
        )
        // Not `setVertexBytes`: its 4 KB cap is far below a screen of
        // instances.
        let instanceByteCount = MemoryLayout<QuadInstance>.stride * instances.count
        guard
            let instanceBuffer = instances.withUnsafeBytes({ raw -> MTLBuffer? in
                guard let base = raw.baseAddress else { return nil }
                return ring.buffer(bytes: base, byteCount: instanceByteCount, device: device)
            })
        else { return }
        encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 1)

        if let atlas {
            encoder.setFragmentTexture(atlas, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
        }

        encoder.drawPrimitives(
            type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
    }
}
