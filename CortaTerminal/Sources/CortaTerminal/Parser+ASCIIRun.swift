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

// MARK: - Printable runs

extension Parser {
    /// Where the run of printable ASCII starting at `start` ends: sixteen
    /// bytes at a time while every lane is printable, then byte by byte.
    @inline(__always)
    static func asciiRunEnd(_ bytes: ArraySlice<UInt8>, from start: Int) -> Int {
        bytes.withUnsafeBytes { raw in
            var end = start + 1
            while end + 16 <= raw.count {
                let lanes = raw.loadUnaligned(fromByteOffset: end, as: SIMD16<UInt8>.self)
                // Wrapping subtraction maps printable ASCII to 0...94;
                // controls and non-ASCII all land above that interval.
                if any((lanes &- SIMD16(repeating: 0x20)) .>= SIMD16(repeating: 0x5F)) { break }
                end += 16
            }
            while end < raw.count, raw[end] >= 0x20, raw[end] < 0x7F { end += 1 }
            return end
        }
    }
}
