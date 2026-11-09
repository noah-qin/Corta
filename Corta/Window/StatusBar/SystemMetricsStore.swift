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

/// One sampler for every window; no work while all enabled bars are hidden.
@MainActor final class SystemMetricsStore {
    static let shared = SystemMetricsStore()
    static let didChange = Notification.Name("dev.noahqin.Corta.systemMetricsDidChange")
    private(set) var snapshot = SystemMetrics()
    private let sampler = SystemMetricsSampler()
    private let store: ConfigurationStore
    /// The sample a poll takes; injected by tests.
    private let sample: @Sendable (SystemMetricsSampler, Set<SystemMetrics.Item>, String) async -> SystemMetrics

    init(
        store: ConfigurationStore = .shared,
        sample: @escaping @Sendable (SystemMetricsSampler, Set<SystemMetrics.Item>, String) async -> SystemMetrics = {
            await $0.sample(items: $1, interface: $2)
        }
    ) {
        self.store = store
        self.sample = sample
    }
    isolated deinit { timer?.invalidate(); task?.cancel() }
    private var clients: Set<UUID> = []
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var generation = 0
    var isSampling: Bool { timer != nil }

    func setActive(_ active: Bool, client: UUID) {
        if active { clients.insert(client) } else { clients.remove(client) }
        let config = store.configuration
        let needed = !clients.isEmpty && config.statusBar && !config.statusItems.isEmpty
        if needed && timer == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            timer.tolerance = 0.2
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
            poll()
        } else if !needed && (timer != nil || task != nil) {
            timer?.invalidate()
            timer = nil
            generation += 1
            task?.cancel()
            task = nil
            Task { await sampler.reset() }
        }
    }

    private func poll() {
        guard task == nil, timer != nil else { return }
        let config = store.configuration
        let generation = generation
        task = Task { [weak self, sampler, sample] in
            let value = await sample(sampler, config.statusItems, config.statusNetworkInterface)
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            self.task = nil
            // Every bar redraws on the notification: a sample that reads the
            // same as the last (an idle machine, most items) is no news.
            guard value != self.snapshot else { return }
            self.snapshot = value
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }
}
