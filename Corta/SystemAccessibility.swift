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

/// Reduce Motion, Reduce Transparency and Increase Contrast in one place,
/// so no new animation or panel forgets one; `observe(_:)` follows live
/// changes. System preferences, never config keys: a copy would drift
/// (D10).
@MainActor
enum SystemAccessibility {
    /// Arrive at the final state instead of animating.
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Replace glass with an opaque fill: nothing may show through.
    static var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    /// Promote hairlines and secondary label colours.
    static var increaseContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// Zero under Reduce Motion, so call sites keep their animation code.
    static func duration(_ preferred: CFTimeInterval) -> CFTimeInterval {
        reduceMotion ? 0 : preferred
    }

    /// Full label colour under Increase Contrast, where 60% grey fails.
    static var secondaryLabelColor: NSColor {
        increaseContrast ? .labelColor : .secondaryLabelColor
    }

    /// Calls `handler` now and on any change, so setup and updates share one
    /// path. Retain the token; releasing it unregisters.
    static func observe(_ handler: @escaping @MainActor () -> Void) -> Any {
        let token = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: NSWorkspace.shared, queue: .main
        ) { _ in
            MainActor.assumeIsolated { handler() }
        }
        handler()
        return token
    }
}
