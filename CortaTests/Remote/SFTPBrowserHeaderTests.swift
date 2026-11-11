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

#if DEBUG
import AppKit
import SwiftUI
import Testing

@testable import Corta

/// The SFTP listing's column header (#530). The inset table style draws a
/// separator at the leading edge of every column, so a stray one sat before
/// **Name** with no column on its left; the header is clipped to the first
/// column's leading edge and the separators between columns stay.
@MainActor
struct SFTPBrowserHeaderTests {
    @Test(
        "no divider is drawn left of the first column",
        arguments: [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua]
    )
    func headerHasNoLeadingDivider(_ appearance: NSAppearance.Name) async throws {
        let window = try await Self.showBrowser(appearance: appearance)
        defer {
            window.close()
            Self.model(of: window)?.disconnect()
        }
        let table = try #require(window.contentView.flatMap { Self.table(in: $0) })
        let header = try #require(table.headerView)
        await waitUntil("the header clip") { header.layer?.mask != nil }
        header.layoutSubtreeIfNeeded()
        let bitmap = try #require(header.bitmapImageRepForCachingDisplay(in: header.bounds))
        header.cacheDisplay(in: header.bounds, to: bitmap)
        let scale = Double(bitmap.pixelsWide) / Double(header.bounds.width)
        let leadingLimit = Int(Double(bitmap.pixelsWide) * 0.25)
        let dividers = Self.dividerRuns(in: bitmap)
        #expect(
            dividers.allSatisfy { $0.lowerBound > leadingLimit },
            "a vertical divider was drawn left of the first column: \(dividers.prefix(2))")

        // The dividers between Name, Size and Modified still sit on their
        // column boundaries.
        for column in 0..<(table.numberOfColumns - 1) {
            let boundary = table.rect(ofColumn: column).maxX * scale
            let divider = try #require(
                dividers.first { abs(Double($0.lowerBound + $0.upperBound) / 2 - boundary) <= 4 * scale },
                "no divider at the boundary after column \(column) (\(boundary) px)")
            #expect(divider.lowerBound > leadingLimit)
        }
    }

    /// The connected browser at its minimum window width, in one appearance.
    private static func showBrowser(appearance: NSAppearance.Name) async throws -> NSWindow {
        let model = SFTPBrowserModel(host: "demo.invalid", startDirectory: "/home/demo") { _ in
            SFTPPreviewClient()
        }
        model.isDevelopmentPreview = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentViewController = NSHostingController(rootView: SFTPBrowserView(model: model))
        window.orderFront(nil)
        model.connect()
        await waitUntil("preview connection") { model.connectionState == .connected }
        await waitUntil("the table") { window.contentView.flatMap { table(in: $0) } != nil }
        return window
    }

    private static func model(of window: NSWindow) -> SFTPBrowserModel? {
        let hosting = window.contentViewController as? NSHostingController<SFTPBrowserView>
        return hosting?.rootView.model
    }

    /// Columns of the header that are a vertical line across most of its
    /// height: the separators between column headers. Text and the sort
    /// indicator cover too little of the height to count.
    private static func dividerRuns(in bitmap: NSBitmapImageRep) -> [ClosedRange<Int>] {
        let rows = Array(stride(from: 3, to: bitmap.pixelsHigh - 3, by: 2))
        // Pixels the view does not draw (clipped, transparent) are no colour
        // of their own: the header's background can be opaque or absent
        // depending on the appearance, so only drawn pixels decide a divider.
        func colour(_ x: Int, _ y: Int) -> SIMD4<Double> {
            let value = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
            return SIMD4(
                Double(value.redComponent), Double(value.greenComponent), Double(value.blueComponent),
                Double(value.alphaComponent))
        }
        var counts: [String: Int] = [:]
        for y in rows {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                let value = colour(x, y)
                guard value.w >= 0.5 else { continue }
                counts["\(value.x),\(value.y),\(value.z)", default: 0] += 1
            }
        }
        let background = counts.max { $0.value < $1.value }?.key ?? "0.0,0.0,0.0"
        let parts = background.split(separator: ",").compactMap { Double($0) }
        let backgroundColour = SIMD3(parts[0], parts[1], parts[2])
        var runs: [ClosedRange<Int>] = []
        var runStart: Int?
        for x in 0..<bitmap.pixelsWide {
            var off = 0
            for y in rows {
                let value = colour(x, y)
                guard value.w >= 0.5 else { continue }
                let delta = SIMD3(value.x, value.y, value.z) - backgroundColour
                if abs(delta.x) + abs(delta.y) + abs(delta.z) > 0.08 { off += 1 }
            }
            let isDivider = Double(off) / Double(rows.count) > 0.5
            if isDivider, runStart == nil { runStart = x }
            if !isDivider, let start = runStart {
                runs.append(start...(x - 1))
                runStart = nil
            }
        }
        if let start = runStart { runs.append(start...(bitmap.pixelsWide - 1)) }
        return runs
    }

    private static func table(in view: NSView) -> NSOutlineView? {
        if let table = view as? NSOutlineView { return table }
        return view.subviews.lazy.compactMap { table(in: $0) }.first
    }
}
#endif
