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

extension KittyGraphics {
    /// Inflates an `o=z` payload: an RFC 1950 zlib stream, the way kitty and
    /// `kitten icat` compress RGB, RGBA and PNG data.
    ///
    /// The bytes are a program's output, so they are hostile until proven
    /// otherwise: a few kilobytes of DEFLATE can claim gigabytes. Output past
    /// `limit` stops the stream at once and refuses it — the expansion is
    /// never allocated — and so do a header that is not zlib's (method 8,
    /// window ≤ 32 KiB, no preset dictionary, the `FCHECK` multiple of 31) and
    /// an Adler-32 that does not match what was inflated.
    ///
    /// Apple's Compression framework does the DEFLATE itself, as Darwin and
    /// Foundation do the rest of the core's system work (D02 binds no C
    /// library); its `zlib` algorithm is raw DEFLATE, so the two-byte header
    /// and the four-byte checksum are handled here.
    static func inflateZlib(_ input: [UInt8], limit: Int) -> [UInt8]? {
        guard input.count >= 6, limit > 0 else { return nil }
        let cmf = input[0], flg = input[1]
        guard cmf & 0x0F == 8, cmf >> 4 <= 7, flg & 0x20 == 0,
            (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0
        else { return nil }
        let trailer = input[(input.count - 4)...]
        let expectedAdler = trailer.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let body = input[2..<(input.count - 4)]

        struct Overflow: Error {}
        var output: [UInt8] = []
        output.reserveCapacity(min(limit, max(body.count * 4, 4096)))
        do {
            let filter = try OutputFilter(.decompress, using: .zlib) { chunk in
                guard let chunk else { return }
                guard output.count + chunk.count <= limit else { throw Overflow() }
                output.append(contentsOf: chunk)
            }
            // Fed in slices, so an overflow is noticed a slice in, not after
            // the whole input has been expanded.
            var start = body.startIndex
            while start < body.endIndex {
                let end = body.index(start, offsetBy: 64 * 1024, limitedBy: body.endIndex) ?? body.endIndex
                try filter.write(Data(body[start..<end]))
                start = end
            }
            try filter.finalize()
        } catch {
            return nil
        }
        guard adler32(output) == expectedAdler else { return nil }
        return output
    }

    /// RFC 1950 §9's checksum, summed in runs short enough that neither
    /// 32-bit accumulator overflows before the modulo.
    static func adler32(_ bytes: [UInt8]) -> UInt32 {
        let modulus: UInt32 = 65521
        var a: UInt32 = 1, b: UInt32 = 0
        var index = 0
        while index < bytes.count {
            let end = min(index + 5552, bytes.count)
            while index < end {
                a &+= UInt32(bytes[index])
                b &+= a
                index += 1
            }
            a %= modulus
            b %= modulus
        }
        return b << 16 | a
    }
}
