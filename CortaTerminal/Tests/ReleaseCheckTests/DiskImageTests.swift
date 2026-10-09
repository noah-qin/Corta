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

import Foundation
import ReleaseCheck
import Testing

@Suite("Disk image release rules")
struct DiskImageTests {
    @Test func exactLayoutAndReadOnlyMount() {
        #expect(ReleaseCheck.diskImageLayoutProblems(entries: ["Corta.app", "Applications"],
            appIsDirectory: true, applicationsTarget: "/Applications", readOnly: true).isEmpty)
        for entries in [["Corta.app"], ["Corta.app", "Applications", ".DS_Store"], ["Other.app", "Applications"]] {
            #expect(!ReleaseCheck.diskImageLayoutProblems(entries: entries, appIsDirectory: true,
                applicationsTarget: "/Applications", readOnly: true).isEmpty)
        }
        #expect(!ReleaseCheck.diskImageLayoutProblems(entries: ["Corta.app", "Applications"],
            appIsDirectory: false, applicationsTarget: "/Applications", readOnly: true).isEmpty)
        #expect(!ReleaseCheck.diskImageLayoutProblems(entries: ["Corta.app", "Applications"],
            appIsDirectory: true, applicationsTarget: "/tmp/Applications", readOnly: true).isEmpty)
        #expect(!ReleaseCheck.diskImageLayoutProblems(entries: ["Corta.app", "Applications"],
            appIsDirectory: true, applicationsTarget: "/Applications", readOnly: false).isEmpty)
    }

    @Test func licenseMetadataAndDownloadURL() throws {
        for flag in [true, false] {
            let data = try PropertyListSerialization.data(fromPropertyList:
                ["Properties": ["Software License Agreement": flag]], format: .xml, options: 0)
            #expect(ReleaseCheck.diskImageHasLicense(in: data) == flag)
        }
        #expect(ReleaseCheck.diskImageHasLicense(in: Data()) == nil)
        #expect(ReleaseCheck.archiveName(version: "1.1.9") == "Corta-1.1.9.dmg")
        #expect(ReleaseCheck.isDiskImageDownloadURL(
            "https://github.com/noah-qin/Corta/releases/download/v1.1.9/Corta-1.1.9.dmg", version: "1.1.9"))
        #expect(!ReleaseCheck.isDiskImageDownloadURL(
            "https://github.com/noah-qin/Corta/releases/download/v1.1.9/Corta-1.1.9.zip", version: "1.1.9"))
        #expect(ReleaseCheck.diskImageTeamMatches("TEAM", appTeams: ["TEAM"]))
        #expect(!ReleaseCheck.diskImageTeamMatches("TEAM", appTeams: ["OTHER"]))
    }

    @Test func rejectedTrustOrLicenseNeverMounts() throws {
        for bad in ["signature", "authority", "stapler", "gatekeeper", "license"] {
            var calls: [[String]] = []
            let metadata = try PropertyListSerialization.data(fromPropertyList:
                ["Properties": ["Software License Agreement": bad == "license"]], format: .xml, options: 0)
            let runner: ReleaseCheck.ImageToolRunner = { command, arguments in
                calls.append([command] + arguments)
                if arguments == ["-dvv", "/tmp/image.dmg"] {
                    return .init(status: 0, stderr: Data((bad == "authority" ? "" :
                        "Authority=Developer ID Application: Test\nTeamIdentifier=TEAM\n").utf8))
                }
                if arguments.first == "imageinfo" { return .init(status: 0, stdout: metadata) }
                let fails = (bad == "signature" && arguments.first == "--verify") ||
                    (bad == "stapler" && arguments.first == "stapler") ||
                    (bad == "gatekeeper" && arguments.first == "-a")
                return .init(status: fails ? 1 : 0)
            }
            #expect(throws: ReleaseCheck.ImageFailure.self) {
                try ReleaseCheck.inspectDiskImage(URL(fileURLWithPath: "/tmp/image.dmg"), runner: runner)
            }
            #expect(!calls.contains { $0.contains("attach") })
        }
    }

    @Test func failedAttachAndLayoutAlwaysDetach() throws {
        for attachStatus: Int32 in [0, 1] {
            var calls: [[String]] = []
            let metadata = try PropertyListSerialization.data(fromPropertyList:
                ["Properties": ["Software License Agreement": false]], format: .xml, options: 0)
            let runner: ReleaseCheck.ImageToolRunner = { command, arguments in
                calls.append([command] + arguments)
                switch arguments.first {
                case "-dvv": return .init(status: 0, stderr: Data("Authority=Developer ID Application: Test\nTeamIdentifier=TEAM\n".utf8))
                case "imageinfo": return .init(status: 0, stdout: metadata)
                case "attach": return .init(status: attachStatus)
                default: return .init(status: 0)
                }
            }
            #expect(throws: ReleaseCheck.ImageFailure.self) {
                try ReleaseCheck.inspectDiskImage(URL(fileURLWithPath: "/tmp/image.dmg"), runner: runner)
            }
            let attach = try #require(calls.first { $0.contains("attach") })
            #expect(attach.contains("-readonly") && attach.contains("-nobrowse") && attach.contains("-noautoopen"))
            #expect(calls.contains { $0.contains("detach") })
            let mount = try #require(attach.last)
            #expect(!FileManager.default.fileExists(atPath: mount))
        }
    }
}
