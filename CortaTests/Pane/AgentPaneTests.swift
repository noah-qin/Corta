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
import QuartzCore
import Testing

@testable import Corta
import CortaTerminal

struct AgentPanePayloadTests {
    @Test func cleansEveryHeaderFieldAndBoundsCommand() throws {
        let command = "false\u{1B}\u{007F}\u{009B}\u{202E}\n\u{2028}" + String(repeating: "x", count: 10_000)
        let payload = try #require(AgentPanePayload.make(
            text: "wide 界\tcontinued\u{0000}\u{001B}\u{007F}\u{009B}\u{200B}\nnext",
            paneName: "log\u{2063}", host: "remote\u{001B}", directory: "/srv\u{007F}",
            command: command, exitStatus: 7))
        let header = try #require(payload.text.split(separator: "\n").first)
        let prefix = "[from log · host remote · /srv · $ "
        let suffix = " · exit 7]"
        #expect(header.hasPrefix(prefix + "false  "))
        #expect(header.hasSuffix(suffix))
        #expect(header.count - prefix.count - suffix.count <= 200)
        #expect(payload.text.hasSuffix("\n```\nwide 界\tcontinued\nnext\n```"))
        #expect(payload.text.unicodeScalars.allSatisfy {
            $0.value == 9 || $0.value == 10
                || ($0.value >= 32 && !(127...159).contains($0.value) && !ConcealingScalars.contains($0.value))
        })
        #expect(!payload.text.hasSuffix("\n"))
    }

    @Test func usesLongerFenceAndPlainSelectionHeader() throws {
        let payload = try #require(AgentPanePayload.make(
            text: "output:\n```\n界\n", paneName: "Log", host: nil, directory: nil,
            command: nil, exitStatus: nil))
        #expect(payload.text == "[from Log]\n````\noutput:\n```\n界\n````")
    }

    @Test func capsAtLineEndsWithExactOmissionCounts() throws {
        let line = "界" + String(repeating: "a", count: 96) + "\n"
        let text = String(repeating: line, count: 400)
        let payload = try #require(AgentPanePayload.make(
            text: text, paneName: "Log", host: nil, directory: nil, command: nil, exitStatus: nil))
        #expect(payload.text == "[from Log]\n```\n" + String(repeating: line, count: 81)
            + "[… 74 lines (7400 bytes) omitted …]\n" + String(repeating: line, count: 245) + "```")
    }

    @Test func aLineTooLongForEitherEndIsOmittedWhole() throws {
        let text = String(repeating: "界", count: 12_000)
        let payload = try #require(AgentPanePayload.make(
            text: text, paneName: "Log", host: nil, directory: nil, command: nil, exitStatus: nil))
        #expect(payload.text == "[from Log]\n```\n[… 1 line (36000 bytes) omitted …]\n```")
    }

    @Test func terminalWrappedWideTextSurvives() throws {
        var terminal = Terminal(rows: 4, columns: 6, scrollbackLimit: 0)
        terminal.feed(Array("ab界cdmore".utf8))
        let grid = terminal.grid
        let range = SelectionRange(
            anchor: SelectionPoint(row: 0, column: 0), head: SelectionPoint(row: 1, column: 3))
        let payload = try #require(AgentPanePayload.make(
            text: Selection.text(of: range, in: grid), paneName: "Log", host: nil, directory: nil,
            command: nil, exitStatus: nil))
        #expect(payload.text.contains("ab界cdmore"))
    }
}

