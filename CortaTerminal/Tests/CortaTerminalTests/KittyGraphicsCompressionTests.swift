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

import Compression
import Foundation
import Testing

@testable import CortaTerminal

/// `o=z`: zlib-compressed image data, which `kitten icat` sends whenever it
/// scales an image to fit. Before it was understood, the compressed bytes
/// were taken as pixels, failed the size check, and the image never showed.
@Suite("Kitty graphics, compressed")
struct KittyGraphicsCompressionTests {
    private static func apc(_ control: String, payload: String = "") -> [UInt8] {
        Array("\u{1B}_G\(control);\(payload)\u{1B}\\".utf8)
    }

    /// An RFC 1950 stream the way zlib writes one: header, raw DEFLATE,
    /// big-endian Adler-32.
    static func zlib(_ bytes: [UInt8]) throws -> [UInt8] {
        var deflated = Data()
        let filter = try OutputFilter(.compress, using: .zlib) { chunk in
            if let chunk { deflated.append(chunk) }
        }
        try filter.write(Data(bytes))
        try filter.finalize()
        let adler = KittyGraphics.adler32(bytes)
        return [0x78, 0x9C] + [UInt8](deflated)
            + [UInt8(adler >> 24), UInt8(adler >> 16 & 0xFF), UInt8(adler >> 8 & 0xFF), UInt8(adler & 0xFF)]
    }

    private static func pixels(_ count: Int) -> [UInt8] {
        (0..<count * 4).map { UInt8(truncatingIfNeeded: $0 &* 37) }
    }

    @Test("a compressed RGBA image is stored as its pixels and placed")
    func compressedRGBA() throws {
        var terminal = Terminal(rows: 10, columns: 40)
        let raw = Self.pixels(64 * 32)
        let payload = Data(try Self.zlib(raw)).base64EncodedString()
        terminal.feed(Self.apc("a=T,i=4,f=32,s=64,v=32,o=z", payload: payload))
        let image = try #require(terminal.grid.imagePlacements.image(KittyGraphics.ImageID(rawValue: 4)))
        #expect(image.bytes == raw)
        #expect(terminal.grid.imagePlacements.orderedPlacements().count == 1)
        #expect(terminal.takeOutput() == Array("\u{1B}_Gi=4;OK\u{1B}\\".utf8))
    }

    @Test("compression is read off the first chunk and applied once the last one is in")
    func compressedChunks() throws {
        var terminal = Terminal(rows: 10, columns: 40)
        let raw = Self.pixels(40 * 40)
        let whole = Data(try Self.zlib(raw)).base64EncodedString()
        let cut = whole.index(whole.startIndex, offsetBy: (whole.count / 2) / 4 * 4)
        terminal.feed(Self.apc("a=T,i=5,f=32,s=40,v=40,o=z,m=1", payload: String(whole[..<cut])))
        #expect(terminal.grid.imagePlacements.imageCount == 0)
        terminal.feed(Self.apc("i=5,m=0", payload: String(whole[cut...])))
        #expect(terminal.grid.imagePlacements.image(KittyGraphics.ImageID(rawValue: 5))?.bytes == raw)
    }

    @Test("a compressed PNG is inflated to the PNG the app decodes")
    func compressedPNG() throws {
        var terminal = Terminal(rows: 10, columns: 40)
        // Any bytes stand in for the PNG: the core passes PNG data through.
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 7, count: 500)
        let payload = Data(try Self.zlib(png)).base64EncodedString()
        terminal.feed(Self.apc("a=t,i=6,f=100,o=z", payload: payload))
        #expect(terminal.grid.imagePlacements.image(KittyGraphics.ImageID(rawValue: 6))?.bytes == png)
    }

    /// A few kilobytes that would inflate to many megabytes: the expansion
    /// stops at the declared size and is refused, never allocated whole.
    @Test("a stream that inflates past its declared size is refused")
    func decompressionBombIsRefused() throws {
        var terminal = Terminal(rows: 10, columns: 40)
        let bomb = try Self.zlib(Array(repeating: 0, count: 32 * 1024 * 1024))
        #expect(bomb.count < 64 * 1024, "the fixture is a real bomb: \(bomb.count) bytes in")
        let payload = Data(bomb).base64EncodedString()
        terminal.feed(Self.apc("a=T,i=8,f=32,s=8,v=8,o=z", payload: payload))
        #expect(terminal.grid.imagePlacements.imageCount == 0)
        #expect(terminal.takeOutput() == Array("\u{1B}_Gi=8;EINVAL:bad compressed data\u{1B}\\".utf8))
    }

    @Test("a stream shorter than the declared pixels is refused")
    func shortStreamIsRefused() throws {
        var terminal = Terminal(rows: 10, columns: 40)
        let payload = Data(try Self.zlib(Self.pixels(4))).base64EncodedString()
        terminal.feed(Self.apc("a=T,i=9,f=32,s=8,v=8,o=z", payload: payload))
        #expect(terminal.grid.imagePlacements.imageCount == 0)
    }

    @Test("a damaged header or checksum is refused")
    func damagedStreamIsRefused() throws {
        let raw = Self.pixels(16)
        var badHeader = try Self.zlib(raw)
        badHeader[1] ^= 0x01  // FCHECK no longer a multiple of 31
        var badChecksum = try Self.zlib(raw)
        badChecksum[badChecksum.count - 1] ^= 0xFF
        var presetDictionary = try Self.zlib(raw)
        presetDictionary[1] = 0xBB  // FDICT set, FCHECK still valid (0x78BB % 31 == 0)
        for stream in [badHeader, badChecksum, presetDictionary, [0x78, 0x9C]] {
            #expect(KittyGraphics.inflateZlib(stream, limit: 64) == nil)
        }
        #expect(KittyGraphics.inflateZlib(try Self.zlib(raw), limit: 64) == raw)
    }

    @Test("an unknown compression is refused, not taken as pixels")
    func unknownCompressionIsRefused() {
        var terminal = Terminal(rows: 10, columns: 40)
        let payload = Data(Self.pixels(4)).base64EncodedString()
        terminal.feed(Self.apc("a=T,i=10,f=32,s=2,v=2,o=x", payload: payload))
        #expect(terminal.grid.imagePlacements.imageCount == 0)
    }

    @Test("Adler-32 matches RFC 1950's definition")
    func adler32() {
        #expect(KittyGraphics.adler32(Array("Wikipedia".utf8)) == 0x11E6_0398)
        #expect(KittyGraphics.adler32([]) == 1)
        // Long enough to cross the run length the sums are folded at.
        #expect(KittyGraphics.adler32(Array(repeating: 0xFF, count: 100_000)) == 0x149A_302C, "zlib.adler32 agrees")
    }
}
