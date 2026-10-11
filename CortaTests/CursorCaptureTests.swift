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
import CoreText
import CortaTerminal
import Foundation
import Metal
import Testing

@testable import Corta

@Suite(
    .serialized, .metalSerialized,
    .enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
struct CursorCaptureTests {
    @Test(arguments: ["X", "中", "🦔", "█", "─"], [CGFloat(1), CGFloat(2)])
    func snapshotMatchesThePresentedCursorCell(_ text: String, _ scale: CGFloat) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try TerminalRenderer(
            device: device,
            font: CTFontCreateWithName("Menlo" as CFString, 14, nil), scale: scale)
        var terminal = Terminal(rows: 4, columns: 10)
        terminal.feed(Array(("\u{1b}[2;3H" + text + "\u{1b}[2;3H").utf8))
        let grid = terminal.grid
        let width = Int(renderer.metrics.cellWidth) * 10
        let height = Int(renderer.metrics.cellHeight) * 4
        let target = MetalRenderTarget.make(device: device, width: width, height: height)
        let done = DispatchSemaphore(value: 0)
        renderer.render(
            grid: grid, rect: CGRect(x: 0, y: 0, width: width, height: height),
            drawableSize: CGSize(width: width, height: height), cursorVisible: true,
            selection: nil, target: target, clearColor: MTLClearColorMake(0, 0, 0, 1)
        ) { _ in done.signal() }
        #expect(done.wait(timeout: .now() + 5) == .success)
        let capture = try #require(renderer.cursorImage(grid: grid))
        let image = capture.image
        var expected = [UInt8](repeating: 0, count: image.width * image.height * 4)
        expected.withUnsafeMutableBytes {
            target.getBytes(
                $0.baseAddress!, bytesPerRow: image.width * 4,
                from: MTLRegionMake2D(
                    capture.column * Int(renderer.metrics.cellWidth),
                    grid.cursor.row * Int(renderer.metrics.cellHeight), image.width, image.height),
                mipmapLevel: 0)
        }
        let actual = try #require(image.dataProvider?.data) as Data
        #expect(actual == Data(expected))
    }
}
