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

@Suite("Release rules")
struct ReleaseCheckTests {
    @Test("a build setting's values are collected across configurations, quoted or not")
    func projectSettings() {
        let pbxproj = """
                    MARKETING_VERSION = 1.1.0;
                    CURRENT_PROJECT_VERSION = 12;
                    MARKETING_VERSION = "1.1.0";
                    MACOSX_DEPLOYMENT_TARGET = 26.0;
                    MARKETING_VERSION_SUFFIX = beta;
            """
        #expect(ReleaseCheck.projectSetting("MARKETING_VERSION", in: pbxproj) == ["1.1.0"])
        #expect(ReleaseCheck.projectSetting("CURRENT_PROJECT_VERSION", in: pbxproj) == ["12"])
        #expect(ReleaseCheck.projectSetting("MISSING", in: pbxproj).isEmpty)
        let split = pbxproj + "\n\t\tCURRENT_PROJECT_VERSION = 13;"
        #expect(ReleaseCheck.projectSetting("CURRENT_PROJECT_VERSION", in: split) == ["12", "13"])
    }

    @Test("only a plain integer is a build number Sparkle can compare")
    func integerBuilds() {
        #expect(ReleaseCheck.isIntegerBuild("12"))
        #expect(!ReleaseCheck.isIntegerBuild(""))
        #expect(!ReleaseCheck.isIntegerBuild("1.1"))
        #expect(!ReleaseCheck.isIntegerBuild("١٢"))  // Arabic-Indic digits are numbers, not ASCII
    }

    @Test("the changelog heading is matched for the exact version")
    func changelogSections() {
        let changelog = "# Changelog\n\n## [Unreleased]\n\n## [1.0.1] - 2026-09-19\n"
        #expect(ReleaseCheck.changelogHasSection(changelog, version: "1.0.1"))
        #expect(!ReleaseCheck.changelogHasSection(changelog, version: "1.1.0"))
    }

    @Test("a sidecar names the archive by file name, and its digest reads back")
    func sidecars() {
        let text = ReleaseCheck.sidecar(digest: "abc123", archiveName: "Corta-1.1.0.zip")
        #expect(text == "abc123  Corta-1.1.0.zip\n")
        #expect(ReleaseCheck.recordedDigest(inSidecar: text) == "abc123")
        #expect(ReleaseCheck.recordedDigest(inSidecar: "") == nil)
    }

