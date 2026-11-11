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

/// Reduce Motion and Increase Contrast for AppKit views in one place, so no
/// new animation or panel forgets one; SwiftUI views read the same
/// preferences from their environment. A change while running reaches
/// AppKit views through `AppearanceController.didChange`. System
/// preferences, never config keys: a copy would drift (D10).
@MainActor
enum SystemAccessibility {
    /// Arrive at the final state instead of animating.
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Promote hairlines and secondary label colours.
    static var increaseContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// Zero under Reduce Motion, so call sites keep their animation code.
    static func duration(_ preferred: CFTimeInterval) -> CFTimeInterval {
        reduceMotion ? 0 : preferred
    }

    /// A system assistive technology that walks the UI is running: VoiceOver
    /// or Switch Control, the only two `NSWorkspace` reports. A braille
    /// display reaches the tree through VoiceOver, so VoiceOver covers it;
    /// Voice Control, Accessibility Inspector and third-party AX clients have
    /// no public "is attached" signal at all. This is therefore *not* "any
    /// client is attached" — it decides a visual affordance, while the
    /// string-free change notifications post unconditionally for the clients
    /// this cannot see (`TerminalView+Accessibility.swift`, D32).
    static var isVoiceOverOrSwitchControlRunning: Bool {
        NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled
    }
}
