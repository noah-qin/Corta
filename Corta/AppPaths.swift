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

/// Where Corta reads config, keeps state and finds the rc file it installs
/// into, and how a non-installed build stays away from all three.
///
/// A Debug build's bundle id ends in `.dev` (D22), which selects a stage
/// directory however it was launched. The stage holds `<dir>/config`,
/// `<dir>/ApplicationSupport` and `<dir>/<rc path>`, so "did this build
/// touch the user's files?" is a question about one path.
///
/// `CORTA_STAGE_DIR` (absolute, from the launch environment only)
/// overrides it for a staged Release check (`CONFORMANCE.md` §4.4).
/// `$HOME` can't: the home and Application Support lookups answer from the
/// account record, not the environment.
nonisolated enum AppPaths {
    static let developmentBundleSuffix = ".dev"

    /// Beside, never inside, the installed build's state directory.
    static let developmentStageName = "Corta Dev"

    static let isDevelopmentBuild = Bundle.main.bundleIdentifier?
        .hasSuffix(developmentBundleSuffix) ?? false

    static let stageDirectory: URL? = stageDirectory(
        environment: ProcessInfo.processInfo.environment,
        bundleIdentifier: Bundle.main.bundleIdentifier)

    /// Pure, so tests need no second bundle (D13).
    static func stageDirectory(environment: [String: String], bundleIdentifier: String?) -> URL? {
        if let raw = environment["CORTA_STAGE_DIR"], raw.hasPrefix("/") {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        guard bundleIdentifier?.hasSuffix(developmentBundleSuffix) == true else { return nil }
        return systemApplicationSupportDirectory
            .appendingPathComponent(developmentStageName, isDirectory: true)
    }

    /// `~/.config/corta/config`, or the stage's `config`.
    static var configFileURL: URL {
        if let stageDirectory { return stageDirectory.appendingPathComponent("config") }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/corta/config")
    }

    /// `~/Library/Application Support/Corta`, or the stage's.
    static var applicationSupportDirectory: URL {
        if let stageDirectory {
            return stageDirectory.appendingPathComponent("ApplicationSupport", isDirectory: true)
        }
        return systemApplicationSupportDirectory.appendingPathComponent("Corta", isDirectory: true)
    }

    /// `~/Library/Caches/<bundle id>`, or the stage's: purgeable. Per bundle
    /// id because `QuadRenderer` prunes archives not its own, and a shared
    /// directory had the two builds deleting each other's (D22).
    static var cacheDirectory: URL? {
        if let stageDirectory {
            return stageDirectory.appendingPathComponent("Caches", isDirectory: true)
        }
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first
        else { return nil }
        return caches.appendingPathComponent(
            Bundle.main.bundleIdentifier ?? "dev.noahqin.Corta", isDirectory: true)
    }

    /// Where user-owned `~` paths like `~/.zshrc` resolve. Staged, the stage
    /// directory, so real shells' rc files are untouched.
    static var userHomeDirectory: URL {
        stageDirectory ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private static var systemApplicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    }
}
