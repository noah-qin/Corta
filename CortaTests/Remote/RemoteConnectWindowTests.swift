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
import Testing

@testable import Corta

@MainActor
@Suite(.serialized)
struct RemoteConnectWindowTests {
    private func close(_ controller: TerminalWindowController) {
        for tab in controller.tabs { tab.split.teardown() }
        controller.window?.close()
    }

    private var localPreset: Preset {
        var preset = Preset(name: "connection-routing-test")
        preset.shell = "/bin/sh"
        preset.arguments = ["-c", "read _"]
        return preset
    }

    @Test func eachDialogStartsWithTheCurrentPaneDefault() {
        let draft = RemoteConnectDraft()
        #expect(!draft.inNewWindow)
        draft.inNewWindow = true
        draft.reset(mode: .ssh)
        #expect(!draft.inNewWindow)
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func connectionReusesItsSourcePaneWithoutAddingTabs() async throws {
        let delegate = AppDelegate()
        let source = delegate.makeWindowController()
        source.showWindow(nil)
        defer { close(source) }
        let original = try #require(source.selectedTab)
        let pane = try #require(original.split.focusedPane)
        let session = try #require(pane.session)
        let other = delegate.makeWindowController()
        other.showWindow(nil)
        other.window?.makeKeyAndOrderFront(nil)
        defer { close(other) }
        let result = delegate.launchConnection(localPreset, from: source.window, inNewWindow: false)
        #expect(result === source)
        #expect(source.tabs.count == 1)
        #expect(other.tabs.count == 1)
        #expect(original.split.focusedPane === pane)
        #expect(pane.launchedCommand?.executable == localPreset.shell)
        #expect(pane.launchedCommand?.arguments == localPreset.arguments)
        #expect(original.split.focusedPane?.session !== session)
        await waitUntil("the replaced session exits") { session.pty.exitStatus != nil }
        #expect(session.pty.exitStatus != nil)
        #expect(!original.split.focusedPane!.didTeardown)
        #expect(source.selectedTab === original)
        #expect(source.selectedTab?.split.focusedPane?.preset == localPreset)
        #expect(RemoteConnectController.terminalWindow(
            from: source.window, main: other.window, ordered: [other.window!]) === source.window)
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func explicitWindowAndMissingOrClosedSourcesCreateWindows() throws {
        let delegate = AppDelegate()
        let source = delegate.makeWindowController()
        source.showWindow(nil)
        defer { close(source) }
        let separate = delegate.launchConnection(localPreset, from: source.window, inNewWindow: true)
        defer { close(separate) }
        #expect(separate !== source)
        #expect(source.tabs.count == 1)
        #expect(separate.tabs.count == 1)
        #expect(separate.selectedTab?.split.focusedPane?.preset == localPreset)
        let missing = delegate.launchConnection(localPreset, from: nil, inNewWindow: false)
        defer { close(missing) }
        #expect(missing !== source)
        #expect(missing.tabs.count == 1)
        source.window?.orderOut(nil)
        let closed = delegate.launchConnection(localPreset, from: source.window, inNewWindow: false)
        defer { close(closed) }
        #expect(closed !== source)
        #expect(RemoteConnectController.terminalWindow(
            from: source.window, main: nil, ordered: []) == nil)
        #expect(RemoteConnectController.terminalWindow(
            from: NSPanel(), main: separate.window, ordered: []) === separate.window)
    }
}
