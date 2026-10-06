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
import SwiftUI

/// The two accessibility settings the glass views answer to, normally read
/// from SwiftUI's environment. Fixed only by the development build's glass
/// preview (`GlassAppearancePreview`), which shows every combination at once;
/// SwiftUI offers no way to set Reduce Transparency for one view.
struct GlassAccessibility: Equatable {
    var reduceTransparency: Bool
    var increaseContrast: Bool

    /// The edge an opaque or high-contrast surface draws; nil for plain
    /// glass, whose material is its edge.
    var panelBorder: NSColor? {
        if increaseContrast { return .labelColor }
        if reduceTransparency { return .separatorColor }
        return nil
    }
}

extension View {
    /// Liquid Glass in `shape`, or under Reduce Transparency an opaque
    /// window-background fill instead. Not tinted glass: a tinted glass
    /// surface is composited above the view's overlays, and covered the
    /// drawn border both settings together call for (seen in the glass
    /// preview).
    @ViewBuilder
    func cortaGlass<S: Shape>(in shape: S, opaque: Bool) -> some View {
        if opaque {
            background(Color(nsColor: .windowBackgroundColor), in: shape)
        } else {
            glassEffect(.regular, in: shape)
        }
    }
}

/// What the search bar shows, written by `PaneSearch` and read by
/// `SearchBarView`. The field's text is not here: it lives in the
/// `NSSearchField` the bar wraps, which `PaneSearch` owns.
@MainActor
@Observable
final class SearchBarModel {
    var countText = ""
    var caseSensitive = false
    var regex = false
    var onToggleCase: () -> Void = {}
    var onToggleRegex: () -> Void = {}
    var onPrevious: () -> Void = {}
    var onNext: () -> Void = {}
    var onClose: () -> Void = {}
}

/// The pane's find bar: a glass pill floating over the output, in SwiftUI.
///
/// The text field stays an `NSSearchField` (`SearchFieldRepresentable`):
/// `PaneSearch` gives it focus through `makeFirstResponder`, reads Return
/// and Esc through its delegate, and the IME marks text in it as in any
/// AppKit field — none of which a SwiftUI `TextField` in a hosted pane does
/// the same way.
///
/// Reduce Transparency and Increase Contrast are environment values here:
/// an opaque fill and a drawn border, as for the command palette.
struct SearchBarView: View {
    let model: SearchBarModel
    let field: NSSearchField
    /// Nil: the system's settings.
    var accessibilityOverride: GlassAccessibility?

    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.colorSchemeContrast) private var systemContrast

    private var accessibility: GlassAccessibility {
        accessibilityOverride ?? GlassAccessibility(
            reduceTransparency: systemReduceTransparency,
            increaseContrast: systemContrast == .increased)
    }
    private var reduceTransparency: Bool { accessibility.reduceTransparency }
    private var increasedContrast: Bool { accessibility.increaseContrast }

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(Self.symbolFont)
                    .foregroundStyle(.primary)
                    .padding(.trailing, 2)
                SearchFieldRepresentable(field: field)
                    // 200pt when the pane has room; a narrow pane squeezes
                    // the field first, so the bar never runs past its edge.
                    .frame(minWidth: 64, idealWidth: 200, maxWidth: 200)
                    .layoutPriority(-1)
                // Monospaced digits, so the buttons don't twitch as the count
                // changes.
                Text(model.countText)
                    .font(.system(size: NSFont.smallSystemFontSize).monospacedDigit())
                    .foregroundStyle(secondary)
                    .frame(minWidth: 44, alignment: .trailing)
                    .padding(.trailing, 4)
                Divider().frame(height: 16).padding(.trailing, 4)
                toggle("textformat", L10n.text("search.caseSensitive"), isOn: model.caseSensitive,
                    action: model.onToggleCase)
                    .padding(.trailing, -4)
                toggle("asterisk", L10n.text("search.regex"), isOn: model.regex,
                    action: model.onToggleRegex)
                    .padding(.trailing, 2)
                button("chevron.up", "Previous Match", action: model.onPrevious)
                    .padding(.trailing, -4)
                button("chevron.down", "Next Match", action: model.onNext)
                button("xmark", "Close Find", action: model.onClose)
            }
            .padding(EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 8))
            // Untinted: a window-background tint matched the terminal's own
            // background and the pill vanished into it.
            .cortaGlass(in: Capsule(), opaque: reduceTransparency)
            // Glass over a flat terminal background has nothing to refract,
            // so on its own it read as no bar at all: a hairline and a soft
            // shadow lift it off the output. Increase Contrast gets the
            // stronger edge.
            .overlay(Capsule().strokeBorder(borderColor, lineWidth: 1))
            .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The bar as an AppKit view for the pane to place: it sizes itself.
    static func hostingView(model: SearchBarModel, field: NSSearchField) -> NSView {
        let hosting = NSHostingView(rootView: SearchBarView(model: model, field: field))
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.safeAreaRegions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        return hosting
    }

    private static let symbolFont = Font.system(size: 12, weight: .semibold).leading(.tight)

    private var secondary: Color {
        increasedContrast ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor)
    }

    private var borderColor: Color {
        increasedContrast ? Color(nsColor: .labelColor) : Color(nsColor: .separatorColor)
    }

    private func button(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(Self.symbolFont).frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .foregroundStyle(secondary)
        .accessibilityLabel(label)
    }

    /// Tint for a glance; the accessibility value states it outright.
    private func toggle(
        _ symbol: String, _ label: String, isOn: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(Self.symbolFont).frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? Color.accentColor : secondary)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "1" : "0")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The bar's `NSSearchField`, owned by `PaneSearch` and only placed here.
private struct SearchFieldRepresentable: NSViewRepresentable {
    let field: NSSearchField

    func makeNSView(context: Context) -> NSSearchField { field }
    func updateNSView(_ nsView: NSSearchField, context: Context) {}
}
