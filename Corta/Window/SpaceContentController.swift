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

/// Space's content column: the grid, or what to do when there is none. The
/// content layer, so opaque and without glass; it starts below the toolbar
/// (the safe area), so no terminal text sits under the titlebar (D24).
@MainActor
final class SpaceContentController: NSViewController {
    enum Content {
        case grid(NSView)
        case noProject
        case noSessions
        case allHidden
    }

    weak var space: CortaSpaceController?
    private let container = NSView()
    private let empty = SpaceEmptyView()
    private var lastArea: CGSize = .zero

    override func loadView() {
        let view = SpaceContentView()
        view.controller = self
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)
        // The cards keep the same gap from the window's edges, the sidebar's
        // card and the toolbar as from each other.
        let gap = SpaceGrid.dividerThickness
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: gap),
            container.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -gap),
            container.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -gap),
        ])
        container.setAccessibilityIdentifier("Corta.Space.Grid")
        empty.space = { [weak self] in self?.space }
        self.view = view
    }

    /// The view the container shows now.
    var shownRoot: NSView? { container.subviews.first }

    /// The area a grid fills.
    var gridArea: CGSize {
        guard isViewLoaded else { return .zero }
        return container.bounds.size
    }

    func show(_ content: Content) {
        _ = view
        let shown: NSView
        switch content {
        case .grid(let root): shown = root
        case .noProject: empty.configure(.noProject); shown = empty
        case .noSessions: empty.configure(.noSessions); shown = empty
        case .allHidden: empty.configure(.allHidden); shown = empty
        }
        guard shown.superview !== container || container.subviews.count != 1 else { return }
        // Another project's grid, or none: a short fade, never a cut through
        // a blank frame.
        if !container.subviews.isEmpty, CortaSpaceController.animatesModeChanges,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            container.wantsLayer = true
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.15
            container.layer?.add(fade, forKey: "corta.space.grid")
        }
        container.subviews.forEach { $0.removeFromSuperview() }
        shown.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(shown)
        NSLayoutConstraint.activate([
            shown.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            shown.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            shown.topAnchor.constraint(equalTo: container.topAnchor),
            shown.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    func update() {
        empty.update()
    }

    private var note: NSView?
    private var noteDismissal: DispatchWorkItem?
    private var noteAction: (() -> Void)?

    /// A short note over the grid's foot — what just happened, and Undo.
    /// Navigation layer, so Liquid Glass; it goes by itself.
    func showNote(_ text: String, undoTitle: String, undo: @escaping () -> Void) {
        note?.removeFromSuperview()
        noteDismissal?.cancel()
        noteAction = undo
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.lineBreakMode = .byTruncatingMiddle
        let button = NSButton(title: undoTitle, target: self, action: #selector(undoFromNote))
        button.bezelStyle = .glass
        button.controlSize = .small
        let row = NSStackView(views: [label, button])
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 6, left: 16, bottom: 6, right: 8)
        let glass = NSGlassEffectView()
        glass.cornerRadius = 18
        glass.contentView = row
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.setAccessibilityIdentifier("Corta.Space.Note")
        view.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            glass.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24),
            glass.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -48),
        ])
        note = glass
        let dismissal = DispatchWorkItem { [weak self, weak glass] in
            guard let glass else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; glass.animator().alphaValue = 0 },
                                                 completionHandler: { glass.removeFromSuperview() })
            if self?.note === glass { self?.note = nil }
        }
        noteDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: dismissal)
    }

    @objc private func undoFromNote() {
        noteDismissal?.perform()
        noteAction?()
    }

    fileprivate func didLayout() {
        let area = gridArea
        guard area != lastArea else { return }
        lastArea = area
        // Not inside the layout pass that reported it: rebuilding the grid
        // there would lay it out again reentrantly.
        DispatchQueue.main.async { [weak self] in self?.space?.gridAreaDidChange() }
    }
}

/// The window's background behind the grid's dividers and empty states.
private final class SpaceContentView: NSView {
    weak var controller: SpaceContentController?

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        dirtyRect.fill()
    }

    override func layout() {
        super.layout()
        controller?.didLayout()
    }
}

/// What Space shows with nothing in the grid: one sentence on why, and the
/// one action that changes it.
@MainActor
final class SpaceEmptyView: NSView {
    enum Kind { case noProject, noSessions, allHidden }

    var space: () -> CortaSpaceController? = { nil }
    private var kind = Kind.noProject
    private let symbol = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let primary = NSButton(title: "", target: nil, action: nil)
    private let secondary = NSButton(title: "", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 40, weight: .light)
        symbol.contentTintColor = .tertiaryLabelColor
        title.font = .preferredFont(forTextStyle: .title2)
        title.alignment = .center
        message.alignment = .center
        message.textColor = .secondaryLabelColor
        message.preferredMaxLayoutWidth = 360
        primary.target = self
        primary.action = #selector(primaryAction)
        primary.bezelStyle = .push
        primary.controlSize = .large
        primary.keyEquivalent = "\r"
        secondary.target = self
        secondary.action = #selector(secondaryAction)
        secondary.bezelStyle = .push
        secondary.controlSize = .large
        let buttons = NSStackView(views: [secondary, primary])
        buttons.spacing = 12
        let stack = NSStackView(views: [symbol, title, message, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(18, after: message)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
        setAccessibilityIdentifier("Corta.Space.Empty")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ kind: Kind) {
        self.kind = kind
        update()
    }

    func update() {
        let symbolName: String
        switch kind {
        case .noProject:
            symbolName = "folder.badge.plus"
            title.stringValue = L10n.text("space.empty.noProject.title")
            message.stringValue = L10n.text("space.empty.noProject.message")
            primary.title = L10n.text("space.openProject")
            secondary.isHidden = true
        case .noSessions:
            symbolName = "terminal"
            title.stringValue = L10n.text("space.empty.noSessions.title")
            message.stringValue = L10n.text("space.empty.noSessions.message")
            primary.title = L10n.text("space.newSession")
            secondary.title = L10n.text("space.connectSSH")
            secondary.isHidden = false
        case .allHidden:
            symbolName = "rectangle.on.rectangle"
            title.stringValue = L10n.text("space.empty.allHidden.title")
            message.stringValue = L10n.text("space.empty.allHidden.message")
            primary.title = L10n.text("space.newSession")
            secondary.isHidden = true
        }
        symbol.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    }

    @objc private func primaryAction() {
        guard let space = space() else { return }
        if kind == .noProject { space.chooseProject() } else { space.newSession() }
    }

    @objc private func secondaryAction() { space()?.connectSession() }

    // MARK: - A session dragged from the sidebar shows here

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([SpacePaneView.sessionType])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        kind == .noProject || SpacePaneView.session(in: sender, space: space()) == nil ? [] : .move
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let space = space(), let session = SpacePaneView.session(in: sender, space: space) else { return false }
        space.dropOnEmptyGrid(session)
        return true
    }
}
