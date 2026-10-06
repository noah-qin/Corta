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
import CoreText

/// The font stack: System Monospaced (tracking the OS), then PingFang SC
/// and Apple Color Emoji pinned as `kCTFontCascadeListAttribute`, so
/// fallback is deterministic rather than locale-dependent.
///
/// `CTFontCreateCopyWithSymbolicTraits` drops the cascade list, while
/// `CTFontCreateCopyWithAttributes` keeps it (observed, not documented),
/// so every derivation that matters re-pins it.
nonisolated enum TerminalFont {
    /// The cascade, in order; fallbacks take the primary's size. Immutable,
    /// hence `nonisolated(unsafe)` for the non-`Sendable` descriptors.
    private nonisolated(unsafe) static let cascadeList: [CTFontDescriptor] = [
        CTFontDescriptorCreateWithNameAndSize("PingFangSC-Regular" as CFString, 0),
        CTFontDescriptorCreateWithNameAndSize("AppleColorEmoji" as CFString, 0),
    ]

    /// The primary font, cascade pinned. `.medium` matches Terminal.app's stem
    /// density at 12pt; `.regular` reads soft through the grayscale atlas.
    ///
    /// - Parameter family: nil for System Monospaced. A family that isn't
    ///   installed or that `MonospacedFontCatalog` rejects falls back to the
    ///   system font — the config file can name anything (D12).
    static func primary(ofSize size: CGFloat, family: String? = nil) -> CTFont {
        if let family, family != Configuration.systemFontFamily,
            MonospacedFontCatalog.isUsable(family: family),
            let font = NSFont(name: family, size: size) ?? namedFamily(family, size: size)
        {
            return pinningCascadeList(font as CTFont, size: size)
        }
        let system = NSFont.monospacedSystemFont(ofSize: size, weight: .medium) as CTFont
        return pinningCascadeList(system, size: size)
    }

    /// Resolves a family name ("Menlo"); `NSFont(name:)` wants a face.
    private static func namedFamily(_ family: String, size: CGFloat) -> NSFont? {
        let descriptor = NSFontDescriptor(fontAttributes: [.family: family])
        return NSFont(descriptor: descriptor, size: size)
    }

    /// A styled variant for the atlas, and whether its bold is synthetic.
    /// Neither style may vanish: a missing italic is sheared (advance
    /// unchanged), and a missing bold is stroked at rasterisation, hence the
    /// flag. The trait copy drops the cascade, so it is re-pinned here, or
    /// bold CJK would skip PingFang SC.
    static func variant(of font: CTFont, bold: Bool, italic: Bool)
        -> (font: CTFont, syntheticBold: Bool)
    {
        let size = CTFontGetSize(font)
        guard bold || italic else { return (pinningCascadeList(font, size: size), false) }

        var desired: CTFontSymbolicTraits = []
        if bold { desired.insert(.traitBold) }
        if italic { desired.insert(.traitItalic) }
        let derived =
            CTFontCreateCopyWithSymbolicTraits(font, 0, nil, desired, desired) ?? font
        let actual = CTFontGetSymbolicTraits(derived)

        var styled = derived
        // No italic face: the usual ~12° oblique (tan 12° ≈ 0.21).
        if italic, !actual.contains(.traitItalic) {
            var matrix = CGAffineTransform(a: 1, b: 0, c: 0.21, d: 1, tx: 0, ty: 0)
            styled = CTFontCreateCopyWithAttributes(derived, 0, &matrix, nil)
        }
        return (
            pinningCascadeList(styled, size: size),
            bold && !actual.contains(.traitBold)
        )
    }

    /// The bold variant.
    static func bold(of font: CTFont) -> CTFont {
        variant(of: font, bold: true, italic: false).font
    }

    /// Re-applies the pinned cascade; idempotent.
    static func pinningCascadeList(_ font: CTFont, size: CGFloat) -> CTFont {
        let attributes = [kCTFontCascadeListAttribute: cascadeList] as CFDictionary
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(font), attributes)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }
}
