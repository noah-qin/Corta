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

/// Opening Settings creates the file when there is none, and otherwise
/// leaves it as it is.
extension ConfigurationStoreTests {
    @Test("opening Settings leaves an existing file as written and keeps a relative preset through a change")
    func openingSettingsDoesNotRewriteTheFile() async throws {
        defer { removeDirectory() }
        let original = "# mine\npreset.work.shell = zsh\nfont-size = 14\n"
        try writeFile(original)
        let store = ConfigurationStore(fileURL: file)
        #expect(store.createIfMissing())
        #expect(try String(contentsOf: file, encoding: .utf8) == original)
        #expect(store.update { $0.bell = .audible })
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("preset.work.shell = zsh"))
    }

    @Test("opening Settings creates a missing file")
    func openingSettingsCreatesAMissingFile() async throws {
        defer { removeDirectory() }
        let store = ConfigurationStore(fileURL: file)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(store.createIfMissing())
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
