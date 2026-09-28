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

    /// Ceilings, increasingly restrictive; never zero, since a restricted
    /// window still redraws on change. Modest, and due the same measurement.
    private static let unrestricted = CAFrameRateRange.default
    private static let inactiveWindow = CAFrameRateRange(minimum: 1, maximum: 30, preferred: 15)
    private static let lowPower = CAFrameRateRange(minimum: 1, maximum: 30, preferred: 15)
    private static let thermalPressure = CAFrameRateRange(minimum: 1, maximum: 20, preferred: 10)

    /// - Parameter window: observed for key/resign to track focus.
    init(scheduler: FrameScheduler, window: NSWindow?) {
        self.scheduler = scheduler
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
        apply()
    }

    isolated deinit {
        let center = NotificationCenter.default
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
        // Scrolling first: full rate for the seconds a gesture lasts, even when
        // throttled.
        if isScrolling {
            scheduler.preferredFrameRateRange = Self.unrestricted
            return
        }
        let info = ProcessInfo.processInfo
        if info.thermalState == .serious || info.thermalState == .critical {
            scheduler.preferredFrameRateRange = Self.thermalPressure
        } else if info.isLowPowerModeEnabled {
            scheduler.preferredFrameRateRange = Self.lowPower
        } else if !isWindowActive {
            scheduler.preferredFrameRateRange = Self.inactiveWindow
        } else {
            scheduler.preferredFrameRateRange = Self.unrestricted
        }
    }
}
