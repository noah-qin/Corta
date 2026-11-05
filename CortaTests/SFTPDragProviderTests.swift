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
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import Corta

@MainActor
struct SFTPDragProviderTests {
    @Test("a dragged row's file loads with the main thread occupied, and only when asked")
    func dragProviderNeedsNoMainActor() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("Corta-Drag-Test-" + UUID().uuidString)
        try Data("remote".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let exports = Mutex(0)
        let provider = SFTPDragItem(name: "notes.txt") {
            exports.withLock { $0 += 1 }
            return file
        }.itemProvider()
        #expect(provider.suggestedName == "notes.txt")
        #expect(exports.withLock { $0 } == 0)
        let ready = DispatchSemaphore(value: 0)
        let contents = Mutex<Data?>(nil)
        provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { url, _ in
            contents.withLock { $0 = url.flatMap { try? Data(contentsOf: $0) } }
            ready.signal()
        }
        // A synchronous consumer on the main thread, as AppKit can be while
        // tracking; a main-actor provider would never answer this.
        #expect(ready.wait(timeout: .now() + .seconds(10 * testTimeoutScale)) == .success)
        #expect(contents.withLock { $0 } == Data("remote".utf8))
    }
}