@MainActor
@Suite(.serialized)
struct AgentPaneTargetsTests {
    @Test func candidatesUseForegroundIdentityAcrossTabsOfOneWindow() throws {
        let window = TerminalWindowController(setup: .init())
        let other = TerminalWindowController(setup: .init())
        defer {
            for controller in [window, other] {
                for tab in controller.tabs { tab.split.teardown() }
                controller.window?.close()
            }
        }
        let source = try #require(window.selectedTab?.split.panes.first)
        let agent = try #require(window.addTab(select: false).split.panes.first)
        let shell = try #require(window.addTab(select: false).split.panes.first)
        let ssh = try #require(window.addTab(select: false).split.panes.first)
        let script = try #require(window.addTab(select: false).split.panes.first)
        var inspected: [TerminalPaneViewController] = []
        let candidates = AgentPaneTargets.candidates(in: window, excluding: source, configured: "ssh") { pane in
            inspected.append(pane)
            let member: ForegroundProgram.Member = switch pane {
            case shell: .init(name: "zsh")
            case ssh: .init(name: "ssh")
            case script: .init(name: "bash", entryPoint: "/tmp/claude")
            default: .init(name: "claude")
            }
            return .init(members: [member])
        }
        #expect(candidates == [agent])
        #expect(inspected == [agent, shell, ssh, script])
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func resolvingAnOfferReadsTheCurrentJobAndRejectsClosedPanes() throws {
        let window = TerminalWindowController(setup: .init())
        defer {
            for tab in window.tabs { tab.split.teardown() }
            window.window?.close()
        }
        let tab = window.addTab(select: false)
        let pane = try #require(tab.split.panes.first)
        let id = pane.taskNotifier.paneID
        let session = try #require(pane.session)
        let claude = ForegroundProgram(members: [.init(name: "claude")])
        let shell = ForegroundProgram(members: [.init(name: "zsh")])
        let live = AgentPaneTargets.resolve(id, sessionID: session.id, in: window, configured: "") { _ in claude }
        #expect(live === pane)
        #expect(AgentPaneTargets.resolve(id, sessionID: session.id, in: window, configured: "") { _ in shell } == nil)
        #expect(AgentPaneTargets.resolve(id, sessionID: UUID(), in: window, configured: "") { _ in claude } == nil)
        window.closeTab(tab)
        #expect(AgentPaneTargets.resolve(id, sessionID: session.id, in: window, configured: "") { _ in claude } == nil)
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func reportsMissingOutputAndMissingAgentInTheSource() throws {
        var preset = Preset(name: "No marks")
        preset.shell = "/bin/cat"
        let window = TerminalWindowController(setup: .init(preset: preset))
        defer {
            for tab in window.tabs { tab.split.teardown() }
            window.window?.close()
        }
        let source = try #require(window.selectedTab?.split.panes.first)
        let terminal = try #require(source.terminalView)
        func toast() -> String? {
            let label = terminal.toastLayer?.sublayers?.compactMap { $0 as? CATextLayer }.last
            return (label?.string as? NSAttributedString)?.string
        }

        source.commands.sendCommandOutputToAgent(nil)
        #expect(toast() == L10n.text("toast.noShellIntegration"))
        source.selectAll(nil)
        source.commands.sendSelectionToAgent(nil)
        #expect(toast() == L10n.text("toast.noAgentPane"))
        #expect(!source.composer.isOpen)
        #expect(source.composer.draft.isEmpty)
    }

    @Test func pickerFiltersNamesAndReturnsOnlyTheChosenPaneID() throws {
        let model = CommandPaletteModel()
        let one = CommandPaletteModel.AgentPaneTarget(id: UUID(), title: "First pane")
        let two = CommandPaletteModel.AgentPaneTarget(id: UUID(), title: "Second pane")
        var picked: UUID?
        model.onPickAgentPane = { picked = $0 }
        model.pickAgentPane([one, two])
        #expect(model.rows.filter(\.selectable).count == 2)
        model.query = "second"
        #expect(model.rows.filter(\.selectable) == [.agentPaneTarget(two)])
        model.runSelected()
        #expect(picked == two.id)
        model.clearAgentPanePicker()
        #expect(model.onPickAgentPane == nil)
        #expect(model.rows.contains { $0.command == .sendSelectionToAgent })
    }
}
