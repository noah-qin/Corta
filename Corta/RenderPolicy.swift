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
import QuartzCore

/// Adapts a pane's frame-rate ceiling to focus, Low Power Mode, thermal
/// pressure and scrolling. It only spaces wakeups on a running link;
/// `FrameScheduler.isPaused` still decides whether any happen
/// (`PERFORMANCE.md` §3). It matters for a pane flooding output while
/// hidden, throttled or on battery.
///
/// `preferredFrameLatency` is left at its default, and not for want of
/// trying. The unit is frames: "the amount of time, in frames, your app
/// requests to render a frame", and the system may make the final latency
/// larger in a window on macOS. The default reads 2.0 and anything under
/// 1 reads back as 1.0. Measured keypress to glass at the default, 1 and 2
/// on a 60 Hz panel, 1 moved neither the median nor the tail by anything
/// like the frame it asks for (`PERFORMANCE.md` §5.7), so nothing is set;
/// `CORTA_FRAME_LATENCY` stays as the seam to measure it again.
final class RenderPolicy {
    private weak var scheduler: FrameScheduler?
    private var thermalObserver: NSObjectProtocol?
    private var powerStateObserver: NSObjectProtocol?
    private var keyObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?
    private var isWindowActive: Bool
    private var isScrolling = false
    private(set) var isTyping = false
    private weak var window: NSWindow?
    private var screenObservers: [NSObjectProtocol] = []
    private var typingExpiry: DispatchWorkItem?
    static let typingGrace: TimeInterval = 1

    nonisolated struct Inputs: Equatable {
        var isScrolling: Bool
        var isTyping: Bool
        var thermalState: ProcessInfo.ThermalState
        var isLowPowerModeEnabled: Bool
        var isWindowActive: Bool
        var maximumFramesPerSecond: Int
    }

    nonisolated static func range(for inputs: Inputs) -> CAFrameRateRange {
        // Critical pressure protects the machine even during interaction.
        if inputs.thermalState == .critical { return thermalPressure }
        let maxFPS = Float(max(60, inputs.maximumFramesPerSecond))
        if inputs.isScrolling || inputs.isTyping {
            return maxFPS > 60
                ? CAFrameRateRange(minimum: 60, maximum: maxFPS, preferred: maxFPS)
                : .default
        }
        if inputs.thermalState == .serious { return thermalPressure }
        if inputs.isLowPowerModeEnabled { return lowPower }
        if !inputs.isWindowActive { return inactiveWindow }
        return maxFPS > 60
            ? CAFrameRateRange(minimum: 60, maximum: maxFPS, preferred: 60)
            : .default
    }

    func noteInput() {
        typingExpiry?.cancel()
        isTyping = true
        apply()
        let expiry = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.isTyping = false
                self?.typingExpiry = nil
                self?.apply()
            }
        }
        typingExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.typingGrace, execute: expiry)
    }

    /// Ceilings, increasingly restrictive; never zero, since a restricted
    /// window still redraws on change. Modest, and due the same measurement.
    nonisolated private static let inactiveWindow = CAFrameRateRange(minimum: 1, maximum: 30, preferred: 15)
    nonisolated private static let lowPower = CAFrameRateRange(minimum: 1, maximum: 30, preferred: 15)
    nonisolated private static let thermalPressure = CAFrameRateRange(minimum: 1, maximum: 20, preferred: 10)

    /// - Parameter window: observed for key/resign to track focus.
    init(scheduler: FrameScheduler, window: NSWindow?) {
        self.scheduler = scheduler
        self.window = window
        self.isWindowActive = window?.isKeyWindow ?? true

        let center = NotificationCenter.default
        thermalObserver = center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        powerStateObserver = center.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        if let window {
            keyObserver = center.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowActiveStateChanged(true) }
            }
            resignObserver = center.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowActiveStateChanged(false) }
            }
        }
        for name in [NSWindow.didChangeScreenNotification, NSApplication.didChangeScreenParametersNotification] {
            screenObservers.append(center.addObserver(
                forName: name, object: name == NSWindow.didChangeScreenNotification ? window : nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            })
        }
        apply()
    }

    isolated deinit {
        typingExpiry?.cancel()
        let center = NotificationCenter.default
        for observer in screenObservers { center.removeObserver(observer) }
        if let thermalObserver { center.removeObserver(thermalObserver) }
        if let powerStateObserver { center.removeObserver(powerStateObserver) }
        if let keyObserver { center.removeObserver(keyObserver) }
        if let resignObserver { center.removeObserver(resignObserver) }
    }

    private func windowActiveStateChanged(_ isActive: Bool) {
        isWindowActive = isActive
        apply()
    }

    /// Trackpad phase transitions from `TerminalView.scrollWheel(with:)`. A
    /// wheel has no phase, so it just never lifts the ceiling.
    func scrollingStateChanged(_ scrolling: Bool) {
        guard isScrolling != scrolling else { return }
        isScrolling = scrolling
        apply()
    }

    private func apply() {
        guard let scheduler else { return }
        let info = ProcessInfo.processInfo
        scheduler.preferredFrameRateRange = Self.range(for: Inputs(
            isScrolling: isScrolling, isTyping: isTyping, thermalState: info.thermalState,
            isLowPowerModeEnabled: info.isLowPowerModeEnabled, isWindowActive: isWindowActive,
            maximumFramesPerSecond: window?.screen?.maximumFramesPerSecond ?? 60))
    }
}
