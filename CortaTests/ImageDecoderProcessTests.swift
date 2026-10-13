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
import Darwin
import Foundation
import Metal
import Testing

@testable import Corta

/// The app side of `corta-image-decoder`: the helper is embedded, and
/// whatever comes back is held to the caps whatever process produced it.
/// `KittyPNGDecodeTests` drives the real helper end to end.
@Suite("Image decoder process")
struct ImageDecoderProcessTests {
    private final class WeakPixels {
        weak var value: ImageDecoderProcess.SharedPixels?
        init(_ value: ImageDecoderProcess.SharedPixels?) { self.value = value }
    }
    private static let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, 0, 0, 0, 1, 0, 0, 0, 1,
    ]

    @Test func dimensionsAreValidatedBeforeAllocating() {
        #expect(ImageDecoderProcess.pngDimensions(Self.png)?.width == 1)
        var bytes = Self.png
        bytes[16] = 255
        #expect(ImageDecoderProcess.pngDimensions(bytes) == nil)
        #expect(ImageDecoderProcess.pngDimensions(Array(Self.png.dropLast())) == nil)
    }
    @Test func noCopyBufferOwnsTheMappingUntilTheTextureIsReleased() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var pixels = ImageDecoderProcess.SharedPixels(
            width: 4, height: 3,
            alignment: device.minimumLinearTextureAlignment(for: .bgra8Unorm))
        _ = try #require(pixels)
        let released = WeakPixels(pixels)
        let descriptor = try #require(pixels).descriptor
        #expect(descriptor >= 4)
        #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
        memset(try #require(pixels).address, 7, try #require(pixels).length)
        var texture = try #require(pixels).texture(device: device, width: 4, height: 3)
        #expect(texture != nil)
        #expect(texture?.buffer != nil)
        pixels = nil
        #expect(released.value != nil)
        texture = nil
        #expect(released.value == nil)
    }

    /// Raw pixels are converted in process: no shared-memory object, no
    /// descriptor, the same page-aligned no-copy texture.
    @Test("in-process pixels map privately, with no descriptor")
    func inProcessPixelsNeedNoSharedObject() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pixels = try #require(ImageDecoderProcess.SharedPixels(
            width: 4, height: 3,
            alignment: device.minimumLinearTextureAlignment(for: .bgra8Unorm), shared: false))
        #expect(pixels.descriptor == -1)
        #expect(Int(bitPattern: pixels.address) % Int(getpagesize()) == 0)
        #expect(pixels.texture(device: device, width: 4, height: 3) != nil)
    }

    @Test("the decoder is embedded beside corta-exec")
    func helperIsEmbedded() throws {
        let helper = try #require(ImageDecoderProcess.bundledHelper)
        #expect(FileManager.default.isExecutableFile(atPath: helper))
        #expect((helper as NSString).deletingLastPathComponent.hasSuffix("Contents/MacOS"))
    }

    @Test("the decoder's sandbox denies a file read")
    func helperSandboxDeniesFiles() throws {
        let helper = try #require(ImageDecoderProcess.bundledHelper)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = ["--check-sandbox"]
        process.environment = [:]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    /// The cap is on pixels; row padding is not the image's. 4097 × 4095 is
    /// under `maximumImagePixels`, and its padded rows pass 64 MiB.
    @Test("an image at the pixel cap with an unaligned width still maps")
    func paddedImageAtThePixelCapFits() throws {
        #expect(4097 * 4095 <= KittyGraphics.maximumImagePixels)
        let pixels = try #require(
            ImageDecoderProcess.SharedPixels(width: 4097, height: 4095, alignment: 256))
        #expect(pixels.length > KittyGraphics.maximumImageBytes)
        #expect(pixels.length <= ImageDecoderProcess.SharedPixels.maximumLength)
        #expect(ImageDecoderProcess.SharedPixels(width: 4097, height: 4096, alignment: 256) == nil)
    }

    @Test("output that disagrees with its own header is refused")
    func outputMustMatchItsHeader() {
        // `cat` hands the input straight back: the PNG signature read as a
        // header claims dimensions far past the caps.
        #expect(ImageDecoderProcess.decodePNG(Self.png, helper: "/bin/cat") == nil)
        #expect(ImageDecoderProcess.decodePNG(Self.png, helper: "/nonexistent/decoder") == nil)
        #expect(ImageDecoderProcess.decodePNG([], helper: "/bin/cat") == nil)
    }

    @Test("a decoder past its deadline, or past the output cap, is cut off")
    func runawayDecodersAreCutOff() {
        #expect(ImageDecoderProcess.decodePNG(Self.png, helper: "/bin/cat", timeout: .zero) == nil)
        // `yes` never stops writing: refused at the cap, not read forever.
        #expect(ImageDecoderProcess.decodePNG(Self.png, helper: "/usr/bin/yes") == nil)
    }

    @Test("a header and exactly its pixels parse; anything else does not")
    func parsing() {
        let header: [UInt8] = [2, 0, 0, 0, 1, 0, 0, 0]
        let pixels = [UInt8](repeating: 7, count: 8)
        #expect(ImageDecoderProcess.parse(header)?.width == 2)
        #expect(ImageDecoderProcess.parse(header)?.height == 1)
        #expect(ImageDecoderProcess.parse(header + pixels) == nil)
        #expect(ImageDecoderProcess.parse(Array(header.dropLast())) == nil)
        #expect(ImageDecoderProcess.parse([0, 0, 0, 0, 1, 0, 0, 0]) == nil)
        #expect(ImageDecoderProcess.parse([0, 0x40, 0, 0, 1, 0, 0, 0]) == nil)  // 16384 wide
    }
}
