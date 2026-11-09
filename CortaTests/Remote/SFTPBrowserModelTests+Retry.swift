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
import CortaSFTP
import Foundation
import Testing
@testable import Corta

/// Retry after a connection failed: where it reopens, and when it must not
/// move.
extension SFTPBrowserModelTests {
    /// Retry used to start over at the session's first folder, losing the
    /// one the failure interrupted and the way back from it.
    @Test("Retry on the same connection returns to the open folder and keeps Back")
    func retryReturnsToTheOpenFolder() async {
        let stalled = FakeSFTPClient()
        stalled.listings["/srv"] = []
        stalled.listings["/srv/app"] = []
        stalled.hangingListings = ["/hung"]
        let replacement = FakeSFTPClient()
        replacement.listings["/srv"] = []
        replacement.listings["/srv/app"] = []
        let model = SFTPBrowserModel(host: "build-box", startDirectory: "/srv") { _ in
            stalled.closed ? replacement : stalled
        }
        defer { model.disconnect() }
        model.connect()
        await waitUntil("initial listing") { model.connectionState == .connected }
        model.navigate(to: "/srv/app")
        await waitUntil("the folder opened") { !model.isLoading && model.currentPath == "/srv/app" }
        model.connectTimeout = .milliseconds(100)
        model.navigate(to: "/hung")
        await waitUntil("timed out") { model.isFailed }
        model.connectTimeout = .seconds(5)
        model.retry()
        await waitUntil("reconnected") { model.client === replacement && model.connectionState == .connected }
        #expect(model.currentPath == "/srv/app")
        #expect(!model.backStack.isEmpty)
    }

    @Test("Retry falls back to the start folder only when the open one is gone")
    func retryFallsBackWhenTheFolderIsGone() async {
        let stalled = FakeSFTPClient()
        stalled.listings["/srv"] = []
        stalled.listings["/srv/app"] = []
        stalled.hangingListings = ["/hung"]
        let replacement = FakeSFTPClient()
        replacement.listings["/srv"] = []
        replacement.listingErrors["/srv/app"] = .server(SFTPStatus(code: .noSuchFile))
        let model = SFTPBrowserModel(host: "build-box", startDirectory: "/srv") { _ in
            stalled.closed ? replacement : stalled
        }
        defer { model.disconnect() }
        model.connect()
        await waitUntil("initial listing") { model.connectionState == .connected }
        model.navigate(to: "/srv/app")
        await waitUntil("the folder opened") { !model.isLoading && model.currentPath == "/srv/app" }
        model.connectTimeout = .milliseconds(100)
        model.navigate(to: "/hung")
        await waitUntil("timed out") { model.isFailed }
        model.connectTimeout = .seconds(5)
        model.retry()
        await waitUntil("reconnected") { model.client === replacement && model.connectionState == .connected }
        #expect(model.currentPath == "/srv")
    }

    @Test("a broken connection while reopening the folder fails the retry, not moves it")
    func retryFailsOnATransportError() async {
        let stalled = FakeSFTPClient()
        stalled.listings["/srv"] = []
        stalled.listings["/srv/app"] = []
        stalled.hangingListings = ["/hung"]
        let replacement = FakeSFTPClient()
        replacement.listings["/srv"] = []
        replacement.listingErrors["/srv/app"] = .transport(.closed)
        let model = SFTPBrowserModel(host: "build-box", startDirectory: "/srv") { _ in
            stalled.closed ? replacement : stalled
        }
        defer { model.disconnect() }
        model.connect()
        await waitUntil("initial listing") { model.connectionState == .connected }
        model.navigate(to: "/srv/app")
        await waitUntil("the folder opened") { !model.isLoading && model.currentPath == "/srv/app" }
        model.connectTimeout = .milliseconds(100)
        model.navigate(to: "/hung")
        await waitUntil("timed out") { model.isFailed }
        model.connectTimeout = .seconds(5)
        model.retry()
        #expect(!model.isFailed)
        await waitUntil("the retry failed") { model.isFailed }
        #expect(model.isFailed)
        #expect(model.currentPath == "/srv/app")
    }
}
