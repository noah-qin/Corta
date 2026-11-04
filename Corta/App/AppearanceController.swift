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

    /// Once `NSApp` exists, from `applicationDidFinishLaunching`; a second
    /// call changes nothing.
    func start() {
        guard appearanceObservation == nil else { return }
        // AppKit re-sends this when an accessibility display option such as
        // Increase Contrast changes, even with Light or Dark forced.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        apply()
    }

    /// Built-in or custom, one per appearance; an unknown name falls back
    /// to the default.
    var theme: Theme { Theme.selected(in: ConfigurationStore.shared.configuration) }

    /// `auto` asks AppKit, so it follows Dark Mode.
    var isDark: Bool {
        switch ConfigurationStore.shared.configuration.appearance {
        case .light: return false
        case .dark: return true
        case .auto:
            return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    /// Posted for each step of a palette transition: colours only, so
    /// panes redraw without re-telling their sessions about the theme.
    static let paletteDidStep = Notification.Name("dev.noahqin.Corta.paletteDidStep")

    /// The variant the windows are headed for, so a change can blend to the next.
    private var appliedVariant: Theme.Variant?
    /// A palette transition under way: from where the canvas is, to where
    /// it is headed, since when.
    private struct Blend {
        var from: Theme.Variant
        var to: Theme.Variant
        var start: CFTimeInterval
    }
    private var blend: Blend?
    private var blendTimer: Timer?
    static let blendDuration: CFTimeInterval = 0.2

    func apply() {
        let variant = theme.variant(dark: isDark)
        let previous = appliedVariant
        appliedVariant = variant
        // An explicit choice applies app-wide so the chrome matches; nil
        // follows macOS.
        let forced: NSAppearance?
        switch ConfigurationStore.shared.configuration.appearance {
        case .auto: forced = nil
        case .light: forced = NSAppearance(named: .aqua)
        case .dark: forced = NSAppearance(named: .darkAqua)
        }
        if let previous, previous != variant, NSApp.windows.contains(where: \.isVisible) {
            // Before the appearance flips, so the fade starts from the old chrome.
            crossfadeWindows()
            beginBlend(to: variant)
        } else if previous != variant || blend == nil {
            endBlend()
            TerminalColorPalette.apply(variant)
        }
        if NSApp.appearance != forced { NSApp.appearance = forced }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// The chrome takes new colours with this run-loop pass and the Metal
    /// canvas a frame or two later (D25), so a switch showed a light band
    /// over a dark canvas for a frame. Each window dissolves from its old
    /// picture instead, titlebar included, while `beginBlend` carries the
    /// canvas and the band it shares a colour with across the same span.
    private func crossfadeWindows() {
        for window in NSApp.windows where window.isVisible {
            guard let layer = (window.contentView?.superview ?? window.contentView)?.layer else { continue }
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Self.blendDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(fade, forKey: "corta.appearance")
        }
    }

    /// Steps the palette from what is on screen to `target`: a jump would
    /// land the canvas a frame apart from the chrome.
    private func beginBlend(to target: Theme.Variant) {
        blend = Blend(from: TerminalColorPalette.activeVariant, to: target, start: CACurrentMediaTime())
        guard blendTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepBlend() }
        }
        RunLoop.main.add(timer, forMode: .common)
        blendTimer = timer
    }

    private func stepBlend() {
        guard let blend else { return endBlend() }
        let progress = min(1, Float((CACurrentMediaTime() - blend.start) / Self.blendDuration))
        guard progress < 1 else {
            endBlend()
            TerminalColorPalette.apply(blend.to)
            NotificationCenter.default.post(name: Self.didChange, object: nil)
            return
        }
        // Ease in and out, as the chrome's fade does.
        let eased = progress * progress * (3 - 2 * progress)
        TerminalColorPalette.apply(blend.from.mixed(with: blend.to, by: eased))
        NotificationCenter.default.post(name: Self.paletteDidStep, object: nil)
    }

    private func endBlend() {
        blendTimer?.invalidate()
        blendTimer = nil
        blend = nil
    }

    @objc private func configurationChanged() { apply() }
}
