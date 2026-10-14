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

import CortaTerminal
import Foundation

/// Visibility changes get a grace period; input always wins over demotion.
nonisolated enum ReaderPriorityPolicy {
    static let grace: TimeInterval = 2
    static func priority(
        visible: Bool, selected: Bool, hiddenSince: TimeInterval?,
        lastInput: TimeInterval?, now: TimeInterval
    ) -> TerminalSession.ReaderPriority {
        if visible && selected { return .interactive }
        if let lastInput, now - lastInput < grace { return .interactive }
        guard let hiddenSince, now - hiddenSince >= grace else { return .interactive }
        return .background
    }
}
