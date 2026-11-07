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
import QuartzCore
import SwiftUI
import Testing

@testable import Corta

@MainActor
struct SFTPLargeDirectoryBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CORTA_SFTP_DIRECTORY_BENCHMARK"] == "1"))
    func largeDirectory() async throws {
        for count in [10_000, 50_000, 100_000] {
            try await measureDirectory(count: count)
        }
    }

    private func measureDirectory(count: Int) async throws {
        let client = FakeSFTPClient()
        let small = "/home/tester"
        let large = small + "/large"
        client.listings = [
            small: [makeEntry("large", permissions: 0o040755)],
            large: (0..<count).map { index in
                makeEntry("report-\(index * 8191 % count).txt", size: UInt64(index * 17))
            },
        ]
        let model = SFTPBrowserModel(host: "benchmark.invalid", startDirectory: small) { _ in client }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SFTPBrowserView(model: model))
        window.orderFront(nil)
        defer {
            window.close()
            model.disconnect()
        }
        model.connect()
        try await waitFor("connection") { model.connectionState == .connected && model.entries.count == 1 }
        let root = try #require(window.contentView)
        try await waitFor("initial table") { table(in: root) != nil }

        try await measureNavigation(model: model, root: root, small: small, large: large, count: count)
    }

    private func measureNavigation(
        model: SFTPBrowserModel, root: NSView, small: String, large: String, count: Int
    ) async throws {
        for run in 1...3 {
            let open = try await measure {
                try await openDirectory(model: model, root: root, path: large, count: count)
            }
            let listing = try #require(table(in: root))
            let scroll = try await measure { try await scrollListing(listing, count: count) }
            let back = try await measure { try await goBack(model: model, root: root, path: small) }

            // Separately measure paging after scrolling. Returning from the
            // first scrolled page above matches the unpaged baseline.
            try await openDirectory(model: model, root: root, path: large, count: count)
            try await scrollListing(try #require(table(in: root)), count: count)
            let page = try await measure {
                model.showListingPage(model.listingPageCount - 1)
                try await waitFor("last page of \(count)") {
                    guard let updated = table(in: root) else { return false }
                    return updated.numberOfRows == model.listedEntries.count
                        && updated.rows(in: updated.visibleRect).contains(0)
                        && updated.rowView(atRow: 0, makeIfNecessary: false) != nil
                }
            }
            try await goBack(model: model, root: root, path: small)
            print("SFTP_BENCH count=\(count) run=\(run) open=\(open) scroll12=\(scroll) page=\(page) back=\(back)")
        }
    }

    private func openDirectory(model: SFTPBrowserModel, root: NSView, path: String, count: Int) async throws {
        model.navigate(to: path)
        try await waitFor("open \(count)") {
            guard let listing = table(in: root) else { return false }
            return model.currentPath == path && model.entries.count == count
                && listing.numberOfRows == min(count, SFTPBrowserModel.listingPageSize)
                && listing.rowView(atRow: 0, makeIfNecessary: false) != nil
        }
    }

    private func scrollListing(_ listing: NSTableView, count: Int) async throws {
        for row in stride(from: 40, through: 480, by: 40) {
            listing.scrollRowToVisible(row)
            try await waitFor("scroll to row \(row) of \(count)") {
                listing.rowView(atRow: row, makeIfNecessary: false) != nil
            }
            // Let the table finish a frame between scroll inputs.
            try await Task.sleep(for: .milliseconds(16))
        }
    }

    private func goBack(model: SFTPBrowserModel, root: NSView, path: String) async throws {
        model.navigateBack()
        try await waitFor("back to \(path)") {
            guard let listing = table(in: root) else { return false }
            return model.currentPath == path && listing.numberOfRows == 1
                && listing.rowView(atRow: 0, makeIfNecessary: false) != nil
        }
    }

    private func table(in view: NSView) -> NSTableView? {
        if let listing = view as? NSTableView { return listing }
        return view.subviews.lazy.compactMap { table(in: $0) }.first
    }

    private func waitFor(_ phase: String, _ ready: () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + 25
        while !ready() {
            try #require(CACurrentMediaTime() < deadline, "Timed out waiting for \(phase)")
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func measure(_ action: () async throws -> Void) async throws -> String {
        let start = CACurrentMediaTime()
        let heartbeat = MainHeartbeat(start: start)
        let timer = Timer(timeInterval: 0.008, repeats: true) { _ in
            MainActor.assumeIsolated { heartbeat.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        try await action()
        let elapsed = CACurrentMediaTime() - start
        heartbeat.tick()
        return String(format: "%.1fms/gap=%.1fms", elapsed * 1000, heartbeat.longest * 1000)
    }

    @MainActor
    private final class MainHeartbeat {
        var last: CFTimeInterval
        var longest: CFTimeInterval = 0

        init(start: CFTimeInterval) { last = start }

        func tick() {
            let now = CACurrentMediaTime()
            longest = max(longest, now - last)
            last = now
        }
    }
}
