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
import Metal

/// Render pipelines and sampler shared across panes: one compile per device
/// per process, every later pane a dictionary lookup. (The binary archive
/// speeds only the first compile per launch.)
///
/// Safe to share because `Entry` is immutable after creation — unlike
/// `GlyphAtlas`, which stays per pane (`TerminalRenderer.init`).
///
/// Keyed by device alone: the library is `makeDefaultLibrary()`, fixed for
/// the process, and Metal doesn't promise the same library object twice.
///
/// `lock` covers lookup and one-time creation, including the archive
/// work, which happens nowhere else.
public nonisolated enum QuadPipelineCache {
    /// The immutable bundle both backends draw with; `let`-only, so sharing
    /// needs no further synchronisation.
    nonisolated final class Entry {
        /// Retained so the `ObjectIdentifier` key can't be recycled.
        let device: MTLDevice
        let solidPipeline: MTLRenderPipelineState
        let glyphPipeline: MTLRenderPipelineState
        /// Premultiplied source blending (see `QuadRenderer`).
        let colorGlyphPipeline: MTLRenderPipelineState
        let sampler: MTLSamplerState

        init(
            device: MTLDevice, solidPipeline: MTLRenderPipelineState,
            glyphPipeline: MTLRenderPipelineState,
            colorGlyphPipeline: MTLRenderPipelineState, sampler: MTLSamplerState
        ) {
            self.device = device
            self.solidPipeline = solidPipeline
            self.glyphPipeline = glyphPipeline
            self.colorGlyphPipeline = colorGlyphPipeline
            self.sampler = sampler
        }
    }

    private static let lock = NSLock()
    // Mutated only under `lock`.
    nonisolated(unsafe) private static var entries: [ObjectIdentifier: Entry] = [:]

    /// The shared entry, created on first ask; a hit is a locked lookup.
    static func entry(for device: MTLDevice) throws -> Entry {
        let key = ObjectIdentifier(device)
        lock.lock()
        defer { lock.unlock() }
        if let entry = entries[key] { return entry }
        let entry = try makeEntry(device: device)
        entries[key] = entry
        return entry
    }

    /// Test hook: forces the cold path, so `QuadRendererTests` sees the
    /// archive rewritten.
    public static func resetForTesting() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    /// Builds the pipelines (identical for both backends, per
    /// `TerminalRenderBackendTests`) through the previous launch's binary
    /// archive, then re-serialises it. Under XCTest the archive read stays off
    /// (`QuadRenderer.isRunningUnderXCTest`).
    private static func makeEntry(device: MTLDevice) throws -> Entry {
        guard let library = device.makeDefaultLibrary() else {
            throw QuadRendererError.libraryUnavailable
        }
        guard let vertexFunction = library.makeFunction(name: "quad_vertex"),
            let solidFragment = library.makeFunction(name: "quad_fragment_solid"),
            let glyphFragment = library.makeFunction(name: "quad_fragment_glyph"),
            let colorGlyphFragment = library.makeFunction(name: "quad_fragment_color")
        else {
            throw QuadRendererError.functionUnavailable
        }

        let archive = QuadRenderer.loadOrCreateBinaryArchive(device: device)

        func makePipeline(fragment: MTLFunction, premultipliedSource: Bool = false) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragment
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = QuadRenderer.pixelFormat
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            // A premultiplied source is already alpha-scaled.
            attachment.sourceRGBBlendFactor = premultipliedSource ? .one : .sourceAlpha
            // Core Animation composites premultiplied, so alpha accumulates as
            // src.a + dst.a*(1-src.a); `.sourceAlpha` squared it.
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            if let archive {
                descriptor.binaryArchives = [archive]
                // Duplicates are accepted, so this seeds and refreshes alike.
                try? archive.addRenderPipelineFunctions(descriptor: descriptor)
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        let solidPipeline = try makePipeline(fragment: solidFragment)
        let glyphPipeline = try makePipeline(fragment: glyphFragment)
        let colorGlyphPipeline = try makePipeline(fragment: colorGlyphFragment, premultipliedSource: true)
        if let archive, let url = QuadRenderer.binaryArchiveURL {
            QuadRenderer.serialize(archive, to: url)
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw QuadRendererError.samplerUnavailable
        }

        return Entry(
            device: device, solidPipeline: solidPipeline, glyphPipeline: glyphPipeline,
            colorGlyphPipeline: colorGlyphPipeline, sampler: sampler)
    }
}
