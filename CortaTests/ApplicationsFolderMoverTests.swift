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
import Testing

@testable import Corta

/// The two decisions behind the move offer, as pure functions: whether the
/// running copy is translocated (and so cannot be moved), and whether an
/// installed copy is newer (and so must not be replaced). The alerts and the
/// move itself need a quarantined download and are checked by hand.
struct ApplicationsFolderMoverTests {
    @Test("a translocated launch is recognised by its mount")
    func translocationIsRecognised() {
        #expect(ApplicationsFolderMover.isTranslocated(URL(fileURLWithPath:
            "/private/var/folders/xy/abc/T/AppTranslocation/0A1B2C/d/Corta.app")))
        #expect(!ApplicationsFolderMover.isTranslocated(URL(fileURLWithPath:
            "/Users/someone/Downloads/Corta.app")))
    }

    @Test("build numbers compare as numbers, not as text")
    func versionsCompareNumerically() {
        #expect(ApplicationsFolderMover.isVersion("1.10", newerThan: "1.9"))
        #expect(ApplicationsFolderMover.isVersion("120", newerThan: "99"))
        #expect(!ApplicationsFolderMover.isVersion("1.1.1", newerThan: "1.1.1"))
        #expect(!ApplicationsFolderMover.isVersion("1.0.1", newerThan: "1.1.0"))
    }
}
