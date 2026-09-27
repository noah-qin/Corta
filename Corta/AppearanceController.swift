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

/// Resolves the theme and appearance into the live colour variant, and
/// follows Dark Mode while running. KVO on `NSApp.effectiveAppearance`,
/// not `AppleInterfaceThemeChanged`, which fires before AppKit updates.
@MainActor
final class AppearanceController: NSObject {
    static let shared = AppearanceController()

    /// Posted when the variant changes; the system can change it with no
    /// config change.
    static let didChange = Notification.Name("dev.noahqin.Corta.appearanceDidChange")

    private var appearanceObservation: NSKeyValueObservation?

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(configurationChanged),
            name: ConfigurationStore.didChange, object: nil)
    }

    /// Once `NSApp` exists, from `applicationDidFinishLaunching`.
    func start() {
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        apply()
    }

    /// Built-in or custom; an unknown name falls back to the default.
    var theme: Theme {
        let configuration = ConfigurationStore.shared.configuration
        return Theme.named(configuration.theme, in: configuration) ?? .corta
    }

    /// `auto` asks AppKit, so it follows Dark Mode.
    var isDark: Bool {
        switch ConfigurationStore.shared.configuration.appearance {
        case .light: return false
        case .dark: return true
        case .auto:
            return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    func apply() {
        // An explicit choice applies app-wide so the chrome matches; nil
        // follows macOS.
        let forced: NSAppearance?
        switch ConfigurationStore.shared.configuration.appearance {
        case .auto: forced = nil
        case .light: forced = NSAppearance(named: .aqua)
        case .dark: forced = NSAppearance(named: .darkAqua)
        }
        if NSApp.appearance != forced { NSApp.appearance = forced }

        TerminalColorPalette.apply(theme.variant(dark: isDark))
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    @objc private func configurationChanged() { apply() }
}
