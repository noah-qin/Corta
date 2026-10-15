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

import AppKit
import CoreGraphics
import CoreText
import Metal
import simd

/// Shaping a run with Core Text and rasterising it into a page.
nonisolated extension GlyphAtlas {
    /// One shaped string as a flat list of runs, each with the font Core Text
    /// resolved (possibly a fallback).
    ///
    /// `.notdef` glyphs are dropped (ZWJ can surface as one); `sawNotdef`
    /// reports that every glyph was `.notdef`, so the caller draws a
    /// placeholder.
    func shape(_ string: String, style: Style)
        -> (runs: [ShapedRun], sawNotdef: Bool)
    {
        let requested = fonts[Int(style.rawValue)]
        var sawNotdef = false
        // Use the typed Foundation key instead of bridging a CFString-keyed
        // Swift dictionary (the historical nil-attribute exception site).
        let attributed = NSAttributedString(string: string, attributes: [.font: requested])
        let line = CTLineCreateWithAttributedString(attributed)
        guard let glyphRuns = CTLineGetGlyphRuns(line) as? [CTRun] else { return ([], false) }
        var runs: [ShapedRun] = []
        for run in glyphRuns {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let attributes = CTRunGetAttributes(run) as? [CFString: Any]
            let runFont: CTFont
            if let value = attributes?[kCTFontAttributeName] {
                runFont = value as! CTFont
            } else {
                runFont = requested
            }
            if !CFEqual(runFont, requested) { fallbackHits += 1 }
            // Bitmap fonts draw nothing through `CTFontDrawGlyphs`.
            let isColor = CTFontGetSymbolicTraits(runFont).contains(.traitColorGlyphs)
                || (CTFontCopyPostScriptName(runFont) as String).hasPrefix("AppleColorEmoji")
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            let kept = zip(glyphs, positions).filter { $0.0 != 0 }
            if kept.isEmpty, glyphs.contains(0) { sawNotdef = true }
            guard !kept.isEmpty else { continue }
            runs.append(
                (kept.map(\.0), kept.map(\.1), runFont, isColor,
                 isColor ? run : nil, isColor ? line : nil))
        }
        return (runs, sawNotdef)
    }

    /// Rasterises runs into `page`, caching inkless results too. A color run
    /// goes to `colorPage` instead (`rasterizeColor`).
    func rasterize(_ runs: [ShapedRun], style: Style, page: AtlasPage) -> GlyphInfo {
        if runs.contains(where: \.isColor) {
            return rasterizeColor(runs)
        }
        // No real bold face: stroke as well as fill, a twentieth of an em at
        // each side, so `SGR 1` still reads bold (`TerminalFont.variant`).
        let strokeWidth: CGFloat =
            isSyntheticBold[Int(style.rawValue)]
            ? CTFontGetSize(fonts[Int(style.rawValue)]) * 0.04
            : 0
        let bounds = runs.reduce(CGRect.null) { $0.union(Self.outlineBounds(of: $1)) }
        guard !bounds.isNull, !bounds.isEmpty else {
            return GlyphInfo(uvRect: .zero, size: .zero, bearing: .zero)
        }
        // Pad by a texel against bleed, plus half the synthetic stroke.
        let pad = CGFloat(Self.bitmapPadding) + strokeWidth / 2
        let bbox = bounds.insetBy(dx: -pad, dy: -pad)
        guard bbox.width.isFinite, bbox.height.isFinite,
            bbox.width > 0, bbox.height > 0,
            bbox.width.rounded(.up) <= CGFloat(atlasPixelSize),
            bbox.height.rounded(.up) <= CGFloat(atlasPixelSize - 1)
        else { return GlyphInfo(uvRect: .zero, size: .zero, bearing: .zero, isMissing: true) }
        let width = max(1, Int(bbox.width.rounded(.up)))
        let height = max(1, Int(bbox.height.rounded(.up)))
        guard let origin = allocate(width: width, height: height, in: page),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return GlyphInfo(uvRect: .zero, size: .zero, bearing: .zero) }
        Self.prepareForText(context)
        context.setFillColor(gray: 1, alpha: 1)
        if strokeWidth > 0 {
            context.setStrokeColor(gray: 1, alpha: 1)
            context.setLineWidth(strokeWidth)
            context.setTextDrawingMode(.fillStroke)
        }
        // No CTM flip: the context's top-down buffer and y-up coordinates cancel,
        // and the shader maps quad (0,0) to the region's top row. A flip drew
        // every glyph upside down.
        for run in runs {
            var glyphs = run.glyphs
            var positions = run.positions.map {
                CGPoint(x: $0.x - bbox.minX, y: $0.y - bbox.minY)
            }
            CTFontDrawGlyphs(run.font, &glyphs, &positions, glyphs.count, context)
        }

        guard let data = context.data else {
            return GlyphInfo(uvRect: .zero, size: .zero, bearing: .zero)
        }
        guard ensureHeight(.grayscale, required: origin.y + height) else {
            // The one eviction path, so the page's rectangle indices return too.
            evict(page)
            return GlyphInfo(uvRect: .zero, size: .zero, bearing: .zero, isMissing: true)
        }
        texture.replace(
            region: MTLRegionMake2D(origin.x, origin.y, width, height),
            mipmapLevel: 0, withBytes: data, bytesPerRow: width)

        return placed(at: origin, width: width, height: height, bearing: bbox.origin, in: page)
    }

    /// The color half of `rasterize`, into `colorPage`.
    ///
    /// `CTRunDraw` is the only Core Text call that draws bitmaps, and
    /// `CTRunGetImageBounds` knows their real extent; the text position is set
    /// to `-bbox.origin`. The glyph is drawn scaled so its image, padding
    /// included, fits `colorBox` exactly, and the renderer draws the bitmap
    /// texel for texel. Drawn at the text size and scaled on the GPU instead,
    /// a bitmap emoji came out smaller than its two cells and soft. For a
    /// bitmap emoji the image bounds are the whole design square, so a small
    /// design (🔸) keeps its size against a large one (🔶). Scaling the
    /// context lets Core Text pick the strike for the size drawn. A grayscale run in a mixed cluster draws by outline
    /// in white. Texels upload premultiplied, matching the color pipeline's
    /// blend (`sourceRGB = .one`).
    private func rasterizeColor(_ runs: [ShapedRun]) -> GlyphInfo {
        let empty = GlyphInfo(uvRect: .zero, size: .zero, bearing: .zero, isColor: true)
        // A bitmap's real extent; length 0 means the whole run.
        let bounds = runs.reduce(CGRect.null) { bounds, run in
            bounds.union(
                run.ctRun.map { CTRunGetImageBounds($0, nil, CFRange(location: 0, length: 0)) }
                    ?? Self.outlineBounds(of: run))
        }
        guard !bounds.isNull, !bounds.isEmpty, bounds.width.isFinite, bounds.height.isFinite else { return empty }
        let pad = CGFloat(Self.bitmapPadding)
        let fill = min(
            (colorBox.width - 2 * pad) / bounds.width,
            (colorBox.height - 2 * pad) / bounds.height)
        guard fill.isFinite, fill > 0 else { return empty }
        let scaled = CGRect(
            x: bounds.minX * fill, y: bounds.minY * fill,
            width: bounds.width * fill, height: bounds.height * fill)
        let bbox = scaled.insetBy(dx: -pad, dy: -pad)
        guard bbox.width.isFinite, bbox.height.isFinite,
            bbox.width.rounded(.up) <= CGFloat(atlasPixelSize),
            bbox.height.rounded(.up) <= CGFloat(atlasPixelSize) else { return empty }
        let width = max(1, Int(bbox.width.rounded(.up)))
        let height = max(1, Int(bbox.height.rounded(.up)))
        guard width <= atlasPixelSize, height <= atlasPixelSize else { return empty }
        guard let origin = allocate(width: width, height: height, in: colorPage),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return empty }
        Self.prepareForText(context)
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        // No CTM flip, as in the grayscale path. Positions are in the
        // unscaled space the scale maps onto the bitmap.
        context.scaleBy(x: fill, y: fill)
        let offset = CGPoint(x: bbox.minX / fill, y: bbox.minY / fill)
        for run in runs {
            if let ctRun = run.ctRun {
                context.textPosition = CGPoint(x: -offset.x, y: -offset.y)
                CTRunDraw(ctRun, context, CFRange(location: 0, length: 0))
            } else {
                var glyphs = run.glyphs
                var positions = run.positions.map {
                    CGPoint(x: $0.x - offset.x, y: $0.y - offset.y)
                }
                CTFontDrawGlyphs(run.font, &glyphs, &positions, glyphs.count, context)
            }
        }

        guard let data = context.data else { return empty }
        guard ensureHeight(.color, required: origin.y + height) else {
            evict(colorPage)
            return empty
        }
        colorTexture.replace(
            region: MTLRegionMake2D(origin.x, origin.y, width, height),
            mipmapLevel: 0, withBytes: data, bytesPerRow: width * 4)

        return placed(at: origin, width: width, height: height, bearing: bbox.origin, in: colorPage, isColor: true)
    }

    /// Where an outline run's glyphs draw, from the pen origin: a cluster's
    /// glyphs don't share an origin.
    private static func outlineBounds(of run: ShapedRun) -> CGRect {
        var glyphs = run.glyphs
        var rects = [CGRect](repeating: .zero, count: glyphs.count)
        CTFontGetBoundingRectsForGlyphs(run.font, .horizontal, &glyphs, &rects, glyphs.count)
        return zip(rects, run.positions).reduce(CGRect.null) { bounds, glyph in
            bounds.union(glyph.0.offsetBy(dx: glyph.1.x, dy: glyph.1.y))
        }
    }

    /// Room on `page`; a full page is reset and asked once more.
    private func allocate(width: Int, height: Int, in page: AtlasPage) -> (x: Int, y: Int)? {
        if let origin = page.allocate(width: width, height: height) { return origin }
        evict(page)
        return page.allocate(width: width, height: height)
    }

    private static func prepareForText(_ context: CGContext) {
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(false)  // no subpixel AA since Mojave
    }

    /// The glyph's entry once its texels are uploaded at `origin`.
    private func placed(
        at origin: (x: Int, y: Int), width: Int, height: Int, bearing: CGPoint, in page: AtlasPage,
        isColor: Bool = false
    ) -> GlyphInfo {
        GlyphInfo(
            uvRect: SIMD4<Float>(
                Float(origin.x) / Float(atlasPixelSize), Float(origin.y) / Float(atlasPixelSize),
                Float(width) / Float(atlasPixelSize), Float(height) / Float(atlasPixelSize)),
            atlasIndex: rectangleIndex(page: page, x: origin.x, y: origin.y, width: width, height: height),
            size: SIMD2<Float>(Float(width), Float(height)),
            bearing: SIMD2<Float>(Float(bearing.x), Float(bearing.y)),
            isColor: isColor)
    }
}
