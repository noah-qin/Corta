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
import Testing

@testable import Corta

/// The app side of `corta-image-decoder`: the helper is embedded, and
/// whatever comes back is held to the caps whatever process produced it.
/// `KittyPNGDecodeTests` drives the real helper end to end.
@Suite("Image decoder process")
struct ImageDecoderProcessTests {
    private static let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3]

    @Test("the decoder is embedded beside corta-exec")
    func helperIsEmbedded() throws {
        let helper = try #require(ImageDecoderProcess.bundledHelper)
        #expect(FileManager.default.isExecutableFile(atPath: helper))
        #expect((helper as NSString).deletingLastPathComponent.hasSuffix("Contents/MacOS"))
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
        #expect(ImageDecoderProcess.parse(header + pixels)
            == .init(width: 2, height: 1, bgra: pixels))
        #expect(ImageDecoderProcess.parse(header + pixels.dropLast()) == nil)
        #expect(ImageDecoderProcess.parse([0, 0, 0, 0, 1, 0, 0, 0]) == nil)
        #expect(ImageDecoderProcess.parse([0, 0x40, 0, 0, 1, 0, 0, 0]) == nil)  // 16384 wide
    }
}
