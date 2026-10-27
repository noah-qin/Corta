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

/// Kitty image payloads to premultiplied BGRA pixels: raw formats here,
/// PNG and GIF in the sandboxed decoder process.
nonisolated extension KittyImageRenderer {
    /// Premultiplied bgra plus real dimensions, which for PNG may differ from
    /// `s=`/`v=`. Internal for the `decodeImage` hook.
    struct DecodedImage {
        var width: Int
        var height: Int
        var pixels: ImageDecoderProcess.SharedPixels?
        var bgra: [UInt8] { pixels?.packedBytes(width: width, height: height) ?? [] }
        init(width: Int, height: Int, pixels: ImageDecoderProcess.SharedPixels) {
            self.width = width
            self.height = height
            self.pixels = pixels
        }
    }

    static func decode(_ data: KittyGraphics.ImageData, alignment: Int = 256) -> DecodedImage? {
        switch data.format {
        case .rgb:
            return decodeRaw(data, bytesPerPixel: 3, alignment: alignment)
        case .rgba:
            return decodeRaw(data, bytesPerPixel: 4, alignment: alignment)
        case .png:
            return decodePNG(data.bytes, alignment: alignment)
        case .gif:
            guard data.bytes.starts(with: Array("GIF87a".utf8)) || data.bytes.starts(with: Array("GIF89a".utf8)),
                let decoded = ImageDecoderProcess.decodePNG(data.bytes, alignment: alignment, allowGIF: true)
            else { return nil }
            return DecodedImage(width: decoded.width, height: decoded.height, pixels: decoded.pixels)
        }
    }

    private static func decodeRaw(
        _ data: KittyGraphics.ImageData, bytesPerPixel: Int,
        alignment: Int
    ) -> DecodedImage? {
        let width = data.width
        let height = data.height
        guard KittyGraphics.dimensionsFit(width: width, height: height),
            data.bytes.count == width * height * bytesPerPixel,
            let pixels = ImageDecoderProcess.SharedPixels(
                width: width, height: height, alignment: alignment, shared: false)
        else { return nil }
        let destination = pixels.address.assumingMemoryBound(to: UInt8.self)
        data.bytes.withUnsafeBufferPointer { source in
            for row in 0..<height {
                for column in 0..<width {
                    let sourceOffset = (row * width + column) * bytesPerPixel
                    let destinationOffset = row * pixels.bytesPerRow + column * 4
                    let alpha = bytesPerPixel == 4 ? source[sourceOffset + 3] : 255
                    let factor = Float(alpha) / 255
                    destination[destinationOffset] = UInt8((Float(source[sourceOffset + 2]) * factor).rounded())
                    destination[destinationOffset + 1] = UInt8((Float(source[sourceOffset + 1]) * factor).rounded())
                    destination[destinationOffset + 2] = UInt8((Float(source[sourceOffset]) * factor).rounded())
                    destination[destinationOffset + 3] = alpha
                }
            }
        }
        return DecodedImage(width: width, height: height, pixels: pixels)
    }

    /// The eight bytes every PNG starts with (RFC 2083 §3.1).
    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// `f=100` is PNG and nothing else. `CGImageSource` sniffs content, so
    /// unchecked any output could reach every ImageIO parser — TIFF, PSD,
    /// HEIC and the rest — under the name of a PNG: the signature is checked
    /// here, and the decoder process pins the type and the header's
    /// dimensions before it decodes. ImageIO itself runs only in that
    /// process, sandboxed (`ImageDecoderProcess`).
    static func decodePNG(_ bytes: [UInt8], alignment: Int = 256) -> DecodedImage? {
        guard bytes.starts(with: pngSignature), let decoded = ImageDecoderProcess.decodePNG(bytes, alignment: alignment)
        else { return nil }
        return DecodedImage(width: decoded.width, height: decoded.height, pixels: decoded.pixels)
    }
}
