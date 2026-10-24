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

/// The app's live panes are the directory; no retained pane or transcript.
@MainActor
final class AgentDirectory: NSObject, NSMenuDelegate {
    static let shared = AgentDirectory()
    private var configurationObserver: NSObjectProtocol?
    private var dockView: AgentDockView?
    static let didChange = Notification.Name("dev.noahqin.Corta.agentsDidChange")

    struct Entry: Equatable {
        var id: UUID
        var title: String
    }

    static var panes: [ViewController] {
        NSApp.windows.compactMap { $0.contentViewController as? SplitViewController }.flatMap(\.panes)
    }
    static var entries: [Entry] {
        guard ConfigurationStore.shared.configuration.agentStatus else { return [] }
        return panes.compactMap { pane in
            guard let status = pane.agents.status else { return nil }
            let details = [L10n.text("agent.state." + status.state.rawValue),
                status.title.isEmpty ? status.app : status.title,
                status.kind.map { L10n.text("agent.kind." + $0.rawValue) } ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " · ")
            return Entry(id: pane.taskNotifier.paneID,
                title: pane.windowTitle.notificationTitle + " — " + details)
        }
    }
    static func focus(_ id: UUID) {
        guard let pane = panes.first(where: { $0.taskNotifier.paneID == id }),
              let window = pane.view.window else { return }
        NSApp.activate()
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(pane.terminalView)
    }

    static func refresh() {
        let directory = shared
        if directory.configurationObserver == nil {
            directory.configurationObserver = NotificationCenter.default.addObserver(
                forName: ConfigurationStore.didChange, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    for pane in panes { pane.agents.readOutput() }
                    refresh()
                }
            }
        }
        let enabled = ConfigurationStore.shared.configuration.agentStatus
        let panes = panes
        var waiting = 0
        var values: [Double] = []
        for window in NSApp.windows {
            guard let split = window.contentViewController as? SplitViewController else { continue }
            let statuses = enabled ? split.panes.compactMap { $0.agents.status } : []
            let status = statuses.max { $0.urgency < $1.urgency }
            let progress = enabled ? split.panes.compactMap { $0.agents.progress }.first : nil
            if status != nil || progress != nil {
                let view = (window.tab.accessoryView as? AgentTabView) ?? AgentTabView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
                view.status = status; view.progress = progress
                var label = status.map { L10n.text("agent.state." + $0.state.rawValue) }
                    ?? L10n.text("agent.progress")
                if let value = progress?.value { label += " · \(value)%" }
                view.toolTip = label
                view.setAccessibilityLabel(view.toolTip ?? L10n.text("agent.progress"))
                view.needsDisplay = true
                window.tab.accessoryView = view
            } else { window.tab.accessoryView = nil }
        }
        if enabled {
            for pane in panes {
                if pane.agents.status?.state == .blocked { waiting += 1 }
                if let progress = pane.agents.progress {
                    values.append(Double(progress.value ?? 0) / 100)
                }
            }
        }
        NSApp.dockTile.badgeLabel = waiting > 0 ? String(waiting) : nil
        if !values.isEmpty {
            let view = directory.dockView ?? AgentDockView(frame: NSRect(origin: .zero, size: NSApp.dockTile.size))
            directory.dockView = view
            view.progress = values.reduce(0, +) / Double(values.count)
            NSApp.dockTile.contentView = view
        } else {
            NSApp.dockTile.contentView = nil
            directory.dockView = nil
        }
        NSApp.dockTile.display()
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func menu() -> NSMenu {
        let menu = NSMenu(title: L10n.text("agent.list"))
        menu.delegate = shared
        return menu
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for entry in Self.entries {
            let item = NSMenuItem(title: entry.title, action: #selector(jump(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = entry.id
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            let item = NSMenuItem(title: L10n.text("agent.empty"), action: nil, keyEquivalent: "")
            item.isEnabled = false; menu.addItem(item)
        }
    }
    @objc private func jump(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { Self.focus(id) }
    }
}

final class AgentTabView: NSView {
    var status: ProgramStatus?
    var progress: ProgramProgress?
    override var intrinsicContentSize: NSSize { NSSize(width: 20, height: 20) }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        let stateColor: NSColor = switch status?.state {
        case .blocked: .systemOrange
        case .error: .systemRed
        case .done: .systemGreen
        case .idle, .unknown: .secondaryLabelColor
        default: .controlAccentColor
        }
        let color = Self.reportedColor(status?.color)
            ?? (progress?.state == .error ? .systemRed
                : progress?.state == .paused ? .systemOrange : stateColor)
        // AppKit can resize a native tab accessory for its tab-strip metrics.
        // Center in the actual bounds, including a nonzero bounds origin.
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        color.setFill()
        let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6))
        if status?.state == .unknown {
            color.setStroke()
            dot.lineWidth = 1.5
            dot.stroke()
        } else { dot.fill() }
        if let progress {
            color.setStroke()
            let path = NSBezierPath()
            path.appendArc(withCenter: center, radius: 7,
                startAngle: 90, endAngle: 90 - 360 * CGFloat(progress.value ?? 25) / 100, clockwise: true)
            path.lineWidth = 2; path.stroke()
        }
    }

    private static func reportedColor(_ text: String?) -> NSColor? {
        guard let text, text.hasPrefix("#"), text.utf8.count == 7,
              let rgb = UInt32(text.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
            green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}

private final class AgentDockView: NSView {
    var progress = 0.0
    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage.draw(in: bounds)
        let track = NSRect(x: bounds.width * 0.15, y: bounds.height * 0.12,
                           width: bounds.width * 0.7, height: bounds.height * 0.08)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).fill()
        var fill = track.insetBy(dx: 2, dy: 2); fill.size.width *= progress
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
    }
}
