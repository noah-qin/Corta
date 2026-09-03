/// M6.9 — the kitty keyboard protocol's progressive-enhancement flags.
///
/// The legacy encoding is ambiguous in ways that matter to editors: `Ctrl+I`
/// and `Tab` are both `0x09`, `Ctrl+M` and `Return` are both `0x0D`, and
/// `Esc` is indistinguishable from the start of an escape sequence. A
/// Neovim mapping that binds `Ctrl+I` and `Tab` differently cannot work
/// until the terminal stops sending the same byte for both.
///
/// `disambiguate` and `reportEventTypes` are implemented. The remaining flags are declared
/// because the protocol's `CSI ? u` query has to report the whole word, and
/// a program that sets one Corta does not honour must be able to see that it
/// did not take — reporting flags Corta ignores would be worse than
/// reporting none.
public struct KeyboardEnhancementFlags: OptionSet, Sendable, Equatable {
    public var rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Bit 1 — send unambiguous escape codes for keys the legacy encoding
    /// collides.
    public static let disambiguate = KeyboardEnhancementFlags(rawValue: 1)
    /// Bit 2 — report key press, repeat and release as separate events.
    public static let reportEventTypes = KeyboardEnhancementFlags(rawValue: 2)
    /// Bit 4 — report shifted and base-layout keys alongside the key code.
    public static let reportAlternateKeys = KeyboardEnhancementFlags(rawValue: 4)
    /// Bit 8 — report every key as an escape code, including plain text.
    public static let reportAllKeysAsEscapeCodes = KeyboardEnhancementFlags(rawValue: 8)
    /// Bit 16 — report the text a key press produces alongside the code.
    public static let reportAssociatedText = KeyboardEnhancementFlags(rawValue: 16)

    /// What Corta actually acts on. A `CSI = flags ; 1 u` asking for more
    /// than this stores only this, so the query reports the truth.
    public static let supported: KeyboardEnhancementFlags = [.disambiguate, .reportEventTypes]
}

/// The protocol's mode *stack*.
///
/// A stack rather than a value because that is what the protocol specifies,
/// and for a good reason: a program that enables flags and then runs a child
/// (`vim` inside `tmux`) has to be able to restore exactly what it found,
/// without knowing what that was.
public struct KeyboardProtocolStack: Sendable, Equatable {
    /// Depth cap. The stack is pushed by the byte stream, so it is unbounded
    /// input and needs a limit (`SECURITY.md` §3); kitty's own
    /// implementation caps it in the same range.
    static let maximumDepth = 32

    private var stack: [KeyboardEnhancementFlags] = [[]]

    public init() {}

    /// The flags in force. The stack is never empty — the base entry is the
    /// legacy encoding, and popping past it leaves that.
    public var current: KeyboardEnhancementFlags { stack[stack.count - 1] }

    public var depth: Int { stack.count }

    /// `CSI > flags u`. At the cap the oldest entry is dropped rather than
    /// the push refused: a program that pushes without popping would
    /// otherwise be stuck at whatever it last set.
    public mutating func push(_ flags: KeyboardEnhancementFlags) {
        stack.append(flags.intersection(.supported))
        if stack.count > Self.maximumDepth { stack.removeFirst() }
    }

    /// `CSI < number u`, default 1.
    public mutating func pop(_ count: Int) {
        for _ in 0..<max(1, count) where stack.count > 1 { stack.removeLast() }
    }

    /// `CSI = flags ; mode u` — 1 sets, 2 adds, 3 removes.
    public mutating func set(_ flags: KeyboardEnhancementFlags, mode: Int) {
        let requested = flags.intersection(.supported)
        switch mode {
        case 2: stack[stack.count - 1].formUnion(requested)
        case 3: stack[stack.count - 1].subtract(requested)
        default: stack[stack.count - 1] = requested
        }
    }
}
