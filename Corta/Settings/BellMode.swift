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

import Foundation

/// What a BEL does; the core only reports one (`Terminal.takeBell()`).
/// Config file only (D10).
nonisolated enum BellMode: String, CaseIterable, Sendable {
    /// `NSSound.beep()`; not the default.
    case audible
    /// A brief flash; the default.
    case visual
    case muted

    /// Localised, not the config word capitalised.
    var displayName: String { L10n.text("bell.\(rawValue)") }
}