    @Test("the feed item for a version yields its build, length and hardware requirements")
    func appcastItems() throws {
        let feed = Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
              <channel>
                <item>
                  <sparkle:version>12</sparkle:version>
                  <sparkle:shortVersionString>1.1.0</sparkle:shortVersionString>
                  <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
                  <enclosure url="https://example.invalid/Corta-1.1.0.zip" length="4096"/>
                </item>
                <item>
                  <sparkle:version>11</sparkle:version>
                  <sparkle:shortVersionString>1.0.1</sparkle:shortVersionString>
                  <enclosure url="https://example.invalid/Corta-1.0.1.zip" length="2048"/>
                </item>
              </channel>
            </rss>
            """.utf8)
        #expect(try ReleaseCheck.appcastItem(version: "1.1.0", in: feed)
                == .init(build: "12", length: "4096", hardwareRequirements: "arm64"))
        #expect(try ReleaseCheck.appcastItem(version: "1.0.1", in: feed)
                == .init(build: "11", length: "2048", hardwareRequirements: ""))
        #expect(try ReleaseCheck.appcastItem(version: "2.0.0", in: feed) == nil)
        #expect(throws: (any Error).self) { try ReleaseCheck.appcastItem(version: "1.1.0", in: Data("<rss".utf8)) }
    }

    @Test("arm64 is found in a hardware-requirements list, and only as a whole entry")
    func hardwareRequirements() {
        #expect(ReleaseCheck.requiresArm64("arm64"))
        #expect(ReleaseCheck.requiresArm64("x86_64, arm64"))
        #expect(!ReleaseCheck.requiresArm64(""))
        #expect(!ReleaseCheck.requiresArm64("arm64e"))
    }

    @Test("a denied entitlement is found unless it is false, and nothing is no entitlements")
    func deniedEntitlements() {
        let plist = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>com.apple.security.get-task-allow</key><true/>
            <key>com.apple.security.cs.allow-jit</key><false/>
            <key>com.apple.security.network.client</key><true/>
            </dict></plist>
            """.utf8)
        #expect(ReleaseCheck.forbiddenEntitlements(inPlist: plist) == ["com.apple.security.get-task-allow"])
        #expect(ReleaseCheck.forbiddenEntitlements(inPlist: Data()) == [])
        #expect(ReleaseCheck.forbiddenEntitlements(inPlist: Data(" \n".utf8)) == [])
        #expect(ReleaseCheck.forbiddenEntitlements(inPlist: Data("<plist".utf8)) == nil)
    }

    @Test("the hardened runtime is read off the CodeDirectory flags, alone or among others")
    func hardenedRuntime() {
        let release = """
            Executable=/Applications/Corta.app/Contents/MacOS/Corta
            CodeDirectory v=20500 size=1234 flags=0x10000(runtime) hashes=27+7 location=embedded
            TeamIdentifier=646VSJ9K5F
            """
        #expect(ReleaseCheck.hasHardenedRuntime(codesignDescription: release))
        #expect(ReleaseCheck.hasHardenedRuntime(
            codesignDescription: "CodeDirectory v=20500 size=1 flags=0x10002(adhoc,runtime) hashes=1+0"))
        #expect(!ReleaseCheck.hasHardenedRuntime(
            codesignDescription: "CodeDirectory v=20400 size=1 flags=0x2(adhoc) hashes=1+0"))
        #expect(!ReleaseCheck.hasHardenedRuntime(codesignDescription: "flags=0x10000(runtime)"))
        #expect(ReleaseCheck.teamIdentifier(codesignDescription: release) == "646VSJ9K5F")
        #expect(ReleaseCheck.teamIdentifier(codesignDescription: "TeamIdentifier=not set") == nil)
        #expect(ReleaseCheck.teamIdentifier(codesignDescription: "") == nil)
    }

    @Test("load paths outside the bundle and the system are reported")
    func loadPaths() {
        let otool = """
            Load command 12
                      cmd LC_RPATH
                  cmdsize 48
                     path @executable_path/../Frameworks (offset 12)
            Load command 13
                      cmd LC_RPATH
                  cmdsize 32
                     path /usr/lib/swift (offset 12)
            Load command 14
                      cmd LC_RPATH
                  cmdsize 48
                     path /Users/me/lib (offset 12)
            Load command 15
                      cmd LC_LOAD_DYLIB
                  cmdsize 88
                     name @rpath/Sparkle.framework/Versions/B/Sparkle (offset 24)
            Load command 16
                      cmd LC_LOAD_WEAK_DYLIB
                  cmdsize 56
                     name /opt/homebrew/lib/libx.dylib (offset 24)
            Load command 17
                      cmd LC_LOAD_DYLIB
                  cmdsize 56
                     name /System/Library/Frameworks/AppKit.framework/Versions/C/AppKit (offset 24)
            """
        let paths = ReleaseCheck.loadPaths(otoolLoadCommands: otool)
        #expect(paths.count == 6)
        #expect(paths.first == ReleaseCheck.LoadPath(command: "LC_RPATH", path: "@executable_path/../Frameworks"))
        #expect(ReleaseCheck.unsafeLoadPaths(paths) == [
            .init(command: "LC_RPATH", path: "/Users/me/lib"),
            .init(command: "LC_LOAD_WEAK_DYLIB", path: "/opt/homebrew/lib/libx.dylib"),
        ])
    }
}
