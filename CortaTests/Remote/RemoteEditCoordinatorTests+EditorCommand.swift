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

import CortaSFTP
import Foundation
import Testing

@testable import Corta

/// Remote editing's editor command: the check that runs before a copy is
/// connected for or downloaded — nothing configured, a command that cannot
/// launch, and a command that can — and the explicit command that receives
/// a copy as data. The coordinator's opener and configuration read are the
/// test's, so no editor is launched and no config file is written.
extension RemoteEditCoordinatorTests {
    @Test("an edit with no editor configured says so before any connection or download")
    func unconfiguredEditorRefusesBeforeConnecting() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteEditStore(rootURL: root)
        let fake = FakeSFTPClient()
        var made = 0
        var opened = 0
        var problems: [RemoteEditCoordinator.EditorCommandProblem] = []
        let coordinator = RemoteEditCoordinator(
            store: store,
            makeClient: { _ in
                made += 1
                return fake
            },
            opener: { _, _, _ in
                opened += 1
                return true
            },
            presenter: .init(
                promptUpload: { _ in }, promptConflict: { _ in }, showError: { _ in },
                showEditorProblem: { problems.append($0) }))
        coordinator.openFileCommand = { "" }

        // The first Edit with nothing configured: the message says what to
        // set, and the consent question, the connection and the download
        // (up to 64 MiB) are all skipped. No file handler is ever tried.
        #expect(
            try await coordinator.open(
                host: "build-box", remotePath: "/srv/app/README.md", line: 1, column: nil)
                == .editorUnavailable)
        #expect(problems == [.notSet])
        #expect(problems.first?.message == L10n.text("remoteEdit.editorNeeded.notSet"))
        #expect(made == 0, "no connection attempt")
        #expect(fake.transferCalls.isEmpty, "nothing was downloaded")
        #expect(opened == 0, "the opener was never reached")
        #expect(store.copies.isEmpty, "no managed copy was recorded")
    }

    @Test("an editor command whose executable cannot be launched is named")
    func unusableEditorNamesItsExecutable() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var made = 0
        var problems: [RemoteEditCoordinator.EditorCommandProblem] = []
        let coordinator = RemoteEditCoordinator(
            store: RemoteEditStore(rootURL: root),
            makeClient: { _ in
                made += 1
                return FakeSFTPClient()
            },
            opener: { _, _, _ in true },
            presenter: .init(
                promptUpload: { _ in }, promptConflict: { _ in }, showError: { _ in },
                showEditorProblem: { problems.append($0) }))

        // Set, absolute, but not there: the message names the path.
        coordinator.openFileCommand = { "/nonexistent/corta-editor-523 --wait {file}" }
        #expect(
            try await coordinator.open(
                host: "build-box", remotePath: "/srv/app/main.rs", line: 1, column: nil)
                == .editorUnavailable)
        #expect(problems == [.missing("/nonexistent/corta-editor-523")])
        #expect(problems.first?.message.contains("/nonexistent/corta-editor-523") == true)

        // Set but not absolute: it would resolve through a PATH Corta does
        // not control, so it is refused with its first word named.
        problems.removeAll()
        coordinator.openFileCommand = { "code --goto {file}:{line}" }
        #expect(
            try await coordinator.open(
                host: "build-box", remotePath: "/srv/app/main.rs", line: 1, column: nil)
                == .editorUnavailable)
        #expect(problems == [.notAbsolute("code")])
        #expect(problems.first?.message.contains("code") == true)
        #expect(made == 0, "neither case connected")
    }

    @Test("a usable editor command leaves the edit unchanged")
    func usableEditorProceeds() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.coordinator.openFileCommand = { "/bin/sh {file}" }
        #expect(
            try await fixture.coordinator.open(
                host: "build-box", remotePath: "/srv/app/main.rs", line: 1, column: nil) == .opened)
        #expect(fixture.recorder.editorProblems.isEmpty)
        #expect(fixture.fake.transferCalls.count == 1, "the copy is still downloaded")
        #expect(fixture.recorder.opened.count == 1, "the editor still opens it")
    }

    @Test("an explicitly configured remote editor receives the file as data")
    func configuredRemoteEditorAllowed() {
        for name in ["file.swift", "evil.command", "semi;$(echo evil).terminal"] {
            #expect(PanePointer.openFileAt(
                url: URL(fileURLWithPath: "/tmp/" + name), line: 42, column: 7,
                command: "/usr/bin/true {file} {line} {column}"))
        }
    }

}
