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

@MainActor
struct SFTPOperationContextTests {
    @Test func renameKeepsDirectoryShownInPrompt() async throws {
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [makeEntry("a.txt")]
        fake.listings["/srv/other"] = [makeEntry("a.txt")]
        let model = SFTPBrowserModel(host: "test-host", startDirectory: "/srv/app") { _ in fake }
        model.connect()
        await waitUntil("connected") { model.connectionState == .connected }
        defer { model.disconnect() }
        let entry = try #require(model.entries.first)
        // A directory request is in flight while the old rows remain usable.
        model.navigate(to: "/srv/other")
        model.requestRename(entry)
        await waitUntil("navigation completed behind the sheet") { model.currentPath == "/srv/other" }
        model.commitTextPrompt("renamed.txt")
        await waitUntil("renamed") { !fake.renamed.isEmpty }
        #expect(fake.renamed.first?.from == "/srv/app/a.txt")
    }

    @Test func uploadKeepsDirectoryWherePickerOpened() async throws {
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = []
        fake.listings["/srv/other"] = []
        let model = SFTPBrowserModel(host: "test-host", startDirectory: "/srv/app") { _ in fake }
        model.connect()
        await waitUntil("connected") { model.connectionState == .connected }
        defer { model.disconnect() }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("corta-review-\(UUID().uuidString).txt")
        try Data("fixture".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        model.pickUploadFiles = {
            await waitUntil("navigation completed behind picker") { model.currentPath == "/srv/other" }
            return [source]
        }
        model.navigate(to: "/srv/other")
        model.requestUpload()
        await waitUntil("uploaded") { !fake.transferCalls.isEmpty }
        #expect(fake.transferCalls.first?.remotePath == "/srv/app/" + source.lastPathComponent)
    }

    @Test func newDirectoryKeepsDirectoryShownInPrompt() async throws {
        let fake = FakeSFTPClient()
        let model = SFTPBrowserModel(host: "test-host", startDirectory: "/srv/app") { _ in fake }
        model.connect()
        await waitUntil("connected") { model.connectionState == .connected }
        defer { model.disconnect() }
        model.navigate(to: "/srv/other")
        model.requestNewDirectory()
        await waitUntil("navigation completed") { model.currentPath == "/srv/other" }
        model.commitTextPrompt("new-folder")
        await waitUntil("directory created") { !fake.madeDirectories.isEmpty }
        #expect(fake.madeDirectories == ["/srv/app/new-folder"])
    }

    @Test func textPromptCannotRunOnAReplacementConnection() async throws {
        let first = FakeSFTPClient()
        let second = FakeSFTPClient()
        let model = SFTPBrowserModel(host: "host-a", startDirectory: "/srv/app") {
            $0 == "host-a" ? first : second
        }
        model.connect()
        await waitUntil("connected to a") { model.connectionState == .connected }
        defer { model.disconnect() }
        model.requestNewDirectory()
        model.changeHost()
        model.fields = SSHTargetFields(host: "host-b")
        model.connect()
        await waitUntil("connected to b") { model.connectionState == .connected }
        model.commitTextPrompt("wrong-host")
        // Drain main-actor tasks so a wrongly enqueued mutation is observable.
        await Task.yield()
        #expect(first.madeDirectories.isEmpty)
        #expect(second.madeDirectories.isEmpty)
    }

    @Test func uploadPickerCannotRunOnAReplacementConnection() async throws {
        let first = FakeSFTPClient()
        let second = FakeSFTPClient()
        let model = SFTPBrowserModel(host: "host-a", startDirectory: "/srv/app") {
            $0 == "host-a" ? first : second
        }
        model.connect()
        await waitUntil("connected to a") { model.connectionState == .connected }
        defer { model.disconnect() }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("corta-upload-\(UUID().uuidString)")
        try Data("fixture".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        var answered = false
        model.pickUploadFiles = {
            model.changeHost()
            model.fields = SSHTargetFields(host: "host-b")
            model.connect()
            await waitUntil("connected to b") { model.connectionState == .connected }
            answered = true
            return [source]
        }
        model.requestUpload()
        await waitUntil("picker answered") { answered }
        await Task.yield()
        #expect(model.transfers.isEmpty)
        #expect(second.transferCalls.isEmpty)
    }
}
