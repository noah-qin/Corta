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

import SwiftUI

extension SettingsView {
    var generalPage: some View {
        Form {
            windowSection
            Section(L10n.text("settings.section.closing")) {
                Toggle(
                    L10n.text("settings.label.confirmClose"),
                    isOn: bind(\.confirmClose)
                )
                .help(L10n.text("settings.help.confirmClose"))
            }
            notificationsSection
            if UpdateController.isAvailable {
                Section(L10n.text("ui.section.updates")) {
                    Toggle(L10n.text("ui.update.auto"), isOn: bind(\.updateAutoCheck))
                    Toggle(L10n.text("ui.update.applications"), isOn: bind(\.suggestApplicationsFolder))
                }
            }
        }
    }

}
