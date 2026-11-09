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
import CortaTerminal

/// One tab: program icons, name and context leading-aligned, a close button
/// on hover, and an agent badge when a pane reports one.
final class TabItemView: NSView, NSTextFieldDelegate {
    unowned let strip: TabStripView
    var index = 0
    /// Its tab has closed and it is fading out. Its index is stale by then:
    /// a double-click on the × closed the tab that had taken its place.
    var isLeaving = false
    private var middleButtonPressed = false
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let badge = AgentTabView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    private var editor: NSTextField?
    /// The tab being renamed, held by identity: the view may be handed
    /// another tab, or leave the strip, before the edit ends.
    private var editingID: String?
    private var editingName = ""
    private var hovering = false {
        didSet {
            updateChrome()
            needsLayout = true
        }
    }
    private var selected = false
    private var item: TabStripItem?
    /// The tab this view shows, by identity: the strip keeps a view with
    /// its tab as tabs around it open, close and move.
    var itemID: String? { item?.id }

    init(strip: TabStripView) {
        self.strip = strip
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = TabStripView.height / 2
        icon.imageScaling = .scaleNone
        // Clipped and faded, not ellipsised: a narrow tab still shows the
        // start of its name, and "…" would take the little room there is.
        title.lineBreakMode = .byClipping
        title.wantsLayer = true
        title.cell?.truncatesLastVisibleLine = true
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.text("tabs.close"))
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        closeButton.setAccessibilityLabel(L10n.text("tabs.close"))
        closeButton.setAccessibilityIdentifier("tab-close")
        for view in [icon, title, badge, closeButton] as [NSView] { addSubview(view) }
        // The tab is the element VoiceOver presses; its parts are not.
        icon.setAccessibilityElement(false)
        title.setAccessibilityElement(false)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityIdentifier("tab-item")
        // The × shows only under the pointer; VoiceOver closes by action.
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: L10n.text("tabs.close")) { [weak self] in
                guard let self, let index = self.liveIndex else { return false }
                self.strip.close(index)
                return true
            },
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { isLeaving ? nil : super.hitTest(point) }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(_ item: TabStripItem, selected: Bool) {
        // Every pass, not only on a change: the tint follows the canvas,
        // which a theme switch moves with the same item and selection.
        defer { updateChrome() }
        guard item != self.item || selected != self.selected else { return }
        if item.id != self.item?.id {
            // Another tab now: an edit under way was the old one's, and the
            // pointer may have left without an exit event.
            cancelRename()
            hovering = isPointerInside
        }
        self.item = item
        self.selected = selected
        let text = NSMutableAttributedString(string: item.name, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: selected ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ])
        if !item.context.isEmpty {
            text.append(NSAttributedString(string: " " + item.context, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        }
        title.attributedStringValue = text
        toolTip = item.toolTip
        badge.status = item.status
        badge.progress = item.progress
        badge.isHidden = item.status == nil && item.progress == nil
        badge.needsDisplay = true
        let badgeLabel = Self.badgeLabel(status: item.status, progress: item.progress)
        badge.toolTip = badgeLabel
        badge.setAccessibilityLabel(badgeLabel)
        // The tab is the element VoiceOver reads; the dot alone says nothing.
        setAccessibilityLabel(badgeLabel.map { "\(item.name), \($0)" } ?? item.name)
        setAccessibilityValue(selected)
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateChrome()
    }

    /// The selected tab's raised pill is the strip's, not the tab's: one
    /// pill that slides from tab to tab (`TabStripView.selection`). A tab
    /// draws only the faint tint under the pointer.
    private func updateChrome() {
        // A layer takes a resolved colour: resolve it in this view's
        // appearance, which the strip sets from the canvas, not in
        // whatever appearance happens to be current.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = !selected && hovering ? NSColor.labelColor.withAlphaComponent(0.06).cgColor : nil
        }
        // Clipped to its pill: a tab growing open shows only what fits.
        layer?.masksToBounds = true
        // Only under the pointer: a row of × marks is clutter.
        closeButton.isHidden = !hovering || editor != nil
    }

    private var isPointerInside: Bool {
        guard let window else { return false }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(point)
    }

    override func layout() {
        super.layout()
        // A closing tab keeps the layout it had while it is wiped away.
        guard !isLeaving else { return }
        let height = bounds.height
        let image = TabIcon.image(for: item?.programs ?? [])
        if icon.image !== image { icon.image = image }
        let size = image?.size ?? .zero
        // The image carries a margin for the turned cards; the front tile
        // sits 12 in. Whole points, so its edges fall on device pixels.
        icon.frame = NSRect(x: 8, y: ((height - size.height) / 2).rounded(),
                            width: size.width, height: size.height)
        let closeSide: CGFloat = 16
        closeButton.frame = NSRect(x: bounds.width - closeSide - 8, y: (height - closeSide) / 2,
                                   width: closeSide, height: closeSide)
        closeButton.isHidden = !hovering || editor != nil
        // The name runs to the edge; the × takes its room only when shown.
        var trailing = closeButton.isHidden ? bounds.width - 6 : closeButton.frame.minX - 4
        if !badge.isHidden {
            badge.frame = NSRect(x: trailing - 16, y: (height - 16) / 2, width: 16, height: 16)
            trailing = badge.frame.minX - 4
        }
        // From the cards' edge, not the image's: its margin is empty.
        let titleX = icon.frame.maxX - TabIcon.margin + 6
        let titleHeight = title.intrinsicContentSize.height
        title.frame = NSRect(x: titleX, y: ((height - titleHeight) / 2).rounded(),
                             width: max(0, trailing - titleX), height: titleHeight)
        editor?.frame = title.frame.insetBy(dx: -2, dy: -1)
        title.isHidden = title.frame.width < 8 || editor != nil
        fadeTitleIfClipped()
    }

    /// A name wider than its room fades out over its last few points.
    private func fadeTitleIfClipped() {
        guard let layer = title.layer else { return }
        let width = title.bounds.width
        guard title.attributedStringValue.size().width > width, width > 0 else {
            layer.mask = nil
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let fade = (layer.mask as? CAGradientLayer) ?? CAGradientLayer()
        fade.frame = title.bounds
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        let start = max(0, (width - 14) / width)
        fade.locations = [0, NSNumber(value: Double(start)), 1]
        layer.mask = fade
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        if editor != nil { super.mouseDown(with: event); return }
        strip.itemMouseDown(index, event: event)
    }
    override func mouseDragged(with event: NSEvent) { strip.itemMouseDragged(event) }
    override func mouseUp(with event: NSEvent) { strip.itemMouseUp() }
    override func otherMouseDown(with event: NSEvent) { middleButtonPressed = event.buttonNumber == 2 }
    override func otherMouseUp(with event: NSEvent) {
        // A press that began here: a button released over the strip after a
        // press elsewhere is not a request to close.
        if event.buttonNumber == 2, middleButtonPressed, let liveIndex { strip.close(liveIndex) }
        middleButtonPressed = false
    }
    override func menu(for event: NSEvent) -> NSMenu? { strip.menu(forTab: index) }

    @objc private func closeTab() {
        if let liveIndex { strip.close(liveIndex) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let liveIndex else { return false }
        strip.delegate?.tabStrip(strip, select: liveIndex)
        return true
    }

    // MARK: - Rename in place

    func beginRename() {
        guard editor == nil, let item, superview != nil else { return }
        let field = NSTextField(string: item.name)
        field.font = .systemFont(ofSize: 13)
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.wantsLayer = true
        field.layer?.cornerRadius = 4
        field.delegate = self
        field.setAccessibilityIdentifier("tab-title-editor")
        editor = field
        editingID = item.id
        editingName = item.name
        addSubview(field)
        needsLayout = true
        layoutSubtreeIfNeeded()
        title.isHidden = true
        updateChrome()
        // Taking first responder selects the whole name. A further
        // `selectText` ended the edit at once when the window was not key.
        window?.makeFirstResponder(field)
    }

    /// Ends an edit without saving it: the tab under it closed or changed.
    func cancelRename() {
        guard editor != nil else { return }
        cancelling = true
        endRename(save: false)
        cancelling = false
    }

    private func endRename(save: Bool) {
        guard let field = editor else { return }
        let id = editingID
        let originalName = editingName
        editor = nil
        editingID = nil
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let window = self.window
        field.delegate = nil
        field.removeFromSuperview()
        updateChrome()
        needsLayout = true
        // An empty name clears the custom title; Escape keeps the old one.
        // By identity: the tab may have moved while it was being named.
        // An unchanged name is no rename: saving it would freeze the
        // program's own title, which then stops following what runs.
        if save, let id, value != originalName {
            strip.rename(tab: id, to: value.isEmpty ? nil : String(value.prefix(200)))
        }
        // Typing goes back to the terminal, unless a click put it elsewhere.
        // After the turn: Escape ends the edit inside `makeFirstResponder(nil)`,
        // while the field editor is still first responder, and the window
        // takes it only afterwards — checked then, the keyboard was lost
        // and ⇧⌘[ and Rename Tab… found no target.
        DispatchQueue.main.async { [weak window] in
            guard let window, window.firstResponder == nil || window.firstResponder === window else { return }
            window.makeFirstResponder(window.terminalSplit?.focusedPane?.terminalView)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            editor?.stringValue = item?.name ?? ""
            cancelling = true
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    private var cancelling = false

    func controlTextDidEndEditing(_ obj: Notification) {
        let save = !cancelling
        cancelling = false
        endRename(save: save)
    }
}

extension TabItemView {
    /// What the badge's dot means, in words.
    static func badgeLabel(status: ProgramStatus?, progress: ProgramProgress?) -> String? {
        guard status != nil || progress != nil else { return nil }
        var label = status.map { L10n.text("agent.state." + $0.state.rawValue) } ?? L10n.text("agent.progress")
        if let value = progress?.value { label += " · \(value)%" }
        return label
    }

    /// Where this view's tab is now, found by identity; nil once it has gone.
    /// A press under way when the tab closes still ends here, and `index` by
    /// then names whichever tab took its place.
    var liveIndex: Int? {
        guard !isLeaving, let itemID else { return nil }
        return strip.index(ofTab: itemID)
    }
}
