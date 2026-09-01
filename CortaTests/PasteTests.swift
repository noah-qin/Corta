import Foundation
import Testing

@testable import Corta

/// M2.6, app side (`SECURITY.md` §2.3): pasted text is data, never a command
/// stream — ESC and C0 controls are stripped, and a paste containing a
/// newline warns unless the application enabled bracketed paste.
struct PasteTests {
    @Test func escapeAndC0ControlsAreStripped() {
        let malicious = "rm -rf ~\u{1B}[2J\u{7}\u{1}\u{1B}[200~echo hi"
        #expect(Paste.sanitized(malicious) == "rm -rf ~[2J[200~echo hi")
    }

    @Test func everyC0ScalarIsStripped() {
        for value: UInt32 in 0..<0x20 {
            guard value != 0x09, value != 0x0A, value != 0x0D else { continue }
            let text = "a\(Unicode.Scalar(value)!)b"
            #expect(Paste.sanitized(text) == "ab", "C0 control U+\(String(value, radix: 16)) must be stripped")
        }
    }

    @Test func tabNewlineAndReturnSurvive() {
        #expect(Paste.sanitized("\ta\nb\rc") == "\ta\nb\rc")
    }

    @Test func plainTextAndUnicodePassThrough() {
        #expect(Paste.sanitized("hello 世界 🎉") == "hello 世界 🎉")
    }

    @Test func newlinePasteNeedsWarningOnlyWithoutBracketedPaste() {
        #expect(Paste.needsWarning(text: "ls\nrm -rf ~", bracketedPasteEnabled: false))
        #expect(!Paste.needsWarning(text: "ls\nrm -rf ~", bracketedPasteEnabled: true))
        #expect(!Paste.needsWarning(text: "single line", bracketedPasteEnabled: false))
    }

    @Test func carriageReturnAlsoNeedsWarning() {
        // CR runs the line just like LF does.
        #expect(Paste.needsWarning(text: "ls\rrm -rf ~", bracketedPasteEnabled: false))
    }

    @Test func bracketedPasteWrapsIn2004Markers() {
        let bytes = Paste.bytes(for: "ls", bracketedPasteEnabled: true)
        #expect(bytes == Array("\u{1B}[200~ls\u{1B}[201~".utf8))
    }

    @Test func unbracketedPasteIsJustTheText() {
        #expect(Paste.bytes(for: "ls", bracketedPasteEnabled: false) == Array("ls".utf8))
    }
}
