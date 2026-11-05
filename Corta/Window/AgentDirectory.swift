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
    /// What the Dock tile last drew: a redraw is a cross-process call, and a
    /// program streaming progress changes `status` on most output signals.
    private var drawnBadge: String?
    private var drawnDockPercent: Int?
    /// Who is waiting and in what order; only a user's jump consults it.
    private var queue = AttentionQueue()
    static let didChange = Notification.Name("dev.noahqin.Corta.agentsDidChange")

    struct Entry: Equatable {
        var id: UUID
        var title: String
    }

    static var panes: [ViewController] {
        NSApp.windows.flatMap(\.terminalSplits).flatMap(\.panes)
    }
    /// Waiting panes in queue order, then the rest by urgency: what `urgency`
    /// ranks, with equals kept in pane order.
    static var entries: [Entry] {
        guard ConfigurationStore.shared.configuration.agentStatus else { return [] }
        syncQueue()
        let waiting = shared.queue.ordered
        let listed = panes.enumerated().sorted { left, right in
            let leftWait = waiting.firstIndex(of: left.element.taskNotifier.paneID) ?? Int.max
            let rightWait = waiting.firstIndex(of: right.element.taskNotifier.paneID) ?? Int.max
            if leftWait != rightWait { return leftWait < rightWait }
            let leftUrgency = left.element.agents.status?.urgency ?? 0
            let rightUrgency = right.element.agents.status?.urgency ?? 0
            return leftUrgency == rightUrgency ? left.offset < right.offset : leftUrgency > rightUrgency
        }.map(\.element)
        return listed.compactMap { pane in
            guard let status = pane.agents.status else { return nil }
            let details = [L10n.text("agent.state." + status.state.rawValue),
                status.title.isEmpty ? status.app : status.title,
                status.kind.map { L10n.text("agent.kind." + $0.rawValue) } ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " · ")
            return Entry(id: pane.taskNotifier.paneID,
                title: pane.windowTitle.notificationTitle + " — " + details)
        }
    }
    /// Brings `id`'s pane forward with the keyboard: its window, its tab, and
    /// out from behind a zoomed sibling, which leaves it with no window of its
    /// own. Only ever called for something the user chose.
    static func focus(_ id: UUID) {
        guard let pane = panes.first(where: { $0.taskNotifier.paneID == id }),
              let split = pane.splitController, let window = split.view.window else { return }
        NSApp.activate()
        if let tab = split.tab { tab.controller?.selectTab(tab) }
        if split.zoomedPane != nil, split.zoomedPane !== pane { split.unzoomPane() }
        window.makeKeyAndOrderFront(nil)
        split.takeFocus(pane)
    }

    // MARK: - Waiting panes

    /// `state=blocked`, as the program reported it. Nothing else waits: done,
    /// failed, a notification and a silent program are not guessed at.
    private static func syncQueue() {
        let enabled = ConfigurationStore.shared.configuration.agentStatus
        shared.queue.sync(waiting: !enabled ? [] : panes.compactMap { pane in
            guard let status = pane.agents.status, status.state == .blocked else { return nil }
            return AttentionQueue.Waiting(id: pane.taskNotifier.paneID, kind: status.kind)
        })
    }

    static var hasWaitingPane: Bool {
        syncQueue()
        return !shared.queue.ordered.isEmpty
    }

    /// Window ▸ Jump to Next Waiting Pane. With nothing waiting, or with the one
    /// waiting pane already focused, nothing changes.
    static func jumpToNextWaiting() {
        syncQueue()
        let current = (NSApp.keyWindow ?? NSApp.mainWindow)?.terminalSplit?.focusedPane
        guard let target = shared.queue.next(from: current?.taskNotifier.paneID) else { return }
        focus(target)
    }

    static func refresh() {
        let directory = shared
        if directory.configurationObserver == nil {
            directory.configurationObserver = NotificationCenter.default.addObserver(
                forName: ConfigurationStore.didChange, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    for pane in Self.panes { pane.agents.readOutput() }
                    refresh()
                }
            }
        }
        let enabled = ConfigurationStore.shared.configuration.agentStatus
        syncQueue()
        refreshTabs(enabled: enabled)
        refreshDock(enabled: enabled, directory: directory)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Each tab shows its most urgent pane status, or its progress, in the
    /// strip (D30).
    private static func refreshTabs(enabled: Bool) {
        for window in NSApp.windows {
            guard let controller = window.windowController as? TerminalWindowController else { continue }
            var changed = false
            for tab in controller.tabs {
                let panes = tab.split.panes
                let statuses = enabled ? panes.compactMap { $0.agents.status } : []
                let status = statuses.max { $0.urgency < $1.urgency }
                let progress = enabled ? panes.compactMap { $0.agents.progress }.first : nil
                if tab.agentStatus != status || tab.agentProgress != progress {
                    tab.agentStatus = status
                    tab.agentProgress = progress
                    changed = true
                }
            }
            if changed { controller.refreshTabStrip() }
        }
    }

    /// The Dock badge counts the panes waiting on the user; the Dock tile
    /// shows the panes' mean progress. Redrawn only when either changes.
    private static func refreshDock(enabled: Bool, directory: AgentDirectory) {
        var waiting = 0
        var values: [Double] = []
        if enabled {
            for pane in panes {
                if pane.agents.status?.state == .blocked { waiting += 1 }
                if let progress = pane.agents.progress {
                    values.append(Double(progress.value ?? 0) / 100)
                }
            }
        }
        let badge = waiting > 0 ? String(waiting) : nil
        let progress = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        let percent = progress.map { Int(($0 * 100).rounded()) }
        guard badge != directory.drawnBadge || percent != directory.drawnDockPercent else { return }
        directory.drawnBadge = badge
        directory.drawnDockPercent = percent
        NSApp.dockTile.badgeLabel = badge
        if let progress {
            let view = directory.dockView ?? AgentDockView(frame: NSRect(origin: .zero, size: NSApp.dockTile.size))
            directory.dockView = view
            view.progress = progress
            NSApp.dockTile.contentView = view
        } else {
            NSApp.dockTile.contentView = nil
            directory.dockView = nil
        }
        NSApp.dockTile.display()
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
