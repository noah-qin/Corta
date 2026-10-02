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

#if DEBUG
import Testing
import CortaTerminal
@testable import Corta

@MainActor
struct SFTPDevelopmentPreviewTests {
    @Test func previewConnectsAndNavigatesWithoutServer() async {
        let model = SFTPBrowserModel(host: "demo.invalid", startDirectory: "/home/demo") { _ in SFTPPreviewClient() }
        defer { model.disconnect() }
        model.connect()
        await waitUntil("preview connection") { model.connectionState == .connected }
        #expect(model.entries.contains { $0.name == "README.md" && $0.kind == .file })
        #expect(model.entries.contains { $0.name == "src" && $0.kind == .directory })
        model.navigate(to: "/home/demo/src")
        await waitUntil("preview folder") { !model.isLoading }
        #expect(model.currentPath == "/home/demo/src")
        #expect(model.entries.contains { $0.name == "main.swift" })
        model.navigate(to: "/home/demo/empty")
        await waitUntil("preview empty folder") { !model.isLoading }
        #expect(model.entries.isEmpty)
    }
    @Test func previewRejectsWrites() async {
        let client = SFTPPreviewClient()
        await #expect(throws: SFTPError.server(SFTPStatus(code: .permissionDenied))) {
            try await client.makeDirectory(path: "/home/demo/test")
        }
        await #expect(throws: SFTPError.server(SFTPStatus(code: .permissionDenied))) {
            try await client.remove(path: "/home/demo/README.md")
        }
    }
    @Test func previewTransferRowsAreDisplayOnly() {
        let queue = SFTPTransferQueue()
        queue.installDevelopmentPreview()
        #expect(queue.transfers.count == 3)
        #expect(queue.transfers.contains { if case .active = $0.state { true } else { false } })
        #expect(queue.transfers.contains { if case .done = $0.state { true } else { false } })
        queue.disconnect()
    }
}
#endif
