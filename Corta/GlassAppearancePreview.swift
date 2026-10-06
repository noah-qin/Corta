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

/// The development build's glass preview (`--glass-preview`): the find bar
/// and the command palette in every combination of Reduce Transparency and
/// Increase Contrast, over the terminal's own background, in one window.
/// Those two are system settings, and a check must not change the machine
/// (D13); this shows each branch without them. Light or dark follows the
/// app's `appearance`.
@MainActor
enum GlassAppearancePreview {
    private static var window: NSWindow?

    static func show() {
        let combinations = [
            GlassAccessibility(reduceTransparency: false, increaseContrast: false),
            GlassAccessibility(reduceTransparency: true, increaseContrast: false),
            GlassAccessibility(reduceTransparency: false, increaseContrast: true),
            GlassAccessibility(reduceTransparency: true, increaseContrast: true),
        ]
        let rows = combinations.map {
            PreviewRow(flags: $0, bar: barModel(), field: field(), palette: CommandPaletteModel())
        }
        let hosting = NSHostingView(rootView: PreviewGrid(rows: rows))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Glass Preview"
        window.identifier = NSUserInterfaceItemIdentifier("Corta.GlassPreview")
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.center()
        window.makeKeyAndOrderFront(nil)
        Self.window = window
    }

    private static func barModel() -> SearchBarModel {
        let model = SearchBarModel()
        model.countText = "3/12"
        model.caseSensitive = true
        return model
    }

    private static func field() -> NSSearchField {
        let field = NSSearchField()
        field.stringValue = "README"
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        (field.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        (field.cell as? NSSearchFieldCell)?.cancelButtonCell = nil
        return field
    }
}

private struct PreviewRow {
    let flags: GlassAccessibility
    let bar: SearchBarModel
    let field: NSSearchField
    let palette: CommandPaletteModel
}

private struct PreviewGrid: View {
    let rows: [PreviewRow]

    var body: some View {
        let background = TerminalColorPalette.defaultBackground
        let canvas = Color(
            .sRGB, red: Double(background.x), green: Double(background.y), blue: Double(background.z))
        let foreground = TerminalColorPalette.defaultForeground
        let text = Color(
            .sRGB, red: Double(foreground.x), green: Double(foreground.y), blue: Double(foreground.z))
        Grid(horizontalSpacing: 24, verticalSpacing: 20) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(label(row.flags)).font(.system(size: 11, weight: .semibold)).foregroundStyle(text)
                        .frame(width: 130, alignment: .leading)
                    SearchBarView(model: row.bar, field: row.field, accessibilityOverride: row.flags)
                        .frame(width: 430)
                    CommandPaletteView(model: row.palette, accessibilityOverride: row.flags)
                        .frame(width: 360, height: 150)
                }
            }
        }
        .padding(24)
        .background {
            // Output behind the glass, so there is something to refract.
            ZStack(alignment: .topLeading) {
                canvas
                Text(String(repeating: "drwxr-xr-x  noah  staff  src/  README.md  Package.swift\n", count: 40))
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(text.opacity(0.8))
                    .padding(8)
            }
        }
    }

    private func label(_ flags: GlassAccessibility) -> String {
        switch (flags.reduceTransparency, flags.increaseContrast) {
        case (false, false): "Default"
        case (true, false): "Reduce Transparency"
        case (false, true): "Increase Contrast"
        case (true, true): "Both"
        }
    }
}
#endif
