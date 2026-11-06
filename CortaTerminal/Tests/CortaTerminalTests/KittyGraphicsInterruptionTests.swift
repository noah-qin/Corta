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

@testable import CortaTerminal

/// What ends an unfinished transmission. The protocol's rule is about graphics
/// commands: "the client must finish sending all chunks for a single image
/// before sending any other graphics related escape codes", and "if an image
/// is being loaded in chunks and the upload is not complete when any delete
/// command is received, the partial upload must be aborted". Text and other
/// sequences between chunks are not a client error (a program's output keeps
/// flowing), and what they leave held is already charged to the budget.
@Suite("Kitty graphics, interrupted")
struct KittyGraphicsInterruptionTests {
    private static func apc(_ control: String, payload: String = "") -> [UInt8] {
        Array("\u{1B}_G\(control);\(payload)\u{1B}\\".utf8)
    }

    /// 2 x 2 RGBA in two chunks; the first is a multiple of three bytes, so
    /// its base64 needs no padding and the two concatenate.
    private static let first = Data(repeating: 0xFF, count: 9).base64EncodedString()
    private static let second = Data(repeating: 0xFF, count: 7).base64EncodedString()

    @Test("text, CSI and OSC between chunks neither end the transmission nor uncharge it")
    func unrelatedOutputLeavesTheTransmissionOpenAndCharged() {
        var terminal = Terminal(rows: 10, columns: 40)
        terminal.feed(Self.apc("a=T,i=1,f=32,s=2,v=2,q=2,m=1", payload: Self.first))
        #expect(terminal.retainedImageBytes == 9)

        terminal.feed(Array("text\u{1B}[2;2H\u{1B}[31m\u{1B}]2;title\u{1B}\\".utf8))
        #expect(terminal.retainedImageBytes == 9, "still held, so still charged")
        #expect(terminal.grid.imagePlacements.imageCount == 0)

        terminal.feed(Self.apc("m=0", payload: Self.second))
        #expect(terminal.grid.imagePlacements.imageCount == 1, "the chunks completed one image")
    }

    @Test("what an interrupted transmission holds stays under the pane's budget")
    func anInterruptedTransmissionCannotExceedTheBudget() {
        var terminal = Terminal(rows: 4, columns: 10)
        terminal.grid.imagePlacements.maximumStoredBytes = 300
        let chunk = Data(repeating: 0xAA, count: 210).base64EncodedString()
        terminal.feed(Self.apc("a=t,f=100,i=1,q=2,m=1", payload: chunk))
        terminal.feed(Array("output\u{1B}[H".utf8))
        #expect(terminal.retainedImageBytes == 210)
        terminal.feed(Self.apc("m=1", payload: chunk))
        #expect(terminal.retainedImageBytes == 0, "past the budget the transmission is dropped, not held")
    }

    @Test("any delete command aborts a partial upload, as the protocol requires")
    func aDeleteAbortsThePartialUpload() {
        for delete in ["a=d,d=a", "a=d,d=i,i=99"] {
            var terminal = Terminal(rows: 10, columns: 40)
            terminal.feed(Self.apc("a=T,i=1,f=32,s=2,v=2,q=2,m=1", payload: Self.first))
            #expect(terminal.retainedImageBytes == 9)
            terminal.feed(Self.apc(delete))
            #expect(terminal.retainedImageBytes == 0, "\(delete) left the upload held")
        }
    }
}
