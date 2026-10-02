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
import Testing

@testable import Corta

/// D22 — which build gets a stage directory, and what that keeps away from
/// the user's own files. The choice is a function of the launch environment
/// and the bundle identifier, so every case here is exercised without a
/// second bundle and without touching anything on the machine
/// (`docs/DECISIONS.md` D13).
@MainActor
struct AppPathsTests {
    private let installed = "dev.noahqin.Corta"
    private let development = "dev.noahqin.Corta.dev"

    @Test func installedBuildHasNoStage() {
        #expect(AppPaths.stageDirectory(environment: [:], bundleIdentifier: installed) == nil)
    }

    @Test func developmentBuildStagesByItsIdentityAlone() throws {
        let stage = try #require(
            AppPaths.stageDirectory(environment: [:], bundleIdentifier: development))
        #expect(stage.lastPathComponent == AppPaths.developmentStageName)
        #expect(!stage.path.hasSuffix("/Application Support/Corta/Corta Dev"))
    }

    /// The installed build's own state directory is never a parent of the
    /// development build's stage: they are siblings, so deleting one cannot
    /// take the other with it.
    @Test func theTwoStateDirectoriesAreSiblings() throws {
        let stage = try #require(
            AppPaths.stageDirectory(environment: [:], bundleIdentifier: development))
        let installedState = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Corta", isDirectory: true)
        let installedPath = try #require(installedState).path
        #expect(!stage.path.hasPrefix(installedPath + "/"))
        #expect(stage.deletingLastPathComponent().path
            == URL(fileURLWithPath: installedPath).deletingLastPathComponent().path)
    }

    @Test func anAbsoluteStageOverrideWinsForEitherBuild() throws {
        let environment = ["CORTA_STAGE_DIR": "/tmp/corta-stage-fixture"]
        for identifier in [installed, development] {
            let stage = try #require(
                AppPaths.stageDirectory(environment: environment, bundleIdentifier: identifier))
            #expect(stage.path == "/tmp/corta-stage-fixture")
        }
    }

    /// A relative value is ignored rather than resolved against the working
    /// directory, which is whatever launched the app.
    @Test func aRelativeStageOverrideIsIgnored() {
        let environment = ["CORTA_STAGE_DIR": "corta-stage-fixture"]
        #expect(
            AppPaths.stageDirectory(environment: environment, bundleIdentifier: installed) == nil)
        let staged = AppPaths.stageDirectory(
            environment: environment, bundleIdentifier: development)
        #expect(staged?.lastPathComponent == AppPaths.developmentStageName)
    }

    @Test func aBundleWithoutAnIdentifierIsTreatedAsInstalled() {
        #expect(AppPaths.stageDirectory(environment: [:], bundleIdentifier: nil) == nil)
    }

    /// A unit-test host gets a stage of its own, per process — not the
    /// development build's, which is the one a developer runs day to day.
    @Test func aTestHostGetsAThrowawayStage() throws {
        let environment = ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]
        for identifier in [installed, development] {
            let stage = try #require(
                AppPaths.stageDirectory(
                    environment: environment, bundleIdentifier: identifier,
                    temporaryDirectory: "/tmp/fixture-tmp", processID: 4242))
            #expect(stage.path == "/tmp/fixture-tmp/Corta-Tests-4242")
        }
        // An explicit stage still wins: CI and staged checks name their own.
        var explicit = environment
        explicit["CORTA_STAGE_DIR"] = "/tmp/corta-stage-fixture"
        #expect(
            AppPaths.stageDirectory(environment: explicit, bundleIdentifier: development)?.path
                == "/tmp/corta-stage-fixture")
    }

    /// The test host must not resolve to the developer's own files — neither
    /// the installed build's nor the development build's. The `#require` and
    /// the prefix checks are the assertion: a host that resolved to either
    /// would read that config and write into its `~/.zshrc`.
    @Test func theTestHostNeverResolvesToTheDevelopersOwnFiles() throws {
        let stage = try #require(
            AppPaths.stageDirectory,
            "the test host must run with a stage of its own")
        #expect(stage.lastPathComponent != AppPaths.developmentStageName
            || ProcessInfo.processInfo.environment["CORTA_STAGE_DIR"] != nil)
        let cache = try #require(AppPaths.cacheDirectory)
        #expect(cache.path.hasPrefix(stage.path + "/"))
        #expect(AppPaths.configFileURL.path.hasPrefix(stage.path + "/"))
        #expect(AppPaths.applicationSupportDirectory.path.hasPrefix(stage.path + "/"))
        for shell in ShellKind.allCases {
            #expect(shell.defaultRCFileURL.path.hasPrefix(stage.path + "/"))
            for url in shell.rcFileURLs {
                #expect(url.path.hasPrefix(stage.path + "/"))
            }
        }
    }

    @Test func onlyTheInstalledBuildCarriesAnUpdater() {
        #expect(UpdateController.isAvailable == !AppPaths.isDevelopmentBuild)
    }
}
