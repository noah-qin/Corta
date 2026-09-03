import AppKit
import Testing

@testable import Corta

@MainActor
struct NativeIntegrationTests {
    @Test("pinch accumulation uses keyboard-sized steps and preserves remainder")
    func pinchSteps() {
        var accumulator: CGFloat = 0
        #expect(ViewController.fontSizes(
            forMagnification: 0.14, accumulator: &accumulator, startingAt: 12).isEmpty)
        #expect(accumulator == 0.14)
        #expect(ViewController.fontSizes(
            forMagnification: 0.31, accumulator: &accumulator, startingAt: 12) == [13, 14, 15])
        #expect(abs(accumulator) < 0.000_001)
    }

    @Test("pinch accumulation clamps and drops blocked remainder")
    func pinchClamp() {
        var accumulator: CGFloat = 0
        #expect(ViewController.fontSizes(
            forMagnification: 0.45, accumulator: &accumulator, startingAt: 63) == [64])
        #expect(accumulator == 0)
    }

    @Test("file pasteboards expose only file URL paths")
    func droppedFilePaths() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        _ = pasteboard.writeObjects([
            NSURL(fileURLWithPath: "/tmp/one file"),
            NSURL(fileURLWithPath: "/tmp/two")
        ])
        #expect(TerminalView.droppedPaths(from: pasteboard) == ["/tmp/one file", "/tmp/two"])

        pasteboard.clearContents()
        pasteboard.setString("https://example.com", forType: .string)
        #expect(TerminalView.droppedPaths(from: pasteboard).isEmpty)
    }

    @Test("Services exports and imports selected text")
    func servicesRoundTrip() {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let pasteboard = NSPasteboard.withUniqueName()
        view.onServicesSelection = { "selected text" }
        #expect(view.writeSelection(to: pasteboard, types: [.string]))
        #expect(pasteboard.string(forType: .string) == "selected text")

        var inserted: String?
        view.onServicesInsert = { inserted = $0 }
        #expect(view.readSelection(from: pasteboard))
        #expect(inserted == "selected text")
    }

    @Test("dropped shell paths quote metacharacters and apostrophes")
    func shellQuoting() {
        #expect(ViewController.shellQuoted("/tmp/plain-file") == "/tmp/plain-file")
        #expect(ViewController.shellQuoted("/tmp/a b") == "'/tmp/a b'")
        #expect(ViewController.shellQuoted("/tmp/a'b") == "'/tmp/a'\\''b'")
        #expect(ViewController.shellQuoted("/tmp/$(touch hacked)") == "'/tmp/$(touch hacked)'")
    }
}
