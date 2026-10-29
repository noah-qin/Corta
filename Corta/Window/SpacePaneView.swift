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

/// One grid panel: a rounded card holding a slim header and the terminal.
///
/// Content layer, so no Liquid Glass: the card is opaque in the terminal's
/// own background, its corners concentric with the window's, and the
/// focused card says so with an accent outline rather than by dimming the
/// others. The header names the session and its state; its actions sit in
/// one menu — the `…` at its corner, faint until the pointer comes, and the
/// header's context menu. Double-click the header to fill the grid, drag
/// it onto another panel to swap the two.
@MainActor
final class SpacePaneView: NSView {
    static let headerHeight: CGFloat = 30
    static let cornerRadius: CGFloat = 10
    /// The `…` is always there, so every panel shows where its actions are;
    /// faint until the pointer is over the panel.
    static let restingMenuAlpha: CGFloat = 0.35
    static let sessionType = NSPasteboard.PasteboardType("dev.noahqin.corta.space-session")

    let session: SpaceSession
    private weak var pane: ViewController?
    private weak var space: CortaSpaceController?
    private let card = NSView()
    private let header = SpacePaneHeader()
    private let terminalHost = NSView()
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let status = SpaceStatusPill()
    private let menuButton = NSButton()
    private var isFocused = false
    private var isPointerInside = false
    private var isDropTarget = false
    /// Where a dragged session would land: a half for an edge, the whole
    /// panel for its middle.
    private let dropOverlay = NSView()

    init(session: SpaceSession, pane: ViewController, space: CortaSpaceController) {
        self.session = session
        self.pane = pane
        self.space = space
        super.init(frame: pane.view.frame)
        build()
        update()
        registerForDraggedTypes([Self.sessionType])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func build() {
        configureControls()
        layOut()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("Corta.Space.Panel")
    }

    private func configureControls() {
        card.wantsLayer = true
        card.layer?.cornerRadius = Self.cornerRadius
        card.layer?.cornerCurve = .continuous
        // Clips the terminal's Metal layer to the card; that layer is already
        // composited with a corner mask in a window, so nothing new is paid.
        card.layer?.masksToBounds = true
        header.panel = self
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingHead
        detailLabel.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        let actions = L10n.text("space.panel.actions")
        menuButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: actions)
        menuButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        menuButton.isBordered = false
        menuButton.bezelStyle = .accessoryBarAction
        menuButton.contentTintColor = .secondaryLabelColor
        menuButton.toolTip = L10n.text("space.panel.actions")
        menuButton.target = self
        menuButton.action = #selector(showMenu(_:))
        menuButton.alphaValue = Self.restingMenuAlpha
    }

