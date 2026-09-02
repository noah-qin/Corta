import AppKit

/// IME composition (M3.1–M3.4): the `NSTextInputClient` conformance, the
/// marked-text (preedit) overlay and the candidate window's placement.
///
/// The split of responsibilities (`DESIGN.md` §7.1):
///
/// - Key *routing* lives in `TerminalView+Keyboard.swift`: ⌘/⌃ events never
///   reach an input method; everything else is offered to
///   `inputContext.handleEvent(_:)` first.
/// - *Committed* text arrives through `insertText(_:replacementRange:)` and
///   is written to the PTY there, as UTF-8 bytes via `onKeyBytes` — never
///   from `keyDown`.
/// - *Marked* text lives in the app layer only. It is never written to the
///   grid and never to the PTY; `MarkedTextOverlayView` draws it over the
///   cells starting at the cursor, keeping the underline styling the
///   attributed string carries.
extension TerminalView: NSTextInputClient {
    // MARK: - Marked text state (M3.1, M3.3)

    /// Extensions cannot add storage, so the preedit state lives on the
    /// overlay subview itself; a lookup stands in for an ivar.
    private var existingMarkedTextOverlay: MarkedTextOverlayView? {
        subviews.first(where: { $0 is MarkedTextOverlayView }) as? MarkedTextOverlayView
    }

    private var markedTextOverlay: MarkedTextOverlayView {
        if let existing = existingMarkedTextOverlay { return existing }
        let overlay = MarkedTextOverlayView()
        addSubview(overlay)
        return overlay
    }

    // MARK: - NSTextInputClient (M3.1)

    /// Committed text is the only IME output that reaches the child: as
    /// UTF-8 bytes through the same `onKeyBytes` path a physical key takes.
    func insertText(_ string: Any, replacementRange: NSRange) {
        clearMarkedText()
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        guard !text.isEmpty else { return }
        onKeyBytes?(Array(text.utf8))
    }

    /// Preedit updates reposition the overlay at the cursor and redraw it;
    /// nothing here touches the grid or the PTY. An empty string is the
    /// IME cancelling the composition, which is an unmark.
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let attributed: NSAttributedString =
            switch string {
            case let a as NSAttributedString: a
            case let s as String: NSAttributedString(string: s)
            default: NSAttributedString()
            }
        guard attributed.length > 0 else {
            clearMarkedText()
            return
        }
        let overlay = markedTextOverlay
        overlay.cellSize = cellSize
        overlay.show(attributed, at: cursorRectProvider?() ?? .zero)
    }

    func unmarkText() {
        clearMarkedText()
    }

    private func clearMarkedText() {
        existingMarkedTextOverlay?.hide()
    }

    func hasMarkedText() -> Bool {
        existingMarkedTextOverlay?.markedText != nil
    }

    func markedRange() -> NSRange {
        guard let length = existingMarkedTextOverlay?.markedText?.length else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: 0, length: length)
    }

    /// The terminal has no text backing store the IME may read; selection
    /// (Track C) is not exposed to input methods.
    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func attributedSubstring(
        forProposedRange range: NSRange, actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.underlineStyle, .underlineColor, .markedClauseSegment, .font, .foregroundColor]
    }

    /// M3.2: the candidate window anchors to the cursor cell, in *screen*
    /// coordinates. Computed on demand from `cursorRectProvider`, so it
    /// stays correct after the window moves.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let cell = cursorRectProvider?(), let window else { return .zero }
        return window.convertToScreen(convert(cell, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }

    /// Key-bound commands that arrive when the IME consumed an event and
    /// resolved it through the key-binding system instead of inserting
    /// text. Forwarding them keeps Return, Delete, Escape and the arrows
    /// behaving identically whether or not an IME is selected (M3.4) — an
    /// IME that answers `handleEvent` with `true` for Return must not eat
    /// the key.
    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)): onKeyBytes?([0x0D])
        case #selector(deleteBackward(_:)): onKeyBytes?([0x7F])
        case #selector(cancelOperation(_:)): onKeyBytes?([0x1B])
        case #selector(moveUp(_:)): onKeyBytes?(Array("\u{1B}[A".utf8))
        case #selector(moveDown(_:)): onKeyBytes?(Array("\u{1B}[B".utf8))
        case #selector(moveRight(_:)): onKeyBytes?(Array("\u{1B}[C".utf8))
        case #selector(moveLeft(_:)): onKeyBytes?(Array("\u{1B}[D".utf8))
        default: break
        }
    }
}

/// Draws the preedit string over the cells at the cursor (M3.3).
///
/// An ordinary `NSView` subview, composited above the Metal layer; the grid
/// itself never sees marked text. There is deliberately no backdrop — the
/// underlined text reads directly over the cells, as in Terminal.app. The
/// view never accepts events (`hitTest` returns nil).
final class MarkedTextOverlayView: NSView {
    /// The preedit as last handed to `setMarkedText`, with the IME's
    /// underline/clause attributes intact; nil while hidden.
    private(set) var markedText: NSAttributedString?

    /// Matches the shell's hardcoded Menlo 14 (`ViewController.viewDidLoad`).
    /// When the font stack becomes configurable (M4's ⌘+/⌘−), wire the
    /// current font in here — until then this is a seam, not a setting.
    var font = NSFont(name: "Menlo", size: 14) ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)

    /// Set by the terminal view before each `show`; needed to size and
    /// vertically centre the text against the cell it covers.
    var cellSize: CGSize = CGSize(width: 8, height: 17)

    /// Same light grey the renderer resolves `.default` foreground to
    /// (`TerminalColorPalette.defaultForeground`).
    private let textColor = NSColor(white: 0.898, alpha: 1)

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The terminal view is layer-HOSTING (its layer is the CAMetalLayer);
        // a subview without its own backing layer never composites on top of
        // it and the preedit stays invisible.
        wantsLayer = true
        isHidden = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        isHidden = true
    }

    /// Shows the preedit at `cell` (the cursor cell's rect in the superview's
    /// coordinates), wide enough for the text but never narrower than a cell.
    func show(_ attributed: NSAttributedString, at cell: CGRect) {
        let display = displayString(for: attributed)
        markedText = display
        let textSize = display.size()
        frame = CGRect(
            x: cell.minX, y: cell.minY,
            width: max(ceil(textSize.width), cell.width),
            height: max(cell.height, ceil(textSize.height)))
        isHidden = false
        needsDisplay = true
    }

    func hide() {
        markedText = nil
        isHidden = true
    }

    /// The IME's attributes win; font and colour are filled in only where
    /// the attributed string carries none, so the underline styling and any
    /// clause highlighting survive untouched.
    private func displayString(for attributed: NSAttributedString) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: attributed)
        // Collect first: mutating an attributed string mid-enumeration is
        // not safe.
        var additions: [(NSRange, [NSAttributedString.Key: Any])] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            var defaults: [NSAttributedString.Key: Any] = [:]
            if attributes[.font] == nil { defaults[.font] = font }
            if attributes[.foregroundColor] == nil { defaults[.foregroundColor] = textColor }
            if !defaults.isEmpty { additions.append((range, defaults)) }
        }
        for (range, defaults) in additions {
            text.addAttributes(defaults, range: range)
        }
        return text
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let markedText else { return }
        // Centre vertically within the cell; the underline the attributed
        // string carries is drawn by AppKit along the text's baseline.
        let y = max(0, (bounds.height - markedText.size().height) / 2)
        markedText.draw(at: NSPoint(x: 0, y: y))
    }
}
