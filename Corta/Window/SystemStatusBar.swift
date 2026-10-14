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
import SwiftUI

final class SystemStatusBar: NSView {
    static let height: CGFloat = 24
    private let client = UUID()
    private let button = NSButton(title: "", target: nil, action: nil)
    private var popover: NSPopover?
    var onVisibilityChange: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        button.isBordered = false
        button.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        button.alignment = .left
        button.lineBreakMode = .byTruncatingTail
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.target = self
        button.action = #selector(showDetails)
        button.identifier = NSUserInterfaceItemIdentifier("system-status-bar")
        button.setAccessibilityLabel(L10n.text("status.label"))
        button.toolTip = L10n.text("status.help")
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // Resolve the singleton before observing its first-load notification;
        // a non-default config posts during init and must not re-enter shared.
        refresh()
        for name in [ConfigurationStore.didChange, SystemMetricsStore.didChange, NSWindow.didChangeOcclusionStateNotification, AppearanceController.didChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(changed), name: name, object: nil)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    isolated deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refresh() }
    @objc private func changed() { refresh() }

    func stop() {
        popover?.close()
        SystemMetricsStore.shared.setActive(false, client: client)
        NotificationCenter.default.removeObserver(self)
    }

    private func refresh() {
        let config = ConfigurationStore.shared.configuration
        let wasHidden = isHidden
        isHidden = !config.statusBar
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let metrics = SystemMetricsStore.shared.snapshot
        var compact = [L10n.text("status.local")]
        var full = [L10n.text("status.local")]
        for item in SystemMetrics.Item.allCases where config.statusItems.contains(item) {
            compact.append(SystemStatusFormat.compactText(item, metrics: metrics))
            full.append(SystemStatusFormat.text(item, metrics: metrics))
        }
        button.title = compact.joined(separator: " · ")
        let accessible = full.joined(separator: " · ")
        button.setAccessibilityValue(accessible)
        button.toolTip = accessible + "\n" + L10n.text("status.help")
        SystemMetricsStore.shared.setActive(
            config.statusBar && window?.occlusionState.contains(.visible) == true, client: client)
        if wasHidden != isHidden { onVisibilityChange?() }
        if let controller = popover?.contentViewController as? NSHostingController<SystemStatusDetails> {
            controller.rootView = SystemStatusDetails(metrics: metrics)
        }
    }

    @objc private func showDetails() {
        if popover?.isShown == true { popover?.close(); return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: SystemStatusDetails(metrics: SystemMetricsStore.shared.snapshot))
        self.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }
}

enum SystemStatusFormat {
    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }
    static func rate(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return bytes(Int64(min(Double(Int64.max - 1024), max(0, value)))) + "/s"
    }
    static func thermal(_ value: ProcessInfo.ThermalState?) -> String {
        guard let value else { return "—" }
        return switch value {
        case .nominal: L10n.text("status.thermal.nominal")
        case .fair: L10n.text("status.thermal.fair")
        case .serious: L10n.text("status.thermal.serious")
        case .critical: L10n.text("status.thermal.critical")
        @unknown default: "—"
        }
    }
    /// Compact visual labels; full names and precision remain in details/AX.
    static func compactBytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        var amount = Double(max(0, value))
        let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
        var index = 0
        while amount >= 1024 && index < units.count - 1 { amount /= 1024; index += 1 }
        return amount.formatted(.number.precision(.fractionLength(0...1)).grouping(.never)) + units[index]
    }
    static func compactText(_ item: SystemMetrics.Item, metrics: SystemMetrics) -> String {
        let value: String
        switch item {
        case .cpu: value = metrics.cpuPercent.map { ($0 / 100).formatted(.percent.precision(.fractionLength(0))) } ?? "—"
        case .load: value = metrics.load.map { $0.formatted(.number.precision(.fractionLength(2))) }.joined(separator: "/")
        case .memory: value = compactBytes(metrics.memoryUsed.map(Int64.init)) + "/" + compactBytes(Int64(metrics.memoryTotal))
        case .network:
            func rate(_ value: Double?) -> String {
                guard let value, value.isFinite else { return "—" }
                return compactBytes(Int64(min(Double(Int64.max - 1024), max(0, value)))) + "/s"
            }
            value = "\(metrics.networkInterface ?? "—") ↓\(rate(metrics.downloadRate)) ↑\(rate(metrics.uploadRate))"
        case .disk: value = compactBytes(metrics.diskAvailable)
        case .thermal: value = thermal(metrics.thermal)
        }
        return L10n.text("status.short.\(item.rawValue)") + " " + (value.isEmpty ? "—" : value)
    }

    static func text(_ item: SystemMetrics.Item, metrics: SystemMetrics) -> String {
        let value: String
        switch item {
        case .cpu: value = metrics.cpuPercent.map { ($0 / 100).formatted(.percent.precision(.fractionLength(0))) } ?? "—"
        case .load: value = metrics.load.map { $0.formatted(.number.precision(.fractionLength(2))) }.joined(separator: " / ")
        case .memory: value = bytes(metrics.memoryUsed.map(Int64.init)) + " / " + bytes(Int64(metrics.memoryTotal))
        case .network: value = "\(metrics.networkInterface ?? "—") ↓ \(rate(metrics.downloadRate)) ↑ \(rate(metrics.uploadRate))"
        case .disk: value = bytes(metrics.diskAvailable)
        case .thermal: value = thermal(metrics.thermal)
        }
        return L10n.text("status.item.\(item.rawValue)") + " " + (value.isEmpty ? "—" : value)
    }
}

struct SystemStatusDetails: View {
    let metrics: SystemMetrics
    var showMetrics = true
    private let info = LocalHostInfo.read()
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("status.details")).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                row("status.host", info.name)
                row("status.system", info.system)
                row("status.chip", info.chip)
                row("status.cores", String(info.cores))
                row("status.item.memory", SystemStatusFormat.bytes(Int64(metrics.memoryTotal)))
            }
            if showMetrics {
            Divider()
            ForEach(SystemMetrics.Item.allCases.filter { ConfigurationStore.shared.configuration.statusItems.contains($0) }, id: \.self) { item in
                Text(SystemStatusFormat.text(item, metrics: metrics)).font(.system(size: 11, design: .monospaced))
            }
            Text(L10n.text("status.memory.help")).font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("status.network.help")).font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("status.thermal.help")).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16).frame(width: 400, alignment: .leading)
    }
    private func row(_ key: String, _ value: String) -> some View {
        GridRow { Text(L10n.text(key)).foregroundStyle(.secondary); Text(value).textSelection(.enabled).accessibilityIdentifier(key) }
    }
}

nonisolated struct LocalHostInfo {
    var name: String
    var system: String
    var chip: String
    var cores: Int
    static func read() -> Self {
        var size = 0
        var chip = "Apple silicon"
        if sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 && size < 256 {
            var bytes = [CChar](repeating: 0, count: size)
            if sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 {
                chip = String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        let process = ProcessInfo.processInfo
        let version = process.operatingSystemVersion
        return Self(name: process.hostName, system: "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                    chip: chip, cores: process.processorCount)
    }
}
