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
import CortaTerminal
import Foundation
import Metal
import Synchronization
import simd

/// The idle cursor drawn once, offscreen, as an image Core Animation can blink.
nonisolated extension TerminalRenderer {
    /// Uses the very same row instances, atlas and Metal shader as the live
    /// block cursor, including wide glyphs, emoji, rules and box drawing.
    /// The small offscreen target is read only after GPU completion.
    struct CursorImage: Sendable {
        let image: CGImage
        let column: Int
        let columns: Int
    }

    /// One completion wins, including cancellation before registration.
    final class CursorCaptureCompletion: Sendable {
        private struct State {
            var continuation: CheckedContinuation<CursorImage?, Never>?
            var finished = false
        }
        private let state = Mutex(State())

        func install(_ continuation: CheckedContinuation<CursorImage?, Never>) -> Bool {
            state.withLock {
                guard !$0.finished else { return false }
                $0.continuation = continuation
                return true
            }
        }
        func finish(_ image: CursorImage?) {
            let continuation = state.withLock { value -> CheckedContinuation<CursorImage?, Never>? in
                guard !value.finished else { return nil }
                value.finished = true
                defer { value.continuation = nil }
                return value.continuation
            }
            continuation?.resume(returning: image)
        }
    }

    /// Submission is synchronous on the render owner; GPU completion or
    /// cancellation resumes the caller. No lock spans the suspension.
    func cursorImageAsync(grid: Grid) async -> CursorImage? {
        let completion = CursorCaptureCompletion()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard completion.install(continuation) else {
                    continuation.resume(returning: nil)
                    return
                }
                guard !Task.isCancelled else { completion.finish(nil); return }
                if !submitCursorCapture(grid: grid, completed: { completion.finish($0) }) {
                    completion.finish(nil)
                }
            }
        } onCancel: {
            completion.finish(nil)
        }
    }

    private func submitCursorCapture(
        grid: Grid, completed: @escaping @Sendable (CursorImage?) -> Void
    ) -> Bool {
        return withExclusiveAccess {
            let row = grid.cursor.row
            var column = grid.cursor.column
            guard row >= 0, row < grid.rows, column >= 0, column < grid.columns else { return false }
            guard let line = grid.line(atAbsoluteRow: grid.scrollback.totalPushed + row) else {
                return false
            }
            if column < line.count, line[column].attributes.contains(.wideSpacer), column > 0 {
                column -= 1
            }
            let columns = column < line.count && line[column].attributes.contains(.wide) ? 2 : 1
            let width = max(1, Int(metricsValue.cellWidth) * columns)
            let height = max(1, Int(metricsValue.cellHeight))
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.renderTarget, .shaderRead]
            if captureBackend?.requiresRecovery == true {
                // Teardown can wait for GPU work. Keep a hung queue parked;
                // the live cursor keeps blinking until its frames complete.
                guard captureBackend?.hasFramesInFlight == false else { return false }
                captureBackend = nil
            }
            if captureBackend == nil { captureBackend = try? Metal4Backend(device: backend.device) }
            guard let target = backend.device.makeTexture(descriptor: descriptor),
                let capture = captureBackend
            else { return false }
            let previousCursor = blockCursor
            let previousPalette = framePalette
            blockCursor = BlockCursor(row: row, column: column)
            framePalette = themeVariant ?? TerminalColorPalette.activeVariant
            applyDynamicColors(to: &framePalette)
            defer {
                blockCursor = previousCursor
                framePalette = previousPalette
            }
            let quads = cursorCellInstances(line: line, row: row, column: column, graphemes: grid.graphemes)
            let completionGate = cursorCaptureWaitGate
            let capturedColumn = column
            return drawCapture(
                quads, into: target, with: capture, clearColor: framePalette.cursor,
                completed: { image in
                    completionGate?()
                    completed(image.map { CursorImage(image: $0, column: capturedColumn, columns: columns) })
                })
        }
    }

    /// One row's instances, by pipeline.
    private struct CellQuads {
        var backgrounds: ContiguousArray<QuadInstance>
        var glyphs: ContiguousArray<QuadInstance>
        var colors: ContiguousArray<QuadInstance>
    }

    /// The cursor's row built as the live block cursor draws it, moved so
    /// the cursor's cell is at the origin.
    private func cursorCellInstances(
        line: Line, row: Int, column: Int, graphemes: GraphemeTable
    ) -> CellQuads {
        var backgrounds: ContiguousArray<QuadInstance> = []
        var glyphs: ContiguousArray<QuadInstance> = []
        var colors: ContiguousArray<QuadInstance> = []
        appendRowInstances(
            line: line, row: row, graphemes: graphemes,
            background: &backgrounds, glyphs: &glyphs, colorGlyphs: &colors)
        let origin = SIMD2<Float>(
            Float(column) * Float(metricsValue.cellWidth), Float(row) * Float(metricsValue.cellHeight))
        for index in backgrounds.indices { backgrounds[index].origin -= origin }
        for index in glyphs.indices { glyphs[index].origin -= origin }
        for index in colors.indices { colors[index].origin -= origin }
        return CellQuads(backgrounds: backgrounds, glyphs: glyphs, colors: colors)
    }

    /// Submits one frame; the callback runs after the GPU releases its writes.
    private func drawCapture(
        _ quads: CellQuads,
        into target: MTLTexture, with capture: Metal4Backend, clearColor color: SIMD4<Float>,
        completed: @escaping @Sendable (CGImage?) -> Void
    ) -> Bool {
        let size = CGSize(width: target.width, height: target.height)
        let rect = CGRect(origin: .zero, size: size)
        guard
            capture.beginFrame(
                target: target,
                clearColor: MTLClearColorMake(Double(color.x), Double(color.y), Double(color.z), 1),
                label: "Corta.cursor.capture")
        else { return false }
        capture.drawSolidQuads(quads.backgrounds, rect: rect, drawableSize: size)
        capture.drawGlyphQuads(
            quads.glyphs, atlas: glyphAtlas.texture, atlasRects: glyphAtlas.atlasRects,
            atlasRectsVersion: glyphAtlas.atlasRectsVersion,
            rect: rect, drawableSize: size)
        capture.drawColorQuads(
            quads.colors, atlas: glyphAtlas.colorTexture, atlasRects: glyphAtlas.atlasRects,
            atlasRectsVersion: glyphAtlas.atlasRectsVersion,
            rect: rect, drawableSize: size)
        // Metal owns writes until this callback; afterwards this target is
        // immutable. Retain it across GPU completion even if the pane closes.
        nonisolated(unsafe) let retained = target
        capture.endFrame(presenting: nil) { error in
            completed(error == nil ? Self.image(of: retained) : nil)
        }
        return true
    }

    /// A finished `bgra8Unorm` target's pixels as an sRGB image.
    private static func image(of target: MTLTexture) -> CGImage? {
        let width = target.width
        let height = target.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes {
            target.getBytes(
                $0.baseAddress!, bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
            let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                .union(.byteOrder32Little), provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)
    }
}
