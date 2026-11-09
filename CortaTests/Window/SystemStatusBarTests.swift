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

@testable import Corta

/// `stop` removes the bar's observations by name rather than every one
/// registered on the view, so it has to name each of them.
@MainActor
struct SystemStatusBarTests {
    /// A refresh puts `isHidden` back to what the configuration says, and
    /// reports the change; flipping it first makes a refresh observable.
    private func refreshes(_ bar: SystemStatusBar, on name: Notification.Name) -> Bool {
        var reported = false
        bar.onVisibilityChange = { reported = true }
        bar.isHidden.toggle()
        NotificationCenter.default.post(name: name, object: nil)
        bar.onVisibilityChange = nil
        return reported
    }

    @Test("the bar refreshes on its notifications until it is stopped, not after")
    func stopDetachesEveryNotification() {
        let bar = SystemStatusBar(frame: NSRect(x: 0, y: 0, width: 400, height: SystemStatusBar.height))
        #expect(refreshes(bar, on: SystemMetricsStore.didChange))
        bar.stop()
        for name in [
            ConfigurationStore.didChange, SystemMetricsStore.didChange,
            NSWindow.didChangeOcclusionStateNotification, AppearanceController.didChange,
            AppearanceController.paletteDidStep,
        ] {
            #expect(!refreshes(bar, on: name), "still observing \(name.rawValue) after stop")
        }
    }

    @Test("a normal thermal state says nothing; a serious one is coloured")
    func thermalShowsOnlyWhenItMatters() {
        var metrics = SystemMetrics()
        metrics.thermal = .nominal
        #expect(SystemStatusFormat.compact(.thermal, metrics: metrics) == nil)
        metrics.thermal = .serious
        #expect(SystemStatusFormat.compact(.thermal, metrics: metrics)?.warning == .systemOrange)
    }

    @Test("a value gaining digits leaves the columns after it where they were")
    func columnsHoldTheirPlace() {
        func stops(cpu: Double, rate: Double, width: CGFloat) -> [CGFloat] {
            var metrics = SystemMetrics()
            metrics.cpuPercent = cpu
            metrics.memoryUsed = 1 << 30
            metrics.downloadRate = rate
            metrics.uploadRate = rate
            let line = SystemStatusFormat.compactLine(
                [.cpu, .load, .memory, .network, .disk], metrics: metrics, width: width)
            let style = line.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            return style?.tabStops.map(\.location) ?? []
        }
        // At the narrowest and at a real bar's width, where the gaps spread.
        for width in [0, 900] as [CGFloat] {
            let quiet = stops(cpu: 3, rate: 900, width: width)
            #expect(quiet.count == 5)
            let busy = stops(cpu: 100, rate: 900 * 1024, width: width)
            #expect(quiet == busy, "\(quiet) vs \(busy)")
        }
    }

    /// Every bar redraws on the notification; an unchanged sample used to
    /// send it every two seconds regardless.
    @Test("an unchanged sample posts no change")
    func unchangedSamplePostsNothing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("config")
        try "status-bar = true\n".write(to: file, atomically: true, encoding: .utf8)
        let config = ConfigurationStore(fileURL: file)
        var fixed = SystemMetrics()
        fixed.cpuPercent = 12
        let constant = fixed
        let metrics = SystemMetricsStore(store: config) { _, _, _ in constant }
        final class Posts: Sendable { let count = Mutex(0) }
        let posts = Posts()
        let observer = NotificationCenter.default.addObserver(
            forName: SystemMetricsStore.didChange, object: metrics, queue: nil
        ) { _ in posts.count.withLock { $0 += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }
        let client = UUID()
        metrics.setActive(true, client: client)
        let deadline = SuspendingClock.now + .seconds(5)
        while posts.count.withLock({ $0 }) == 0, SuspendingClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(posts.count.withLock { $0 } == 1)
        metrics.setActive(false, client: client)
        metrics.setActive(true, client: client)
        try await Task.sleep(for: .milliseconds(300))
        #expect(posts.count.withLock { $0 } == 1)
        metrics.setActive(false, client: client)
    }

}
