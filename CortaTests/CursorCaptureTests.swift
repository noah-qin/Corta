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
    func snapshotMatchesThePresentedCursorCell(_ text: String, _ scale: CGFloat) async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try TerminalRenderer(
            device: device,
            font: CTFontCreateWithName("Menlo" as CFString, 14, nil), scale: scale)
        // Settings tests may change the process palette while this test awaits.
        renderer.themeVariant = Theme.corta.dark
        var terminal = Terminal(rows: 4, columns: 10)
        terminal.feed(Array(("\u{1b}[2;3H" + text + "\u{1b}[2;3H").utf8))
        let grid = terminal.grid
        let width = Int(renderer.metrics.cellWidth) * 10
        let height = Int(renderer.metrics.cellHeight) * 4
        let target = MetalRenderTarget.make(device: device, width: width, height: height)
        await withCheckedContinuation { continuation in
            renderer.render(
                grid: grid, rect: CGRect(x: 0, y: 0, width: width, height: height),
                drawableSize: CGSize(width: width, height: height), cursorVisible: true,
                selection: nil, target: target, clearColor: MTLClearColorMake(0, 0, 0, 1)
            ) { _ in continuation.resume() }
        }
        let captured = await renderer.cursorImageAsync(grid: grid)
        let capture = try #require(captured)
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
    @Test("cursor capture releases renderer access before waiting for the GPU")
    func gpuWaitDoesNotHoldRendererLock() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try TerminalRenderer(
            device: device,
            font: CTFontCreateWithName("Menlo" as CFString, 14, nil), scale: 1)
        defer { renderer.cursorCaptureWaitGate = nil }
        renderer.cursorCaptureWaitGate = {
            let entered = DispatchSemaphore(value: 0)
            let thread = Thread {
                _ = renderer.withExclusiveAccess { entered.signal() }
            }
            thread.qualityOfService = .userInitiated
            thread.start()
            #expect(
                entered.wait(timeout: .now() + 5) == .success,
                "a GPU completion must not keep the live renderer locked")
        }
        let terminal = Terminal(rows: 2, columns: 4)
        let capture = await renderer.cursorImageAsync(grid: terminal.grid)
        #expect(capture != nil)
    }

}

/// CPU-only continuation lifetime tests also run on the CI virtual GPU.
struct CursorCaptureCancellationTests {
    @Test("cancellation before capture registration resumes immediately")
    func cancellationBeforeRegistration() async {
        let completion = TerminalRenderer.CursorCaptureCompletion()
        completion.finish(nil)
        let result: TerminalRenderer.CursorImage? = await withCheckedContinuation { continuation in
            if !completion.install(continuation) { continuation.resume(returning: nil) }
        }
        #expect(result == nil)
    }

    @Test("a late GPU callback cannot resume a cancelled capture twice")
    func completionAfterCancellation() async {
        let completion = TerminalRenderer.CursorCaptureCompletion()
        let result: TerminalRenderer.CursorImage? = await withCheckedContinuation { continuation in
            #expect(completion.install(continuation))
            completion.finish(nil)
            completion.finish(nil)
        }
        #expect(result == nil)
    }
}