    private func layOut() {
        let row = NSStackView(views: [icon, titleLabel, status, detailLabel, NSView(), menuButton])
        row.spacing = 8
        row.setCustomSpacing(10, after: status)
        for child in [card, header, terminalHost, row] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(card)
        dropOverlay.wantsLayer = true
        dropOverlay.layer?.cornerRadius = Self.cornerRadius - 2
        dropOverlay.layer?.cornerCurve = .continuous
        dropOverlay.layer?.borderWidth = 2
        dropOverlay.isHidden = true
        addSubview(dropOverlay)
        card.addSubview(header)
        card.addSubview(terminalHost)
        header.addSubview(row)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.topAnchor.constraint(equalTo: card.topAnchor),
            header.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            row.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: 1),
            terminalHost.topAnchor.constraint(equalTo: header.bottomAnchor),
            terminalHost.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            terminalHost.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            terminalHost.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
        ])
    }

    /// Puts the pane's view in this panel, if another parent had it.
    func attachTerminal() {
        guard let pane, pane.view.superview !== terminalHost else { return }
        pane.view.removeFromSuperview()
        pane.view.translatesAutoresizingMaskIntoConstraints = false
        terminalHost.addSubview(pane.view)
        NSLayoutConstraint.activate([
            pane.view.leadingAnchor.constraint(equalTo: terminalHost.leadingAnchor),
            pane.view.trailingAnchor.constraint(equalTo: terminalHost.trailingAnchor),
            pane.view.topAnchor.constraint(equalTo: terminalHost.topAnchor),
            pane.view.bottomAnchor.constraint(equalTo: terminalHost.bottomAnchor),
        ])
    }

    func update() {
        let presentation = SpaceSessionPresentation(session: session)
        isFocused = pane != nil && space?.host?.focusedPane === pane
        // The card is the terminal's surface: its background, and chrome in
        // the appearance that reads on it.
        let background = SpacePaneView.canvasColor
        card.appearance = NSAppearance(named: background.isDark ? .darkAqua : .aqua)
        card.layer?.backgroundColor = background.cgColor
        icon.image = NSImage(systemSymbolName: presentation.symbol, accessibilityDescription: nil)
        titleLabel.stringValue = presentation.title
        titleLabel.textColor = isFocused ? .labelColor : .secondaryLabelColor
        detailLabel.stringValue = presentation.detail
        status.configure(text: presentation.state, tint: presentation.tint)
        applyOutline()
        setAccessibilityLabel([presentation.title, presentation.state].compactMap { $0 }.joined(separator: ", "))
    }

    private func applyOutline() {
        let accent = isFocused || isDropTarget
        card.layer?.borderWidth = accent ? 2 : 1
        card.layer?.borderColor = accent
            ? NSColor.controlAccentColor.cgColor
            : NSColor.separatorColor.resolved(in: card.effectiveAppearance).cgColor
        dropOverlay.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        dropOverlay.layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        update()
    }

    // MARK: - Arriving

    /// Says "here" once when a session lands: an accent outline that fades,
    /// or, with Reduce Motion, one that stays a moment and goes.
    func announceArrival() {
        let ring = NSView(frame: bounds)
        ring.autoresizingMask = [.width, .height]
        ring.wantsLayer = true
        ring.layer?.cornerRadius = Self.cornerRadius
        ring.layer?.cornerCurve = .continuous
        ring.layer?.borderWidth = 3
        ring.layer?.borderColor = NSColor.controlAccentColor.cgColor
        addSubview(ring)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { ring.removeFromSuperview() }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.9
                ring.animator().alphaValue = 0
            }, completionHandler: { ring.removeFromSuperview() })
        }
    }

    // MARK: - The panel's menu

    /// Hide, fill the grid, end: everything a panel can do, in one place.
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let maximized = space?.selectedProject?.maximized === session
        for (key, action) in [
            (maximized ? "space.panel.restore" : "space.panel.maximize", #selector(toggleMaximize)),
            ("space.panel.hide", #selector(hidePanel)),
        ] {
            menu.addItem(withTitle: L10n.text(key), action: action, keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: L10n.text("space.session.rename"), action: #selector(rename), keyEquivalent: "")
            .target = self
        if space?.canBrowseFiles(of: session) == true {
            menu.addItem(withTitle: L10n.text("space.session.browseFiles"), action: #selector(browseFiles),
                         keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        // nil targets: the window's own commands, enabled as the menu bar's.
        menu.addItem(withTitle: L10n.text("space.arrange.columns"),
                     action: #selector(SplitViewController.arrangeSpaceInColumns(_:)), keyEquivalent: "")
        menu.addItem(withTitle: L10n.text("space.arrange.rows"),
                     action: #selector(SplitViewController.arrangeSpaceInRows(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.text("space.session.end"), action: #selector(endSession), keyEquivalent: "")
            .target = self
        return menu
    }

    @objc private func showMenu(_ sender: NSButton) {
        makeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func toggleMaximize() { space?.toggleMaximize(session) }
    @objc private func hidePanel() { space?.hide(session) }
    @objc private func endSession() { space?.endSession(session) }
    @objc private func rename() { space?.sidebar.beginRename(session) }
    @objc private func browseFiles() { space?.browseFiles(of: session) }

    // MARK: - Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { setPointerInside(true) }
    override func mouseExited(with event: NSEvent) { setPointerInside(false) }

    private func setPointerInside(_ inside: Bool) {
        guard inside != isPointerInside else { return }
        isPointerInside = inside
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            menuButton.animator().alphaValue = inside ? 1 : Self.restingMenuAlpha
        }
    }

    fileprivate func headerClicked(_ event: NSEvent) {
        if event.clickCount == 2 { space?.toggleMaximize(session) } else { space?.focus(session) }
    }

    fileprivate func beginDrag(with event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString(session.id.uuidString, forType: Self.sessionType)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let image = header.bitmapImageRepForCachingDisplay(in: header.bounds).flatMap { rep -> NSImage? in
            header.cacheDisplay(in: header.bounds, to: rep)
            let image = NSImage(size: header.bounds.size)
            image.addRepresentation(rep)
            return image
        }
        dragging.setDraggingFrame(convert(header.frame, from: card), contents: image)
        beginDraggingSession(with: [dragging], event: event, source: header)
    }

    /// The session a drag carries, if it belongs to the project on screen.
    static func session(in info: NSDraggingInfo, space: CortaSpaceController?) -> SpaceSession? {
        guard let text = info.draggingPasteboard.string(forType: sessionType), let id = UUID(uuidString: text),
              let space, let (project, session) = space.session(withID: id),
              project === space.selectedProject, session.pane != nil else { return nil }
        return session
    }

    /// The theme's background, which the card shares with its terminal.
    static var canvasColor: NSColor {
        let color = TerminalColorPalette.defaultBackground
        return NSColor(srgbRed: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 1)
    }
}

extension SpacePaneView {
    // MARK: - Dropping a session here

    /// Where a drop at the pointer lands: an edge splits this panel there,
    /// the middle takes its place. The overlay shows the area it will get.
    private func dropEdge(for sender: NSDraggingInfo, session dragged: SpaceSession) -> SpaceGrid.Edge? {
        let point = convert(sender.draggingLocation, from: nil)
        guard let edge = SpaceGrid.edge(at: point, in: bounds.size),
              space?.canDrop(dragged, on: self, edge: edge) == true else { return nil }
        return edge
    }

    private func showDropTarget(_ edge: SpaceGrid.Edge?) {
        isDropTarget = true
        var frame = bounds
        let gap = SpaceGrid.dividerThickness / 2
        switch edge {
        case .left: frame.size.width = bounds.width / 2 - gap
        case .right: frame.origin.x = bounds.width / 2 + gap; frame.size.width = bounds.width / 2 - gap
        case .bottom: frame.size.height = bounds.height / 2 - gap
        case .top: frame.origin.y = bounds.height / 2 + gap; frame.size.height = bounds.height / 2 - gap
        case nil: break
        }
        dropOverlay.frame = frame
        dropOverlay.isHidden = false
        applyOutline()
    }

    private func clearDropTarget() {
        isDropTarget = false
        dropOverlay.isHidden = true
        applyOutline()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let dragged = Self.session(in: sender, space: space), dragged !== session else {
            clearDropTarget()
            return []
        }
        showDropTarget(dropEdge(for: sender, session: dragged))
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { clearDropTarget() }

    override func draggingEnded(_ sender: NSDraggingInfo) { clearDropTarget() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        clearDropTarget()
        guard let space, let dragged = Self.session(in: sender, space: space), dragged !== session else { return false }
        space.drop(dragged, on: self, edge: dropEdge(for: sender, session: dragged))
        return true
    }
}

/// The header: a click focuses the panel, a double-click fills the grid, a
/// drag carries the session to another panel, a right-click opens its menu.
private final class SpacePaneHeader: NSView, NSDraggingSource {
    weak var panel: SpacePaneView?
    private var mouseDownEvent: NSEvent?

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownEvent else { return }
        let distance = hypot(event.locationInWindow.x - start.locationInWindow.x,
                             event.locationInWindow.y - start.locationInWindow.y)
        guard distance > 4 else { return }
        mouseDownEvent = nil
        panel?.beginDrag(with: start)
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownEvent != nil else { return }
        mouseDownEvent = nil
        panel?.headerClicked(event)
    }

    override func menu(for event: NSEvent) -> NSMenu? { panel?.makeMenu() }

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
}

/// The session's state as a dot and a word, in the state's colour.
@MainActor
final class SpaceStatusPill: NSView {
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        let stack = NSStackView(views: [dot, label])
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(text: String?, tint: NSColor?) {
        isHidden = text == nil
        label.stringValue = text ?? ""
        let color = tint ?? .tertiaryLabelColor
        label.textColor = tint == nil ? .secondaryLabelColor : color
        dot.layer?.backgroundColor = color.resolved(in: effectiveAppearance).cgColor
    }
}

private extension NSColor {
    /// Whether text on this colour wants the dark appearance's chrome.
    var isDark: Bool {
        guard let rgb = usingColorSpace(.sRGB) else { return false }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent < 0.5
    }

    func resolved(in appearance: NSAppearance) -> NSColor {
        var result = self
        appearance.performAsCurrentDrawingAppearance { result = self.usingColorSpace(.sRGB) ?? self }
        return result
    }
}
