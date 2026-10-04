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
import CortaTerminal
import Testing

@testable import Corta

@MainActor struct SystemStatusAndThemeEditorTests {
    @Test func statusConfigurationRoundTripsAndUnknownItemsArePreserved() {
        let (config, unknown) = Configuration.parse("status-bar = true\nstatus-items = cpu,thermal\nstatus-network-interface = en0")
        #expect(config.statusBar)
        #expect(config.statusItems == [.cpu, .thermal])
        #expect(config.statusNetworkInterface == "en0")
        #expect(unknown.isEmpty)
        #expect(Configuration.parse(config.serialized()).configuration == config)
        #expect(!Configuration().statusBar)
        let (_, future) = Configuration.parse("status-items = cpu,unknown-metric")
        #expect(future.count == 1)
    }

    @Test func deltasHandleCPUWrapAndNetworkResetsWithoutSpikes() {
        #expect(SystemMetricsSampler.cpuUsage(previous: [10, 0, 90, 0], current: [30, 0, 170, 0]) == 20)
        #expect(SystemMetricsSampler.cpuUsage(previous: [1, 1, 1, 1], current: [1, 1, 1, 1]) == nil)
        #expect(SystemMetricsSampler.cpuUsage(previous: [UInt32.max - 9, 0, 0, 0], current: [10, 0, 20, 0]) == 50)
        #expect(SystemMetricsSampler.counterDelta(1000, 10) == 0)
        #expect(SystemMetricsSampler.counterDelta(UInt32.max - 9, 10) == 20)
    }

    @Test func networkUsesOnlyOneInterfaceAndExplicitMissingInterfacesStayUnavailable() {
        let names = ["en0", "utun2", "awdl0"]
        #expect(SystemMetricsSampler.selectInterface(names, requested: "auto", primary: "en0") == "en0")
        #expect(SystemMetricsSampler.selectInterface(names, requested: "utun2", primary: "en0") == "utun2")
        #expect(SystemMetricsSampler.selectInterface(names, requested: "missing", primary: "en0") == nil)
        #expect(SystemMetricsSampler.selectInterface(names, requested: "auto", primary: nil) == "en0")
        #expect(SystemMetricsSampler.selectInterface([], requested: "auto", primary: nil) == nil)
    }

    @Test func nativeMetricsReadRealLocalState() async throws {
        let sampler = SystemMetricsSampler()
        let value = await sampler.sample(items: Set(SystemMetrics.Item.allCases), interface: "auto")
        #expect(value.cpuPercent == nil)
        #expect(value.load.count == 3)
        #expect(try #require(value.memoryUsed) > 0)
        #expect(value.memoryUsed! <= value.memoryTotal)
        #expect(value.memoryCompressed != nil)
        #expect(try #require(value.diskAvailable) >= 0)
        #expect(value.thermal != nil)
        try await Task.sleep(for: .milliseconds(250))
        let second = await sampler.sample(items: Set(SystemMetrics.Item.allCases), interface: "auto")
        #expect(try #require(second.cpuPercent) >= 0)
        #expect(second.cpuPercent! <= 100)
        await sampler.reset()
        let reset = await sampler.sample(items: [.cpu, .network], interface: "missing")
        #expect(reset.cpuPercent == nil)
        #expect(reset.downloadRate == nil)
    }

    private func makeStore() throws -> (ConfigurationStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("corta-features-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (ConfigurationStore(fileURL: directory.appendingPathComponent("config")), directory)
    }

    @Test func samplerIsSharedAndStopsAfterTheLastVisibleClient() throws {
        let (config, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        config.update { $0.statusBar = true; $0.statusItems = [.cpu] }
        let metrics = SystemMetricsStore(store: config)
        let first = UUID(), second = UUID()
        metrics.setActive(true, client: first)
        metrics.setActive(true, client: second)
        #expect(metrics.isSampling)
        metrics.setActive(false, client: first)
        #expect(metrics.isSampling)
        metrics.setActive(false, client: second)
        #expect(!metrics.isSampling)
        config.update { $0.statusBar = false }
        metrics.setActive(true, client: first)
        #expect(!metrics.isSampling)
        metrics.setActive(false, client: first)
    }

    @Test func themeDraftDoesNotTouchTheConfigUntilSaveAndRoundTripsBothVariants() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = store.configuration
        let editor = ThemeEditorModel(source: .corta, editing: false)
        editor.displayName = "Midnight"
        editor.setColor(1, Theme.color("#101018")!)
        editor.isDark = false
        editor.setColor(2, Theme.color("#ff00ff")!)
        #expect(store.configuration == before)
        #expect(editor.save(to: store))
        let theme = try #require(Theme.named(editor.themeID, in: store.configuration))
        #expect(theme.dark.background == Theme.color("#101018"))
        #expect(theme.light.cursor == Theme.color("#ff00ff"))
        #expect(store.configuration.theme == editor.themeID)
        let reparsed = Configuration.parse(try String(contentsOf: store.fileURL, encoding: .utf8)).configuration
        #expect(reparsed == store.configuration)
        #expect(Theme.corta.dark != theme.dark)
    }

    @Test func themeColorsClampExtendedSRGBAndRejectNonFiniteComponents() {
        let editor = ThemeEditorModel(source: .corta, editing: false)
        editor.setColor(1, SIMD4(-0.2, 1.2, 0.5, 0.2))
        #expect(editor.color(1) == SIMD4(0, 1, 0.5, 1))
        #expect(Theme.hex(editor.color(1)) == "#00ff80")
        editor.setColor(1, SIMD4(.nan, 0, 0, 1))
        #expect(editor.color(1) == SIMD4(0, 1, 0.5, 1))
    }

    @Test func themeSaveRejectsInvalidNamesAndConcurrentEdits() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = ThemeEditorModel(source: .corta, editing: false)
        editor.displayName = "bad#name"
        #expect(!editor.save(to: store))
        editor.displayName = "First"
        #expect(editor.save(to: store))
        let existing = try #require(store.configuration.customThemes.first)
        let editing = ThemeEditorModel(source: existing, editing: true)
        store.update { $0.customThemes.removeAll() }
        #expect(!editing.save(to: store))
        #expect(store.configuration.customThemes.isEmpty)
    }
}
