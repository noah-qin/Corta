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
import simd

/// Placements drawn from the texture cache, in the frame's one render pass.
nonisolated extension KittyImageRenderer {
    /// Draws visible placements in z-index then transmission order, placed
    /// like `TerminalRenderer.selectionQuads`, into the backend's open
    /// frame. Cache reads only: an uncached placement draws nothing this
    /// frame.
    func draw(
        table: ImagePlacementTable, viewport: ImageViewport, rect: CGRect, drawableSize: CGSize,
        backend: Metal4Backend, drawable: MTLDrawable? = nil
    ) {
        forEachVisiblePlacement(table: table, viewport: viewport) { instance, texture, sourceUVRect, receivedAt in
            backend.drawColorQuads(
                [instance], atlas: texture, rect: rect, drawableSize: drawableSize, imageUVRect: sourceUVRect,
                transient: true)
            if RenderMetrics.isEnabled, let receivedAt, let drawable {
                RenderMetrics.noteImagePresent(of: drawable, receivedAt: receivedAt)
            }
        }
    }

    /// The culling and quad math.
    private func forEachVisiblePlacement(
        table: ImagePlacementTable, viewport: ImageViewport,
        body: (QuadInstance, MTLTexture, SIMD4<Float>, TimeInterval?) -> Void
    ) {
        let cellWidth = viewport.cellWidth
        let cellHeight = viewport.cellHeight
        let placements = table.orderedPlacements().sorted { $0.zIndex < $1.zIndex }
        guard !placements.isEmpty else { return }

        for placement in placements {
            guard let texture = texture(for: placement.imageID) else { continue }

            // `totalPushed`, not `.count` (`TerminalRenderer.selectionQuads`).
            let viewportRow =
                ScrollbackCoordinates.reanchoredRow(
                    placement.row, from: placement.baseScrollbackTotal, to: viewport.scrollbackTotalPushed)
                + viewport.offset
            let columns = placement.columns ?? max(1, Int((Float(texture.width) / cellWidth).rounded(.up)))
            let placementRows =
                placement.rows ?? max(1, Int((Float(texture.height) / cellHeight).rounded(.up)))
            guard viewportRow + placementRows > 0, viewportRow < viewport.rows else { continue }

            let instance = QuadInstance(
                origin: .init(Float(placement.column) * cellWidth, Float(viewportRow) * cellHeight),
                size: .init(placement.displayPixelWidth.map(Float.init) ?? Float(columns) * cellWidth,
                            placement.displayPixelHeight.map(Float.init) ?? Float(placementRows) * cellHeight),
                color: .one, atlasIndex: .max)
            // The arrival time is a metric only: no image lookup per frame without it.
            let receivedAt = RenderMetrics.isEnabled ? table.image(placement.imageID)?.receivedAt : nil
            body(instance, texture, Self.sourceUVRect(for: placement), receivedAt)
        }
    }

    static func sourceUVRect(for placement: KittyGraphics.Placement) -> SIMD4<Float> {
        .init(0, placement.sourceTop, 1, placement.sourceBottom - placement.sourceTop)
    }
}
