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
import SwiftUI

extension SettingsView {
    var spacePage: some View {
        Form {
            Section(L10n.text("settings.section.space")) {
                Toggle(L10n.text("settings.label.agentMessages"), isOn: bind(\.agentMessages))
                    .help(L10n.text("settings.help.agentMessages"))
                Toggle(L10n.text("settings.label.spaceAttentionBadge"), isOn: bind(\.spaceAttentionBadge))
                Toggle(L10n.text("settings.label.waitingAutoAdvance"), isOn: bind(\.waitingQueueAutoAdvance))
            }
        }
    }
}
