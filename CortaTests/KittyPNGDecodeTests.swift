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
import ImageIO
import Testing

@testable import Corta

/// `f=100` means PNG. `CGImageSource` sniffs content, so without a check any
/// program's output reached every ImageIO decoder — TIFF, JPEG, HEIC, PSD —
/// as long as it claimed to be a PNG.
@Suite("Kitty PNG decode")
struct KittyPNGDecodeTests {
    private static func encoded(as type: String) throws -> [UInt8] {
        let context = try #require(
            CGContext(
                data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 16,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data as CFMutableData, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return [UInt8](data as Data)
    }

    @Test("a PNG decodes at its own size")
    func pngDecodes() throws {
        let decoded = try #require(KittyImageRenderer.decodePNG(Self.encoded(as: "public.png")))
        #expect(decoded.width == 4 && decoded.height == 3)
        #expect(decoded.bgra.count == 4 * 3 * 4)
    }

    @Test("another ImageIO format sent as a PNG is refused", arguments: ["public.tiff", "public.jpeg", "com.microsoft.bmp"])
    func otherFormatsAreRefused(type: String) throws {
        let bytes = try Self.encoded(as: type)
        // ImageIO itself reads it, so the refusal is ours.
        #expect(CGImageSourceCreateWithData(Data(bytes) as CFData, nil).flatMap {
            CGImageSourceCreateImageAtIndex($0, 0, nil)
        } != nil)
        #expect(KittyImageRenderer.decodePNG(bytes) == nil)
    }
}
