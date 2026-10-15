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

import Foundation

/// One scalar line of the config file, `name = value`, declared once: how a
/// value reads into a `Configuration` and how the configuration writes it
/// back. `Configuration.parse` and `serialized` both walk
/// `Configuration.scalarSections`, so a key's name, parsing and spelling
/// cannot drift apart.
nonisolated struct ConfigurationKey: Sendable {
    let name: String
    /// False when the value does not parse: the line then survives verbatim
    /// for the user to fix (`Configuration.serialized(preserving:)`).
    let read: @Sendable (inout Configuration, String) -> Bool
    let write: @Sendable (Configuration) -> String

    typealias Path<Value> = WritableKeyPath<Configuration, Value> & Sendable

    static func flag(_ name: String, _ path: Path<Bool>) -> Self {
        Self(
            name: name,
            read: { configuration, value in
                guard let parsed = parseBool(value) else { return false }
                configuration[keyPath: path] = parsed
                return true
            },
            write: { String($0[keyPath: path]) })
    }

    static func choice<Value: RawRepresentable & Sendable>(_ name: String, _ path: Path<Value>) -> Self
    where Value.RawValue == String {
        Self(
            name: name,
            read: { configuration, value in
                guard let parsed = Value(rawValue: value) else { return false }
                configuration[keyPath: path] = parsed
                return true
            },
            write: { $0[keyPath: path].rawValue })
    }

    /// A parseable out-of-range value is clamped and rewritten canonically:
    /// every unbounded input needs a cap (`SECURITY.md` §3).
    static func integer(_ name: String, _ path: Path<Int>, in range: ClosedRange<Int>) -> Self {
        Self(
            name: name,
            read: { configuration, value in
                guard let parsed = Int(value) else { return false }
                configuration[keyPath: path] = range.clamped(parsed)
                return true
            },
            write: { String($0[keyPath: path]) })
    }

    static func number(_ name: String, _ path: Path<Double>, in range: ClosedRange<Double>) -> Self {
        Self(
            name: name,
            read: { configuration, value in
                guard let parsed = Double(value) else { return false }
                configuration[keyPath: path] = range.clamped(parsed)
                return true
            },
            write: { number($0[keyPath: path]) })
    }

    /// A `#rrggbb` (or any spelling `Theme.color` takes), written back
    /// canonically; empty means "the default".
    static func color(_ name: String, _ path: Path<String>) -> Self {
        Self(
            name: name,
            read: { configuration, value in
                guard let color = value.isEmpty ? "" : Theme.color(value).map(Theme.hex) else { return false }
                configuration[keyPath: path] = color
                return true
            },
            write: { $0[keyPath: path] })
    }

    static func parseBool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: return nil
        }
    }

    /// A whole number without its `.0`, as a person writes it.
    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

