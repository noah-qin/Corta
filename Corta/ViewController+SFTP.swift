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

import Cocoa
import CortaTerminal

/// Browse Remote Files…, for the host this pane talks to. `.remote` knows
/// it; `.remoteUnknown` asks, since argv and screen text aren't honest
/// sources. `.local` and `.unknown` get no offer.
extension ViewController {
    /// The pure gate, for tests.
    nonisolated static func canBrowseRemoteFiles(state: PaneRemoteState) -> Bool {
        switch state {
        case .remote, .remoteUnknown: return true
        case .local, .unknown: return false
        }
    }

    var canBrowseRemoteFiles: Bool {
        Self.canBrowseRemoteFiles(state: paneRemoteState)
    }

    @objc func browseRemoteFiles(_ sender: Any?) {
        guard isOperable, canBrowseRemoteFiles else { return }
        SFTPBrowserController.show(for: self)
    }
}
