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
import Sparkle

/// Sparkle's standard updater: the background check on
/// `SUScheduledCheckInterval` (`Sparkle-Info.plist`) and Check for
/// Updates…. Started at launch so the interval means what it says.
///
/// Absent in the development build (D22), which the feed would offer to
/// replace with the release; the menu item is left out too.
@MainActor
final class UpdateController {
    static let shared = UpdateController()

    /// Nil in the development build (`isAvailable` false).
    private let controller: SPUStandardUpdaterController?

    static var isAvailable: Bool { !AppPaths.isDevelopmentBuild }

    private init() {
        controller =
            Self.isAvailable
            ? SPUStandardUpdaterController(
                startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
        applyAutoCheckSetting()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyAutoCheckSetting), name: ConfigurationStore.didChange,
            object: nil)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller?.checkForUpdates(sender)
    }

    /// `update-auto-check` gates only the background check, read live.
    @objc private func applyAutoCheckSetting() {
        controller?.updater.automaticallyChecksForUpdates =
            ConfigurationStore.shared.configuration.updateAutoCheck
    }
}