nonisolated extension Configuration {
    static let fontSizeRange: ClosedRange<Double> = 8...64
    static let columnsRange = 20...500
    static let rowsRange = 5...300
    static let scrollbackLinesRange = 0...1_000_000
    static let commandHistoryLimitRange = 0...10_000
    /// The settings page's bound. The file itself takes any value from 1.
    static let notificationThresholdRange: ClosedRange<Double> = 1...86_400

    /// The scalar keys in the order `serialized` writes them, under the
    /// comment that heads each group.
    static let scalarSections: [(heading: String, keys: [ConfigurationKey])] = [
        ("# Appearance", [
            ConfigurationKey(
                name: "theme",
                // Resolved at use: a custom theme may be defined further down.
                read: { configuration, value in
                    configuration.theme = value.isEmpty ? Theme.corta.name : value
                    return true
                },
                write: { $0.theme }),
            .choice("appearance", \.appearance),
            .choice("input-source-indicator", \.inputSourceIndicator),
            .choice("input-source-indicator-position", \.inputSourceIndicatorPosition),
            .color("input-source-direct-color", \.inputSourceDirectColor),
            .color("input-source-ime-color", \.inputSourceIMEColor),
            .flag("status-bar", \.statusBar),
            ConfigurationKey(
                name: "status-items",
                read: { configuration, value in
                    let names = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    let items = names.compactMap(SystemMetrics.Item.init(rawValue:))
                    guard items.count == names.count else { return false }
                    configuration.statusItems = Set(items)
                    return true
                },
                write: { configuration in
                    SystemMetrics.Item.allCases.filter { configuration.statusItems.contains($0) }
                        .map(\.rawValue).joined(separator: ",")
                }),
            ConfigurationKey(
                name: "status-network-interface",
                read: { configuration, value in
                    guard !value.isEmpty, value.count < 32,
                        value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
                    else { return false }
                    configuration.statusNetworkInterface = value
                    return true
                },
                write: { $0.statusNetworkInterface }),
            .choice("cursor-shape", \.cursorShape),
            .flag("cursor-blink", \.cursorBlink),
            ConfigurationKey(
                name: "font-family",
                // Legacy family names migrate to the single supported face.
                read: { configuration, _ in
                    configuration.fontFamily = Configuration.systemFontFamily
                    return true
                },
                write: { $0.fontFamily }),
            // The ⌘+/⌘− clamp: below ~8pt the cell degenerates.
            .number("font-size", \.fontSize, in: fontSizeRange),
        ]),
        ("# Terminal", [
            .integer("columns", \.columns, in: columnsRange),
            .integer("rows", \.rows, in: rowsRange),
            .integer("scrollback-lines", \.scrollbackLines, in: scrollbackLinesRange),
            .integer("command-history-limit", \.commandHistoryLimit, in: commandHistoryLimitRange),
            .choice("bell", \.bell),
            .flag("copy-on-select", \.copyOnSelect),
            .choice("link-activation", \.linkActivation),
            .choice("mouse-override-modifier", \.mouseOverrideModifier),
            .flag("option-as-meta", \.optionAsMeta),
            .flag("search-case-sensitive", \.searchCaseSensitive),
            .flag("search-regex", \.searchRegex),
            ConfigurationKey(
                name: "open-file-command",
                // Validated when set, not at click time. A bare name would
                // resolve through a `PATH` the user's shell controls, not Corta.
                read: { configuration, value in
                    guard Configuration.isUsableOpenFileCommand(value) else { return false }
                    configuration.openFileCommand = value
                    return true
                },
                write: { $0.openFileCommand }),
            .flag("allow-clipboard-write", \.allowClipboardWrite),
            .flag("directory-history", \.directoryHistory),
            .flag("directory-completion", \.directoryCompletion),
            .flag("command-status-marks", \.commandStatusMarks),
            .flag("restore-windows", \.restoreWindows),
            .flag("confirm-close", \.confirmClose),
            .flag("update-auto-check", \.updateAutoCheck),
            .flag("suggest-applications-folder", \.suggestApplicationsFolder),
            .flag("secure-keyboard-entry", \.secureKeyboardEntry),
        ]),
        ("# Quick Terminal: a panel summoned by a system-wide hotkey.", [
            .flag("quick-terminal", \.quickTerminal),
            ConfigurationKey(
                name: "quick-terminal-key",
                // Empty means no hotkey (menu and palette only). A shortcut
                // with no modifier is refused: it would swallow the key
                // system-wide.
                read: { configuration, value in
                    if value.isEmpty {
                        configuration.quickTerminalKey = nil
                        return true
                    }
                    guard let shortcut = Shortcut.parse(value), GlobalHotKey.isRegistrable(shortcut)
                    else { return false }
                    configuration.quickTerminalKey = shortcut
                    return true
                },
                write: { $0.quickTerminalKey?.text ?? "" }),
            .choice("quick-terminal-position", \.quickTerminalPosition),
            .choice("quick-terminal-screen", \.quickTerminalScreen),
        ]),
        ("# Notifications", [
            .flag("notify-on-long-task", \.notifyOnLongTask),
            .number("notification-threshold", \.notificationThreshold, in: 1...Double.greatestFiniteMagnitude),
        ]),
    ]

    static let scalarKeys: [String: ConfigurationKey] = Dictionary(
        uniqueKeysWithValues: scalarSections.flatMap(\.keys).map { ($0.name, $0) })
}

nonisolated extension ClosedRange {
    /// `value`, or the bound nearest it when it falls outside.
    func clamped(_ value: Bound) -> Bound {
        Swift.min(upperBound, Swift.max(lowerBound, value))
    }
}
