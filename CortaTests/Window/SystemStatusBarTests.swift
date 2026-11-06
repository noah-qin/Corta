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

/// `stop` removes the bar's observations by name rather than every one
/// registered on the view, so it has to name each of them.
@MainActor
struct SystemStatusBarTests {
    /// A refresh puts `isHidden` back to what the configuration says, and
    /// reports the change; flipping it first makes a refresh observable.
    private func refreshes(_ bar: SystemStatusBar, on name: Notification.Name) -> Bool {
        var reported = false
        bar.onVisibilityChange = { reported = true }
        bar.isHidden.toggle()
        NotificationCenter.default.post(name: name, object: nil)
        bar.onVisibilityChange = nil
        return reported
    }

    @Test("the bar refreshes on its notifications until it is stopped, not after")
    func stopDetachesEveryNotification() {
        let bar = SystemStatusBar(frame: NSRect(x: 0, y: 0, width: 400, height: SystemStatusBar.height))
        #expect(refreshes(bar, on: SystemMetricsStore.didChange))
        bar.stop()
        for name in [
            ConfigurationStore.didChange, SystemMetricsStore.didChange,
            NSWindow.didChangeOcclusionStateNotification, AppearanceController.didChange,
        ] {
            #expect(!refreshes(bar, on: name), "still observing \(name.rawValue) after stop")
        }
    }
}
