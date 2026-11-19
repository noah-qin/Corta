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

/// What the compose field shows besides its text, written by `PaneComposer`.
/// The text itself lives in the `NSTextView` the field wraps.
@MainActor
@Observable
final class ComposerModel {
    var isEmpty = true
    var onSend: () -> Void = {}
    var onClose: () -> Void = {}
}

/// The compose field: a native text view on the command palette's rounded
/// glass, with Close and Send as capsule buttons.
///
/// The text stays an AppKit `NSTextView` (`ComposerTextRepresentable`): input
/// methods mark text in it, and its keys and focus are AppKit's, as the find
/// bar's field is. Reduce Transparency and Increase Contrast are environment
/// values: an opaque fill and a drawn border, as for the palette.
struct ComposerView: View {
    let model: ComposerModel
    let scrollView: NSScrollView
    /// Nil: the system's settings.
    var accessibilityOverride: GlassAccessibility?

    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.colorSchemeContrast) private var systemContrast

    private var accessibility: GlassAccessibility {
        accessibilityOverride ?? GlassAccessibility(
            reduceTransparency: systemReduceTransparency,
            increaseContrast: systemContrast == .increased)
    }

    /// The palette's shape, a little tighter for a smaller surface.
    private static let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

    var body: some View {
        GlassEffectContainer {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    ComposerTextRepresentable(scrollView: scrollView)
                        .frame(maxWidth: .infinity, minHeight: 40, maxHeight: .infinity)
                    if model.isEmpty {
                        // Over the text view's first line, inset as its text is.
                        Text(L10n.text("composer.placeholder"))
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 9)
                            .padding(.top, 6)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                // Kept beyond the glass container's merge distance from the
                // text, as the connect sheet keeps its actions.
                HStack(spacing: 12) {
                    Text(L10n.text("composer.hint"))
                        .font(.system(size: 11))
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityHidden(true)
                    Spacer(minLength: 8)
                    Button(action: model.onClose) {
                        Text(L10n.text("common.close")).frame(minWidth: 56)
                    }
                    .buttonStyle(.glass)
                    Button(action: model.onSend) {
                        Text(L10n.text("composer.send")).frame(minWidth: 56)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(model.isEmpty)
                    .help(L10n.text("composer.hint"))
                }
                .buttonBorderShape(.capsule)
            }
            .padding(12)
            .cortaGlass(in: Self.shape, opaque: accessibility.reduceTransparency)
            .overlay {
                // Glass over a flat terminal background has nothing to
                // refract: a hairline lifts it, the stronger edge under
                // Increase Contrast.
                Self.shape.strokeBorder(borderColor, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("composer.label"))
    }

    private var secondary: Color {
        accessibility.increaseContrast
            ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor)
    }

    private var borderColor: Color {
        Color(nsColor: accessibility.panelBorder ?? .separatorColor)
    }

    /// The field as an AppKit view for the pane to place; the pane's
    /// constraints size it.
    static func hostingView(model: ComposerModel, scrollView: NSScrollView) -> NSView {
        let hosting = NSHostingView(rootView: ComposerView(model: model, scrollView: scrollView))
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.setAccessibilityIdentifier("composer")
        return hosting
    }
}

/// The field's scroll view and text view, owned by `PaneComposer` and only
/// placed here.
private struct ComposerTextRepresentable: NSViewRepresentable {
    let scrollView: NSScrollView

    func makeNSView(context: Context) -> NSScrollView { scrollView }
    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
