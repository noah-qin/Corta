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
import Testing
@testable import Corta

struct ImagePlacementScrollTests {
    @Test func clippedRegionPlacementUsesTheRetainedSourcePixels() throws {
        var terminal = Terminal(rows: 8, columns: 20)
        terminal.feed(Array("\u{1B}[3;1H".utf8))
        let payload = Data(repeating: 0xFF, count: 16).base64EncodedString()
        terminal.feed(Array("\u{1B}_Ga=T,q=2,i=1,f=32,s=2,v=2,c=2,r=2;\(payload)\u{1B}\\".utf8))
        terminal.feed(Array("\u{1B}[2;7r\u{1B}[2S".utf8))
        let placement = try #require(terminal.grid.imagePlacements.orderedPlacements().first)
        let uv = KittyImageRenderer.sourceUVRect(for: placement)
        #expect(uv == SIMD4<Float>(0, 0.5, 1, 0.5))
    }
}
