/// OSC 5 ("special colours") reports and sets, and OSC 105 resets — five
/// fixed slots xterm's ctlseqs assigns to `colorBD`/`colorUL`/`colorBL`/
/// `colorRV`/`colorIT` (bold, underline, blink, reverse, italic). A
/// separate interface from `IndexedPalette` (OSC 4/104) despite the
/// similar wire form: OSC 4 addresses 256 numbered slots with a themed
/// default for each; OSC 5 addresses these five fixed, named ones.
///
/// Unlike `IndexedPalette`, there is no themed default to seed here — a
/// slot Corta's renderer has never been told a colour for renders with the
/// terminal's ordinary SGR-attribute handling, not a placeholder colour,
/// so `overrides` is the entire state: empty means "nothing overridden,"
/// not "everything set to black."
public struct SpecialColors: Sendable, Equatable {
    /// The five slots OSC 5's `Pc` parameter addresses (xterm ctlseqs).
    public enum Slot: UInt8, CaseIterable, Sendable {
        case bold = 0
        case underline = 1
        case blink = 2
        case reverse = 3
        case italic = 4
    }

    public internal(set) var overrides: [Slot: (red: UInt8, green: UInt8, blue: UInt8)] = [:]

    public init() {}

    /// The colour OSC 5 set for `slot`, or `nil` if it was never set (or
    /// was reset by OSC 105) — there being no default to fall back to is
    /// the point, see the type's own doc comment.
    public func color(at slot: Slot) -> (red: UInt8, green: UInt8, blue: UInt8)? {
        overrides[slot]
    }

    mutating func setOverride(_ slot: Slot, to color: (red: UInt8, green: UInt8, blue: UInt8)) {
        overrides[slot] = color
    }

    /// OSC 105 with no arguments — every slot reverts to unset.
    mutating func resetAllOverrides() {
        overrides.removeAll()
    }

    mutating func resetOverride(_ slot: Slot) {
        overrides[slot] = nil
    }

    public static func == (lhs: SpecialColors, rhs: SpecialColors) -> Bool {
        guard lhs.overrides.count == rhs.overrides.count else { return false }
        for (slot, color) in lhs.overrides {
            guard let other = rhs.overrides[slot], other == color else { return false }
        }
        return true
    }
}
