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
import CortaTerminal
import Foundation
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers

@testable import Corta

/// Whole frames compared against recorded references in `RenderReferences/`.
///
/// The references were recorded from the classic Metal path (`QuadRenderer`)
/// before #109 removed it, so these are the before/after comparison that
/// replaced the two-backend pixel equivalence: Metal 4 must draw what 1.0.1
/// drew. `TEST_RUNNER_CORTA_RECORD_RENDER_REFERENCES=1` rewrites them; only
/// for an intended visual change, with every new PNG inspected.
@Suite(
    .serialized, .metalSerialized,
    .enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
struct RenderReferenceTests {
    // MARK: - The scenes

    static let width = 64
    static let height = 48
    /// Smaller than the target, so the scissor is part of the comparison.
    static let rect = CGRect(x: 4, y: 4, width: 56, height: 40)
    static let drawableSize = CGSize(width: width, height: height)
    static let clearColor = MTLClearColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)

    static func makeCoverageTexture(device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: 16, height: 16, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var pixels = [UInt8](repeating: 0, count: 16 * 16)
        for i in pixels.indices { pixels[i] = UInt8(i) }
        texture.replace(
            region: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0,
            withBytes: &pixels, bytesPerRow: 16)
        return texture
    }

    static func makeColorTexture(device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 16, height: 16, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
        for i in 0..<(16 * 16) {
            pixels[i * 4] = UInt8(truncatingIfNeeded: i * 3)
            pixels[i * 4 + 1] = UInt8(truncatingIfNeeded: 255 - i)
            pixels[i * 4 + 2] = UInt8(truncatingIfNeeded: i)
            pixels[i * 4 + 3] = UInt8(truncatingIfNeeded: 128 + i / 2)
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0,
            withBytes: &pixels, bytesPerRow: 16 * 4)
        return texture
    }

    /// Opaque plus overlapping translucent solids (the blend path), glyph
    /// instances sampling coverage, and colour instances sampling the
    /// premultiplied texture.
    static let solidInstances: [QuadInstance] = [
        QuadInstance(origin: .init(0, 0), size: .init(24, 24), color: .init(1, 0, 0, 1)),
        QuadInstance(origin: .init(12, 12), size: .init(24, 24), color: .init(0, 1, 0, 0.5)),
        QuadInstance(origin: .init(32, 4), size: .init(16, 32), color: .init(0, 0, 1, 0.75)),
    ]
    static let glyphInstances: [QuadInstance] = [
        QuadInstance(
            origin: .init(2, 2), size: .init(32, 32), color: .init(1, 1, 0, 0.9),
            uvRect: .init(0, 0, 1, 1)),
        QuadInstance(
            origin: .init(30, 10), size: .init(16, 16), color: .init(0, 1, 1, 1),
            uvRect: .init(0.25, 0.25, 0.5, 0.5)),
    ]
    static let colorInstances: [QuadInstance] = [
        QuadInstance(origin: .init(20, 8), size: .init(24, 24), color: .one, uvRect: .init(0, 0, 1, 1))
    ]

    /// A 4x2-pixel RGBA image, transmitted and placed over 4x2 cells.
    static let kittyImage: [UInt8] = {
        let payload: [UInt8] = [
            255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 0, 255,
            0, 255, 255, 255, 255, 0, 255, 255, 128, 128, 128, 255, 255, 255, 255, 255,
        ]
        let encoded = Data(payload).base64EncodedString()
        return Array("\u{1B}_Ga=T,i=9,f=32,s=4,v=2,c=4,r=2;\(encoded)\u{1B}\\".utf8)
    }()

    /// Text in several renditions, a Kitty image, a selection, two search
    /// matches (one current), a hovered link and the cursor — everything
    /// the overlay and image passes draw, in one 24x10 frame, nothing scrolled.
    static func overlayTerminal() -> Terminal {
        var terminal = Terminal(rows: 10, columns: 24)
        terminal.feed(Array("plain \u{1B}[1mbold\u{1B}[0m \u{1B}[4;31munder\u{1B}[0m\r\n".utf8))
        terminal.feed(Array("\u{1B}[44mblue bg\u{1B}[0m \u{1B}[7mrev\u{1B}[0m find\r\n".utf8))
        terminal.feed(Array("find again\r\n".utf8))
        terminal.feed(kittyImage)
        terminal.feed(Array("\r\n\r\n\r\n$ ".utf8))
        return terminal
    }

    static let overlaySelection = TerminalSelection(
        start: GridPosition(row: 0, column: 2), end: GridPosition(row: 1, column: 3))
    static let overlaySearchMatches = [
        TerminalSelection(start: GridPosition(row: 1, column: 12), end: GridPosition(row: 1, column: 15)),
        TerminalSelection(start: GridPosition(row: 2, column: 0), end: GridPosition(row: 2, column: 3)),
    ]
    static let overlayHoveredLink = TerminalSelection(
        start: GridPosition(row: 2, column: 5), end: GridPosition(row: 2, column: 9))

    // MARK: - Recording and comparison

    static var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("RenderReferences")
    }

    static var isRecording: Bool {
        ProcessInfo.processInfo.environment["CORTA_RECORD_RENDER_REFERENCES"] == "1"
    }

    static func bytes(of texture: MTLTexture) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(
            &pixels, bytesPerRow: texture.width * 4,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return pixels
    }

    /// BGRA, premultiplied-first, little-endian: the render target's layout.
    static let bitmapInfo = CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

    static func writePNG(_ pixels: [UInt8], width: Int, height: Int, to url: URL) throws {
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(
            CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: bitmapInfo, provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent))
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    /// The reference, redrawn into the render target's byte layout.
    static func readPNG(_ url: URL, width: Int, height: Int) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            image.width == width, image.height == height
        else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: bitmapInfo.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    /// Records `texture` as `name`, or compares it with the recorded one.
    /// One code value per channel is blend rounding; more is a difference.
    static func check(
        _ texture: MTLTexture, named name: String, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let url = directory.appendingPathComponent("\(name).png")
        let actual = bytes(of: texture)
        if isRecording {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writePNG(actual, width: texture.width, height: texture.height, to: url)
            return
        }
        guard let expected = readPNG(url, width: texture.width, height: texture.height) else {
            Issue.record("no \(texture.width)x\(texture.height) reference at \(url.path)", sourceLocation: sourceLocation)
            return
        }
        var mismatches = 0
        for i in actual.indices where abs(Int(actual[i]) - Int(expected[i])) > 1 {
            mismatches += 1
        }
        if mismatches > 0 {
            MetalRenderTarget.attachPNG(texture, named: "\(name)-actual.png")
            Attachment.record(try Data(contentsOf: url), named: "\(name)-reference.png")
        }
        #expect(
            mismatches == 0, "\(mismatches) bytes differ from RenderReferences/\(name).png",
            sourceLocation: sourceLocation)
    }

    // MARK: - Rendering

    static func renderQuads(device: MTLDevice, empty: Bool) throws -> MTLTexture {
        let backend = try Metal4Backend(device: device)
        let coverage = try #require(makeCoverageTexture(device: device))
        let color = try #require(makeColorTexture(device: device))
        let target = MetalRenderTarget.make(device: device, width: width, height: height)
        let completed = backend.renderFrameAndWait(into: target, clearColor: clearColor) { backend in
            guard !empty else { return }
            backend.drawSolidQuads(solidInstances, rect: rect, drawableSize: drawableSize)
            backend.drawGlyphQuads(glyphInstances, atlas: coverage, rect: rect, drawableSize: drawableSize)
            backend.drawColorQuads(colorInstances, atlas: color, rect: rect, drawableSize: drawableSize)
        }
        #expect(completed, "the frame never completed")
        return target
    }

    /// Renders the overlay scene with `cursorStyle` (a DECSCUSR parameter),
    /// in the dark theme, after the Kitty image has decoded.
    static func renderOverlays(device: MTLDevice, cursorStyle: Int) throws -> MTLTexture {
        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        let renderer = try TerminalRenderer(device: device, font: font, scale: 1)
        var terminal = overlayTerminal()
        terminal.feed(Array("\u{1B}[\(cursorStyle) q".utf8))
        let grid = terminal.grid
        let width = Int(renderer.metrics.cellWidth) * grid.columns
        let height = Int(renderer.metrics.cellHeight) * grid.rows
        let target = MetalRenderTarget.make(device: device, width: width, height: height)
        let size = CGSize(width: width, height: height)

        let decoded = DispatchSemaphore(value: 0)
        renderer.kittyImageRenderer.onImagesReady = { decoded.signal() }
        renderer.themeVariant = Theme.corta.dark

        func frame() {
            renderer.renderAndWait(
                grid: grid, rect: CGRect(origin: .zero, size: size), drawableSize: size,
                cursorVisible: true, selection: overlaySelection,
                searchMatches: overlaySearchMatches, currentSearchMatchIndex: 0,
                hoveredLink: overlayHoveredLink, target: target)
        }
        frame()
        #expect(decoded.wait(timeout: .now() + frameCompletionTimeout) == .success, "the Kitty image never decoded")
        renderer.invalidate()
        frame()
        return target
    }

    // MARK: - Tests

    @Test func quadsMatchTheReference() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        try Self.check(try Self.renderQuads(device: device, empty: false), named: "quads")
    }

    /// An empty frame still clears, or a blank grid leaves the last frame up.
    @Test func anEmptyFrameClearsToTheReference() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        try Self.check(try Self.renderQuads(device: device, empty: true), named: "empty-frame")
    }

    @Test(arguments: [(2, "overlays-block-cursor"), (4, "overlays-underline-cursor"), (6, "overlays-bar-cursor")])
    func overlaysMatchTheReference(cursorStyle: Int, name: String) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        try Self.check(try Self.renderOverlays(device: device, cursorStyle: cursorStyle), named: name)
    }
}
