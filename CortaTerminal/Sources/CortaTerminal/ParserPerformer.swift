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

/// What a parser tells its performer. The parser only recognises shapes;
/// what `CSI 2 J` means is the performer's, which is what lets the state
/// machine be tested against bytes alone.
///
/// Every requirement has a default no-op: an unimplemented sequence must be
/// ignored cleanly (`SECURITY.md` §3), since `xterm-256color` invites
/// sequences Corta does not have.
public protocol ParserPerformer {
    mutating func print(_ scalar: UInt32)

    /// A run of printable ASCII in the ground state — one call instead of a
    /// dispatch per byte on the common path.
    mutating func printASCII(_ bytes: ArraySlice<UInt8>)

    /// A C0 control that acts immediately.
    mutating func execute(_ control: UInt8)

    mutating func escapeDispatch(intermediates: Intermediates, final: UInt8)

    mutating func csiDispatch(_ sequence: CSISequence)

    /// Raw bytes, bounded by `Parser.maxStringLength`: a payload is not
    /// necessarily text.
    mutating func oscDispatch(_ bytes: ArraySlice<UInt8>)

    /// Raw bytes, bounded by `Parser.maxAPCStringLength`; Kitty graphics is
    /// the one user.
    mutating func apcDispatch(_ bytes: ArraySlice<UInt8>)
}

extension ParserPerformer {
    public mutating func printASCII(_ bytes: ArraySlice<UInt8>) {
        for byte in bytes { print(UInt32(byte)) }
    }

    public mutating func escapeDispatch(intermediates: Intermediates, final: UInt8) {}
    public mutating func csiDispatch(_ sequence: CSISequence) {}
    public mutating func oscDispatch(_ bytes: ArraySlice<UInt8>) {}
    public mutating func apcDispatch(_ bytes: ArraySlice<UInt8>) {}
}
