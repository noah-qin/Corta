import Testing

@testable import CortaTerminal

/// M6.9 — the kitty keyboard protocol's mode stack and its query.
@Suite("Kitty keyboard protocol")
struct KeyboardProtocolTests {
    private func response(to input: String) -> String {
        var terminal = Terminal(rows: 5, columns: 20)
        terminal.feed(Array(input.utf8))
        return String(decoding: terminal.takeOutput(), as: UTF8.self)
    }

    @Test("a fresh terminal reports the legacy encoding")
    func startsAtLegacy() {
        #expect(response(to: "\u{1B}[?u") == "\u{1B}[?0u")
    }

    @Test("a pushed flag is reported back")
    func pushIsReported() {
        #expect(response(to: "\u{1B}[>1u\u{1B}[?u") == "\u{1B}[?1u")
    }

    /// The report has to be the truth, not the request.
    @Test("flags Corta does not honour are not reported as honoured")
    func unsupportedFlagsAreNotClaimed() {
        #expect(response(to: "\u{1B}[>31u\u{1B}[?u") == "\u{1B}[?3u")
    }

    @Test("pop restores what the pusher found")
    func popRestores() {
        #expect(response(to: "\u{1B}[>1u\u{1B}[<1u\u{1B}[?u") == "\u{1B}[?0u")
    }

    @Test("popping past the base leaves the legacy encoding")
    func popPastTheBase() {
        #expect(response(to: "\u{1B}[<99u\u{1B}[?u") == "\u{1B}[?0u")
    }

    @Test("the set form's three modes replace, add and remove")
    func setModes() {
        #expect(response(to: "\u{1B}[=1;1u\u{1B}[?u") == "\u{1B}[?1u")
        #expect(response(to: "\u{1B}[=1;2u\u{1B}[?u") == "\u{1B}[?1u")
        #expect(response(to: "\u{1B}[=1;1u\u{1B}[=1;3u\u{1B}[?u") == "\u{1B}[?0u")
    }

    /// The stack is pushed by the byte stream, so it is unbounded input and
    /// needs a cap (`SECURITY.md` §3).
    @Test("the stack is bounded")
    func stackIsBounded() {
        var stack = KeyboardProtocolStack()
        for _ in 0..<1000 { stack.push(.disambiguate) }
        #expect(stack.depth <= KeyboardProtocolStack.maximumDepth)
        #expect(stack.current == .disambiguate)
    }
}
