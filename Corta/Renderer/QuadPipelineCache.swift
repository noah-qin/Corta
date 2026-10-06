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
import Synchronization

enum QuadPipelineError: Error {
    case libraryUnavailable
    case functionUnavailable
    case samplerUnavailable
}

/// Render pipelines and sampler shared across panes: one compile per device
/// per process, every later pane a dictionary lookup. The first compile of a
/// launch goes through the previous launch's `MTLBinaryArchive`.
///
/// **Colour space.** Colours and the atlas are sRGB-encoded and blend in
/// that space: the target is `.bgra8Unorm`, not `_srgb`, as in xterm,
/// Alacritty and Ghostty. Linear blending waits on stem darkening
/// (`DESIGN.md` §7, hard part 5).
///
/// Safe to share because `Entry` is immutable after creation — unlike
/// `GlyphAtlas`, which stays per pane (`TerminalRenderer.init`).
///
/// Keyed by device alone: the library is `makeDefaultLibrary()`, fixed for
/// the process, and Metal doesn't promise the same library object twice.
///
/// `entries`' lock covers lookup and one-time creation, including the
/// archive work, which happens nowhere else.
public nonisolated enum QuadPipelineCache {
    /// Every render target's format; the pipelines are built against it.
    public static let pixelFormat: MTLPixelFormat = .bgra8Unorm

    /// The immutable bundle every pane draws with; `let`-only, and Metal's
    /// device, pipeline and sampler objects are thread-safe, so sharing needs
    /// no further synchronisation.
    nonisolated final class Entry: Sendable {
        /// Retained so the `ObjectIdentifier` key can't be recycled.
        let device: MTLDevice
        let solidPipeline: MTLRenderPipelineState
        let glyphPipeline: MTLRenderPipelineState
        /// Returns the premultiplied sample untinted and blends
        /// premultiplied-over.
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

    private static let entries = Mutex<[ObjectIdentifier: Entry]>([:])

    /// The shared entry, created on first ask; a hit is a locked lookup.
    static func entry(for device: MTLDevice) throws -> Entry {
        let key = ObjectIdentifier(device)
        return try entries.withLock { entries in
            if let entry = entries[key] { return entry }
            let entry = try makeEntry(device: device)
            entries[key] = entry
            return entry
        }
    }

    /// Drops every device's pipelines, so the next renderer compiles them
    /// again — without the archive (`firstCreationDone`) — and re-serialises it:
    /// a cold start without a new process, which the archive tests and the
    /// construction benchmark need.
    public static func discardPipelines() {
        entries.withLock { $0.removeAll() }
    }

    /// Builds the pipelines through the previous launch's binary archive, then
    /// re-serialises it.
    private static func makeEntry(device: MTLDevice) throws -> Entry {
        guard let library = device.makeDefaultLibrary() else {
            throw QuadPipelineError.libraryUnavailable
        }
        guard let vertexFunction = library.makeFunction(name: "quad_vertex"),
            let solidFragment = library.makeFunction(name: "quad_fragment_solid"),
            let glyphFragment = library.makeFunction(name: "quad_fragment_glyph"),
            let colorGlyphFragment = library.makeFunction(name: "quad_fragment_color")
        else {
            throw QuadPipelineError.functionUnavailable
        }

        let archive = loadOrCreateBinaryArchive(device: device)

        func makePipeline(fragment: MTLFunction, premultipliedSource: Bool = false) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragment
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = pixelFormat
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
        if let archive, let url = binaryArchiveURL {
            serialize(archive, to: url)
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw QuadPipelineError.samplerUnavailable
        }

        return Entry(
            device: device, solidPipeline: solidPipeline, glyphPipeline: glyphPipeline,
            colorGlyphPipeline: colorGlyphPipeline, sampler: sampler)
    }

    // MARK: - Binary archive

    /// The compiled-pipeline archive, in `AppPaths.cacheDirectory`: purgeable
    /// and per bundle id, so pruning only touches this build's archives (D22).
    /// Named by `buildFingerprint`, so a rebuild never reads an older build's
    /// cache. Internal for `QuadPipelineCacheTests`.
    static var binaryArchiveURL: URL? {
        guard let directory = AppPaths.cacheDirectory else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pruneStaleBinaryArchives(in: directory)
        return directory.appendingPathComponent("\(archivePrefix)\(buildFingerprint).metallib-archive")
    }

    private static let archivePrefix = "QuadPipelines-"

    /// The executable's modification time, which changes on every rebuild.
    /// A stable `"unknown"` if unreadable still caches correctly.
    private static var buildFingerprint: String {
        guard let url = Bundle.main.executableURL,
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let modified = attributes[.modificationDate] as? Date
        else { return "unknown" }
        return String(Int(modified.timeIntervalSince1970))
    }

    /// Removes every other archive in the directory — older builds', and the
    /// ones 1.0 wrote under another name — which would otherwise pile up.
    /// Best-effort.
    private static func pruneStaleBinaryArchives(in directory: URL) {
        let current = "\(archivePrefix)\(buildFingerprint).metallib-archive"
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else { return }
        for entry in entries
        where entry.pathExtension == "metallib-archive" && entry.lastPathComponent != current
        {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// Writes via a temp file and an atomic `replaceItemAt`, so a reader never
    /// sees a half-written archive.
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

    /// Only a launch's first creation reads the archive. After it the file
    /// is this process's own, not the previous launch's, so a creation after
    /// `discardPipelines()` compiles: the cold start the archive tests and the
    /// construction benchmark ask for (~38 ms, against 6–9 ms through the
    /// archive). It also keeps a hosted test bundle off the read that once
    /// segfaulted inside Metal (`-[_MTLDevice recordBinaryArchiveUsage:]`, a
    /// null C string reaching `strlen`; an upstream report ties it to
    /// `MTLGetShaderCachePath()` returning nil; not reproduced on macOS
    /// 27.0.1): the host's own first creation finds no archive in its
    /// throwaway stage (`AppPaths`). A hosted run with an explicit, reused
    /// `CORTA_STAGE_DIR` reads the last run's at launch, as the app would.
    private static let firstCreationDone = Mutex(false)

    /// Opens the previous launch's archive on the first creation, or a fresh
    /// one; `makeEntry` adds this launch's pipelines and re-serialises it.
    /// Nil on failure, falling back to a plain compile.
    static func loadOrCreateBinaryArchive(device: MTLDevice) -> (any MTLBinaryArchive)? {
        let descriptor = MTLBinaryArchiveDescriptor()
        let isFirst = firstCreationDone.withLock { done in
            defer { done = true }
            return !done
        }
        if isFirst, let url = binaryArchiveURL,
            FileManager.default.fileExists(atPath: url.path)
        {
            descriptor.url = url
        }
        return try? device.makeBinaryArchive(descriptor: descriptor)
    }
}
