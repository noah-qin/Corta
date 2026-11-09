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
    static let height: CGFloat = 20
    private let client = UUID()
    private let button = NSButton(title: "", target: nil, action: nil)
    private var popover: NSPopover?
    var onVisibilityChange: (() -> Void)?
    private static let observedNotifications = [
        ConfigurationStore.didChange, SystemMetricsStore.didChange,
        NSWindow.didChangeOcclusionStateNotification, AppearanceController.didChange,
        // Each step of a theme or appearance blend, so the bar's ground
        // fades with the window's rather than snapping at the end.
        AppearanceController.paletteDidStep,
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        button.isBordered = false
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
        // In line with the terminal's text above it, not the window's edge.
        let inset = PaneSurfaceView.margin + TerminalLayout.insets.left
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // Resolve the singleton before observing its first-load notification;
        // a non-default config posts during init and must not re-enter shared.
        refresh()
        for name in Self.observedNotifications {
            NotificationCenter.default.addObserver(self, selector: #selector(changed), name: name, object: nil)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    isolated deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refresh() }
    /// The columns spread over the bar's width, so a resize lays them out again.
    private var laidOutWidth: CGFloat = 0
    override func layout() {
        super.layout()
        guard button.bounds.width != laidOutWidth else { return }
        laidOutWidth = button.bounds.width
        updateLine()
    }

    /// The visible line alone, from the last sample: what a width change
    /// needs, without the side effects of a full `refresh`.
    private func updateLine() {
        let enabled = ConfigurationStore.shared.configuration.statusItems
        let items = SystemMetrics.Item.allCases.filter { enabled.contains($0) }
        button.attributedTitle = SystemStatusFormat.compactLine(
            items, metrics: SystemMetricsStore.shared.snapshot, width: button.bounds.width)
    }
    @objc private func changed() { refresh() }

    func stop() {
        popover?.close()
        SystemMetricsStore.shared.setActive(false, client: client)
        // By name: the view outlives `stop`, and it can carry registrations
        // AppKit made, which a bare `removeObserver(self)` would take with
        // it. Only `deinit`, where nothing is left to notify, removes all.
        for name in Self.observedNotifications {
            NotificationCenter.default.removeObserver(self, name: name, object: nil)
        }
    }

    private func refresh() {
        let config = ConfigurationStore.shared.configuration
        let wasHidden = isHidden
        isHidden = !config.statusBar
        // The window's own ground, the colour the pane cards sit on, with
        // no rule of its own: the bar is the window's bottom margin, not a
        // panel. Light or dark follows the canvas, as the tab strip does.
        let name: NSAppearance.Name = PaneSurfaceView.isLightCanvas ? .aqua : .darkAqua
        if appearance?.name != name { appearance = NSAppearance(named: name) }
        layer?.backgroundColor = PaneSurfaceView.gutterColor.cgColor
        let metrics = SystemMetricsStore.shared.snapshot
        let items = SystemMetrics.Item.allCases.filter { config.statusItems.contains($0) }
        let full = [L10n.text("status.local")] + items.map { SystemStatusFormat.text($0, metrics: metrics) }
        updateLine()
        let accessible = full.joined(separator: " · ")
        button.setAccessibilityValue(accessible)
        button.toolTip = accessible + "\n" + L10n.text("status.help")
        SystemMetricsStore.shared.setActive(
            config.statusBar && window?.occlusionState.contains(.visible) == true, client: client)
        if wasHidden != isHidden { onVisibilityChange?() }
        if popover?.isShown == true,
            let controller = popover?.contentViewController as? NSHostingController<SystemStatusDetails>,
            controller.rootView.metrics != metrics
        {
            controller.rootView = SystemStatusDetails(metrics: metrics, info: controller.rootView.info)
        }
    }

    @objc private func showDetails() {
        if popover?.isShown == true { popover?.close(); return }
        let popover = NSPopover()
        popover.behavior = .transient
        // The host's name, system and chip, read once per opening rather
        // than on every metrics update while it is open.
        popover.contentViewController = NSHostingController(
            rootView: SystemStatusDetails(metrics: SystemMetricsStore.shared.snapshot, info: LocalHostInfo.read()))
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
        return amount.formatted(.number.precision(.fractionLength(0...1)).grouping(.never)) + " " + units[index]
    }

    /// One metric as the bar shows it: a quiet label, its value, and a
    /// colour when the value is a warning. Nil when there is nothing to
    /// say: a thermal state that is normal is not news.
    struct Compact: Equatable {
        var label: String
        var value: String
        /// The widest value this metric is expected to show, so the metrics
        /// after it keep their place as its digits come and go.
        var template: String
        var warning: NSColor?
        /// How full, from 0 to 1, for a metric drawn with a meter.
        var fraction: Double?
    }

    static func compact(_ item: SystemMetrics.Item, metrics: SystemMetrics) -> Compact? {
        let label = L10n.text("status.short.\(item.rawValue)")
        func rate(_ value: Double?) -> String {
            guard let value, value.isFinite else { return "—" }
            return compactBytes(Int64(min(Double(Int64.max - 1024), max(0, value)))) + "/s"
        }
        switch item {
        case .cpu:
            let value = metrics.cpuPercent.map { ($0 / 100).formatted(.percent.precision(.fractionLength(0))) }
            return Compact(
                label: label, value: value ?? "—", template: (1.0).formatted(.percent.precision(.fractionLength(0))),
                fraction: metrics.cpuPercent.map { $0 / 100 })
        case .load:
            // The one-minute figure; all three are in the details.
            let value = metrics.load.first.map { $0.formatted(.number.precision(.fractionLength(2))) }
            return Compact(label: label, value: value ?? "—", template: "00.00")
        case .memory:
            let total = compactBytes(Int64(metrics.memoryTotal))
            let fraction = metrics.memoryUsed.map { Double($0) / Double(max(1, metrics.memoryTotal)) }
            return Compact(label: label, value: compactBytes(metrics.memoryUsed.map(Int64.init)) + " / " + total,
                           template: "000.0 GB / " + total, fraction: fraction)
        case .network:
            // The arrows say what it is; the interface is in the details.
            return Compact(label: "", value: "↓ \(rate(metrics.downloadRate))  ↑ \(rate(metrics.uploadRate))",
                           template: "↓ 000.0 KB/s  ↑ 000.0 KB/s")
        case .disk:
            return Compact(label: label, value: compactBytes(metrics.diskAvailable), template: "000.0 GB")
        case .thermal:
            guard let state = metrics.thermal, state != .nominal else { return nil }
            let warning: NSColor? = switch state {
            case .serious: .systemOrange
            case .critical: .systemRed
            default: nil
            }
            return Compact(label: label, value: thermal(state), template: "", warning: warning)
        }
    }

    /// The bar's line: Local, then each metric in a column of its own
    /// width, so a value that gains a digit does not push the rest along.
    /// With no width yet, the columns sit at the narrowest gap.
    /// Looked up once; its palette colour resolves when the bar draws.
    private static let hostSymbol = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 11, weight: .regular)
            .applying(.init(paletteColors: [.secondaryLabelColor])))

    /// One metric's column: its text, the template width that sets the gap
    /// — so the gap does not move as values change — and what it takes now,
    /// which only a value outgrowing its template exceeds.
    private struct Cell {
        let text: NSAttributedString
        let reserved: CGFloat
        let width: CGFloat
    }

    private static func cell(
        _ item: SystemMetrics.Item, metrics: SystemMetrics, font: NSFont,
        value valueAttributes: [NSAttributedString.Key: Any]
    ) -> Cell? {
        guard let part = compact(item, metrics: metrics) else { return nil }
        let labelAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        let space = NSAttributedString(string: " ", attributes: valueAttributes)
        let cell = NSMutableAttributedString()
        if !part.label.isEmpty {
            cell.append(NSAttributedString(string: part.label + " ", attributes: labelAttributes))
        }
        var meterWidth: CGFloat = 0
        if let fraction = part.fraction {
            let meter = meter(fraction, font: font)
            cell.append(meter)
            cell.append(space)
            meterWidth = meter.size().width + space.size().width
        }
        var attributes = valueAttributes
        if let warning = part.warning { attributes[.foregroundColor] = warning }
        cell.append(NSAttributedString(string: part.value, attributes: attributes))
        let prefix = part.label.isEmpty ? "" : part.label + " "
        let template = NSAttributedString(string: prefix + part.template, attributes: valueAttributes)
        let reserved = template.size().width + meterWidth
        return Cell(text: cell, reserved: reserved, width: max(reserved, cell.size().width))
    }

    /// The host mark and "Local", where the line starts.
    private static func leading(font: NSFont, value valueAttributes: [NSAttributedString.Key: Any])
        -> NSMutableAttributedString
    {
        let line = NSMutableAttributedString()
        if let host = hostSymbol {
            let attachment = NSTextAttachment()
            attachment.image = host
            attachment.bounds = NSRect(x: 0, y: (font.capHeight - host.size.height) / 2,
                                       width: host.size.width, height: host.size.height)
            line.append(NSAttributedString(attachment: attachment))
            line.append(NSAttributedString(string: " ", attributes: valueAttributes))
        }
        line.append(NSAttributedString(string: L10n.text("status.local"), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return line
    }

    static func compactLine(_ items: [SystemMetrics.Item], metrics: SystemMetrics,
                            width: CGFloat = 0) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let line = leading(font: font, value: valueAttributes)
        let cells = items.compactMap { cell($0, metrics: metrics, font: font, value: valueAttributes) }
        // One even gap between every column, Local included, so the line
        // spans the bar whichever metrics are on: Local at the leading
        // edge, the last metric flush with the trailing one, where the
        // panes above end. Narrower than that, the gaps keep a minimum and
        // the line is cut at its end. A few points in: the button's cell
        // insets its text.
        let minimumGap: CGFloat = 16
        let used = line.size().width + cells.reduce(0) { $0 + $1.reserved }
        let even = cells.isEmpty ? 0 : (width - 4 - used) / CGFloat(cells.count)
        let gap = max(minimumGap, even)
        var x = line.size().width
        var stops: [NSTextTab] = []
        for (index, cell) in cells.enumerated() {
            x += gap
            if index == cells.count - 1, even > minimumGap {
                stops.append(NSTextTab(textAlignment: .right, location: (width - 4).rounded(.down)))
            } else {
                stops.append(NSTextTab(textAlignment: .left, location: x.rounded()))
            }
            x += cell.width
            line.append(NSAttributedString(string: "\t", attributes: valueAttributes))
            line.append(cell.text)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = stops
        paragraph.lineBreakMode = .byTruncatingTail
        line.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
        return line
    }

    /// A small capsule meter, filled to `fraction`: accent while there is
    /// room, orange from three quarters, red from nine tenths. Drawn when
    /// the bar draws, so its colours follow the bar's appearance.
    static func meter(_ fraction: Double, font: NSFont) -> NSAttributedString {
        let size = NSSize(width: 26, height: 5)
        let level = min(1, max(0, fraction.isFinite ? fraction : 0))
        let image = NSImage(size: size, flipped: false) { rect in
            let track = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
            NSColor.labelColor.withAlphaComponent(0.1).setFill()
            track.fill()
            guard level > 0 else { return true }
            let width = max(rect.height, rect.width * level)
            let fill = NSRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
            let color: NSColor = level >= 0.9 ? .systemRed : level >= 0.75 ? .systemOrange : .controlAccentColor
            color.setFill()
            NSBezierPath(roundedRect: fill, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: ((font.capHeight - size.height) / 2).rounded(),
                                   width: size.width, height: size.height)
        return NSAttributedString(attachment: attachment)
    }

    static func text(_ item: SystemMetrics.Item, metrics: SystemMetrics) -> String {
        let value: String
        switch item {
        case .cpu:
            value = metrics.cpuPercent.map { ($0 / 100).formatted(.percent.precision(.fractionLength(0))) } ?? "—"
        case .load:
            value = metrics.load.map { $0.formatted(.number.precision(.fractionLength(2))) }.joined(separator: " / ")
        case .memory: value = bytes(metrics.memoryUsed.map(Int64.init)) + " / " + bytes(Int64(metrics.memoryTotal))
        case .network:
            value = "\(metrics.networkInterface ?? "—") ↓ \(rate(metrics.downloadRate)) ↑ \(rate(metrics.uploadRate))"
        case .disk: value = bytes(metrics.diskAvailable)
        case .thermal: value = thermal(metrics.thermal)
        }
        return L10n.text("status.item.\(item.rawValue)") + " " + (value.isEmpty ? "—" : value)
    }
}

struct SystemStatusDetails: View {
    let metrics: SystemMetrics
    var showMetrics = true
    /// Read by whoever opens the details: a view rebuilt per update read it
    /// again each time.
    let info: LocalHostInfo
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
            let items = ConfigurationStore.shared.configuration.statusItems
            ForEach(SystemMetrics.Item.allCases.filter { items.contains($0) }, id: \.self) { item in
                Text(SystemStatusFormat.text(item, metrics: metrics)).font(.system(size: 11, design: .monospaced))
            }
            Text(L10n.text("status.memory.help")).font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("status.network.help")).font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("status.thermal.help")).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16).frame(width: 400, alignment: .leading)
    }
    private func row(_ key: String, _ value: String) -> some View {
        GridRow {
            Text(L10n.text(key)).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).accessibilityIdentifier(key)
        }
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
        return Self(
            name: process.hostName,
            system: "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            chip: chip, cores: process.processorCount)
    }
}
