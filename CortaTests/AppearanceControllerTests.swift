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
import Testing

@testable import Corta

/// What AppKit views read of Increase Contrast is baked into layers, so a
/// change to the system's accessibility display options must reach them
/// as an appearance change. AppKit re-sends `effectiveAppearance` for one
/// (measured with Light or Dark forced too); this pins that it still does.
@MainActor
struct AppearanceControllerTests {
    @Test func anAccessibilityDisplayChangeIsAnAppearanceChange() {
        AppearanceController.shared.start()
        // Let a launch-time appearance change settle before listening.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        var heard = 0
        let token = NotificationCenter.default.addObserver(
            forName: AppearanceController.didChange, object: nil, queue: nil
        ) { _ in heard += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        // Only this process hears it; no system setting changes.
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: NSWorkspace.shared)
        let deadline = SuspendingClock.now + .seconds(TimeInterval(5 * testTimeoutScale))
        while heard == 0, SuspendingClock.now < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        #expect(heard >= 1)
    }
}
