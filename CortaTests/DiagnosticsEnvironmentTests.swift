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

import CortaTerminal
import Foundation
import Testing

@testable import Corta

/// The `CORTA_*` launch switches (#126): one type reads them, a child never
/// inherits one, and `docs/TESTING.md` lists them all. Every accessor is fed
/// a dictionary, never the process environment (D13).
struct DiagnosticsEnvironmentTests {
    private typealias Switch = DiagnosticsEnvironment.Switch

    @Test func everySwitchIsStrippedFromAChild() {
        var inherited = ["PATH": "/usr/bin:/bin"]
        for name in Switch.allCases { inherited[name.rawValue] = "/tmp/x" }
        let child = ChildEnvironment.sanitized(inheriting: inherited)
        for name in Switch.allCases {
            #expect(child[name.rawValue] == nil, "\(name.rawValue) reached the child")
        }
        #expect(child["PATH"] == "/usr/bin:/bin")
    }

    @Test func onlyTheProgramSubstitutionIsWithheldFromRelease() {
        #expect(Switch.allCases.filter { !$0.isHonouredInRelease } == [.sftpSSH])
    }

    @Test func frameDriverDefaultsAndDocumentedValues() {
        #expect(DiagnosticsEnvironment.frameDriver(in: [:]) == .displaylink)
        #expect(DiagnosticsEnvironment.frameDriver(in: ["CORTA_FRAME_DRIVER": "invalid"]) == .displaylink)
        // The unaccepted no-sync experiment must not disable vsync in a shipped build.
        #expect(DiagnosticsEnvironment.frameDriver(in: ["CORTA_FRAME_DRIVER": "ondemand-nosync"]) == .displaylink)
        for driver in DiagnosticsEnvironment.FrameDriver.allCases {
            #expect(DiagnosticsEnvironment.frameDriver(in: ["CORTA_FRAME_DRIVER": driver.rawValue]) == driver)
        }
    }

    @Test func measurementSwitchesParseOnlyTheirDocumentedValues() {
        #expect(DiagnosticsEnvironment.frameLatency(in: [:]) == nil)
        #expect(DiagnosticsEnvironment.frameLatency(in: ["CORTA_FRAME_LATENCY": "1"]) == 1)
        #expect(DiagnosticsEnvironment.frameLatency(in: ["CORTA_FRAME_LATENCY": "0.5"]) == nil)
        #expect(DiagnosticsEnvironment.frameLatency(in: ["CORTA_FRAME_LATENCY": "fast"]) == nil)

        #expect(DiagnosticsEnvironment.maxDrawables(in: ["CORTA_MAX_DRAWABLES": "2"]) == 2)
        #expect(DiagnosticsEnvironment.maxDrawables(in: ["CORTA_MAX_DRAWABLES": "3"]) == 3)
        #expect(DiagnosticsEnvironment.maxDrawables(in: ["CORTA_MAX_DRAWABLES": "4"]) == nil)
        #expect(DiagnosticsEnvironment.maxDrawables(in: [:]) == nil)

        #expect(!DiagnosticsEnvironment.isRenderMetricsEnabled(in: [:]))
        #expect(DiagnosticsEnvironment.isRenderMetricsEnabled(in: ["CORTA_RENDER_METRICS": "1"]))
        #expect(DiagnosticsEnvironment.renderMetricsFile(in: ["CORTA_RENDER_METRICS": "1"]) == nil)
        #expect(
            DiagnosticsEnvironment.renderMetricsFile(in: ["CORTA_RENDER_METRICS": "/tmp/m.txt"])?.path
                == "/tmp/m.txt")
        #expect(
            DiagnosticsEnvironment.renderMetricsKeystrokes(in: ["CORTA_RENDER_METRICS_KEYSTROKES": "50"])
                == 50)
        #expect(
            DiagnosticsEnvironment.renderMetricsKeystrokes(in: ["CORTA_RENDER_METRICS_KEYSTROKES": "0"])
                == nil)
    }

    @Test func onlyZeroSuppressesTheRestore() {
        #expect(DiagnosticsEnvironment.isWindowRestoreSuppressed(in: ["CORTA_RESTORE_WINDOWS": "0"]))
        #expect(!DiagnosticsEnvironment.isWindowRestoreSuppressed(in: ["CORTA_RESTORE_WINDOWS": "1"]))
        #expect(!DiagnosticsEnvironment.isWindowRestoreSuppressed(in: [:]))
    }

    @Test func aStageMustBeAbsolute() {
        #expect(
            DiagnosticsEnvironment.stageDirectory(in: ["CORTA_STAGE_DIR": "/tmp/stage"])?.path
                == "/tmp/stage")
        #expect(DiagnosticsEnvironment.stageDirectory(in: ["CORTA_STAGE_DIR": "stage"]) == nil)
    }

    @Test func theSSHOverrideNeedsADebugBuildAndAnAbsoluteExecutable() {
        let set = ["CORTA_SFTP_SSH": "/opt/fake-ssh"]
        #expect(
            DiagnosticsEnvironment.sftpSSHExecutable(in: set, isDebugBuild: true, isExecutable: { _ in true })
                == "/opt/fake-ssh")
        // A Release build never substitutes the program that holds the session.
        #expect(
            DiagnosticsEnvironment.sftpSSHExecutable(in: set, isDebugBuild: false, isExecutable: { _ in true })
                == nil)
        #expect(
            DiagnosticsEnvironment.sftpSSHExecutable(in: set, isDebugBuild: true, isExecutable: { _ in false })
                == nil)
        #expect(
            DiagnosticsEnvironment.sftpSSHExecutable(
                in: ["CORTA_SFTP_SSH": "fake-ssh"], isDebugBuild: true, isExecutable: { _ in true }) == nil)
        #expect(DiagnosticsEnvironment.sftpSSHExecutable(in: [:], isDebugBuild: true) == nil)
        // The real check, against a file that exists but cannot run.
        #expect(
            DiagnosticsEnvironment.sftpSSHExecutable(
                in: ["CORTA_SFTP_SSH": "/etc/hosts"], isDebugBuild: true) == nil)
        #expect(
            DiagnosticsEnvironment.sftpSSHExecutable(in: ["CORTA_SFTP_SSH": "/bin/sh"], isDebugBuild: true)
                == "/bin/sh")
    }

    // MARK: - One reader, one list

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)  // CortaTests/DiagnosticsEnvironmentTests.swift
            .deletingLastPathComponent()  // CortaTests
            .deletingLastPathComponent()  // repository root
    }

    @Test func theTestingGuideListsEverySwitch() throws {
        let guide = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("docs/TESTING.md"), encoding: .utf8)
        for name in Switch.allCases {
            #expect(guide.contains("| `\(name.rawValue)"), "docs/TESTING.md has no row for \(name.rawValue)")
        }
    }

    /// The issue's acceptance grep, kept: a new switch read anywhere else
    /// would be one this type does not document or gate.
    @Test func nothingElseReadsACortaSwitch() throws {
        let root = Self.repositoryRoot
        var offenders: [String] = []
        for directory in ["Corta", "CortaTerminal/Sources"] {
            let base = root.appendingPathComponent(directory)
            let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
            while let file = files?.nextObject() as? URL {
                guard file.pathExtension == "swift",
                    file.lastPathComponent != "DiagnosticsEnvironment.swift"
                else { continue }
                let text = try String(contentsOf: file, encoding: .utf8)
                if text.contains("environment[\"CORTA_") { offenders.append(file.lastPathComponent) }
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }
}
