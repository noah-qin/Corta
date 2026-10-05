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
@testable import CortaTerminal

/// A pane as its remote side sees it, with no session: the spawn record,
/// the preset, and a rebuild that only counts.
@MainActor
private final class RemoteTestHost: PaneRemoteHost {
    var session: TerminalSession! = nil
    var launchedCommand: (executable: String, arguments: [String])?
    var preset: Preset?
    var isOperable = false
    var terminalView: TerminalView! = nil
    private(set) var rebuilds: [Bool] = []
    private(set) lazy var remote = PaneRemote(host: self)

    func rebuildPane(strictRespawn: Bool) { rebuilds.append(strictRespawn) }
}

/// Reconnect's gate and wording, and the menu items it validates, against
/// `PaneRemote` alone. `PaneRemoteStateTests` covers the same side through
/// real panes and staged launchers.
@MainActor
struct PaneRemoteTests {
    @Test("a pane whose remote launcher never spawned can reconnect with the preset's command")
    func presetCommandReconnects() {
        let host = RemoteTestHost()
        var preset = Preset(name: "box")
        preset.shell = "/usr/bin/ssh"
        preset.arguments = ["box", "tmux", "attach"]
        host.preset = preset
        #expect(host.remote.reconnectCommand?.executable == "/usr/bin/ssh")
        #expect(host.remote.canReconnect)
        #expect(host.remote.reconnectNotice == L10n.text("toast.reconnectedReattach"))

        host.remote.reconnectRemote(nil)
        #expect(host.rebuilds == [true])
    }

    @Test("a local shell is never offered Reconnect, and the action refuses")
    func localShellDoesNotReconnect() {
        let host = RemoteTestHost()
        host.launchedCommand = ("/bin/zsh", ["-l"])
        #expect(!host.remote.canReconnect)
        host.remote.reconnectRemote(nil)
        #expect(host.rebuilds.isEmpty)
    }

    @Test("the spawn record beats the preset, and a plain ssh is not a reattach")
    func launchedCommandWins() {
        let host = RemoteTestHost()
        var preset = Preset(name: "local")
        preset.shell = "/bin/zsh"
        host.preset = preset
        host.launchedCommand = ("/usr/bin/ssh", ["box"])
        #expect(host.remote.reconnectCommand?.arguments == ["box"])
        #expect(host.remote.reconnectNotice == L10n.text("toast.reconnected"))
    }

    @Test("a failed pane is local and offers no browser")
    func failedPaneIsLocal() {
        let host = RemoteTestHost()
        host.launchedCommand = ("/usr/bin/ssh", ["box"])
        #expect(host.remote.state == .local)
        #expect(!host.remote.canBrowseFiles)
        #expect(!host.remote.childIsLiveLauncher)
    }

    @Test("the menu items follow the gates")
    func menuValidation() {
        let host = RemoteTestHost()
        let reconnect = NSMenuItem(
            title: "", action: #selector(PaneRemote.reconnectRemote(_:)), keyEquivalent: "")
        let browse = NSMenuItem(
            title: "", action: #selector(PaneRemote.browseRemoteFiles(_:)), keyEquivalent: "")
        #expect(!host.remote.validateMenuItem(reconnect))
        #expect(!host.remote.validateMenuItem(browse))
        host.launchedCommand = ("/usr/bin/ssh", ["box"])
        #expect(host.remote.validateMenuItem(reconnect))
    }

    @Test("the pane answers the remote actions and validates them as its remote side does")
    func paneForwardsRemoteActions() {
        // Not loaded: no session, nothing spawned, so neither applies.
        let pane = ViewController()
        for action in [
            #selector(PaneRemote.reconnectRemote(_:)), #selector(PaneRemote.browseRemoteFiles(_:)),
        ] {
            #expect(pane.responds(to: action))
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            #expect(!pane.validateMenuItem(item), "\(action)")
        }
    }
}
