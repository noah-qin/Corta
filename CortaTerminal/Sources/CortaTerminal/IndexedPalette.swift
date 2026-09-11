/// The 256-entry indexed palette OSC 4 reports and sets, and OSC 104
/// resets — the per-session overrides on top of a themed default (B06).
/// OSC 5 ("special colours") is a separate, unimplemented interface; this
/// type does not carry it despite the similar name.
///
/// `defaults` is seeded by the app the same way `DynamicColors` is: ANSI
/// 0–15 from the active theme, 16–255 from xterm's fixed 6×6×6 colour cube
/// and 24-step greyscale ramp (`Theme.Variant.indexedPaletteDefaults`,
/// `Corta/Renderer/TerminalColorPalette.swift`'s render-side copy of the
/// same formula — not themed, because xterm defines those numerically and a
/// program asking for colour 137 means one specific colour under every
/// theme). `overrides` is the sparse set of indices OSC 4 has actually
/// changed; OSC 104 clears one, several, or (with no arguments) all of them.
public struct IndexedPalette: Sendable, Equatable {
    // `private(set)`: the 256-entry invariant below is only checked in
    // `init`, and `color(at:)` indexes this array with every `UInt8` — a
    // freely mutable public property would let a caller shrink it and turn
    // the next OSC 4 query into an out-of-bounds trap. Replacing the whole
    // palette (as RIS and the app's theme reseed both do) goes through
    // `init` again and is checked the same way.
    public private(set) var defaults: [(red: UInt8, green: UInt8, blue: UInt8)]
    public internal(set) var overrides: [UInt8: (red: UInt8, green: UInt8, blue: UInt8)] = [:]

    public init(defaults: [(red: UInt8, green: UInt8, blue: UInt8)] = IndexedPalette.xtermDefaults()) {
        precondition(defaults.count == 256, "IndexedPalette.defaults must name all 256 indices")
        self.defaults = defaults
    }

    /// The effective colour for `index`: the OSC 4 override if one is set,
    /// otherwise the default.
    public func color(at index: UInt8) -> (red: UInt8, green: UInt8, blue: UInt8) {
        overrides[index] ?? defaults[Int(index)]
    }

    mutating func setOverride(_ index: UInt8, to color: (red: UInt8, green: UInt8, blue: UInt8)) {
        overrides[index] = color
    }

    /// Replaces `defaults` in place, keeping `overrides` untouched — for a
    /// live theme switch (M6.13), which reseeds what an *unoverridden*
    /// index answers without discarding OSC 4 state a program already set,
    /// the same way `dynamicColors` reseeding never touches OSC 52 state.
    /// Assigning a whole new `IndexedPalette` (RIS, initial session setup)
    /// is the "start over" case this is not: `resetAllOverrides` is what
    /// terminal state itself provides for that.
    public mutating func updateDefaults(
        to newDefaults: [(red: UInt8, green: UInt8, blue: UInt8)]
    ) {
        precondition(newDefaults.count == 256, "IndexedPalette.defaults must name all 256 indices")
        defaults = newDefaults
    }

    /// OSC 104 with no arguments — every index reverts to its default.
    mutating func resetAllOverrides() {
        overrides.removeAll()
    }

    mutating func resetOverride(_ index: UInt8) {
        overrides[index] = nil
    }

    /// xterm's fixed values for indices 16–255: the 6×6×6 colour cube, then
    /// the 24-step greyscale ramp. Indices 0–15 are placeholder black here —
    /// the app overwrites them immediately with its theme's ANSI colours
    /// (`Theme.Variant.indexedPaletteDefaults`), the same split
    /// `TerminalColorPalette.swift`'s `resolve(_:)` makes on the render
    /// side. Internal rather than private: `Theme.Variant
    /// .indexedPaletteDefaults` starts from this array and only replaces
    /// the first sixteen entries.
    public static func xtermDefaults() -> [(red: UInt8, green: UInt8, blue: UInt8)] {
        var values: [(red: UInt8, green: UInt8, blue: UInt8)] = Array(
            repeating: (0, 0, 0), count: 256)
        let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
        for i in 0..<216 {
            values[16 + i] = (levels[i / 36], levels[(i / 6) % 6], levels[i % 6])
        }
        for i in 0..<24 {
            let level = UInt8(8 + i * 10)
            values[232 + i] = (level, level, level)
        }
        return values
    }

    public static func == (lhs: IndexedPalette, rhs: IndexedPalette) -> Bool {
        guard lhs.defaults.count == rhs.defaults.count else { return false }
        for i in 0..<lhs.defaults.count where lhs.defaults[i] != rhs.defaults[i] {
            return false
        }
        guard lhs.overrides.count == rhs.overrides.count else { return false }
        for (index, color) in lhs.overrides {
            guard let other = rhs.overrides[index], other == color else { return false }
        }
        return true
    }
}
