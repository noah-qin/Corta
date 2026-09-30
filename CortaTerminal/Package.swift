// swift-tools-version: 6.2
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

import PackageDescription

// The terminal core is deliberately NOT `@MainActor`. The Xcode project
// sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which is right for
// the AppKit shell and wrong for the parser, grid and PTY reader — they
// run off the main thread (`DECISIONS.md` D04). Disabling default
// isolation here is the entire reason this package exists.
let package = Package(
    name: "CortaTerminal",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "CortaTerminal", targets: ["CortaTerminal"]),
        .executable(name: "corta-dump", targets: ["corta-dump"]),
        .executable(name: "corta-bench", targets: ["corta-bench"]),
        .executable(name: "corta-exec", targets: ["corta-exec"]),
        .executable(name: "corta-fuzz", targets: ["corta-fuzz"]),
        .executable(name: "corta-license", targets: ["corta-license"]),
        .executable(name: "corta-release-check", targets: ["corta-release-check"]),
    ],
    targets: [
        .target(
            name: "CortaTerminal",
            swiftSettings: [.defaultIsolation(nil)]
        ),
        // The spawn helper `Spawn.swift` posix_spawns and then execve's over
        // — see that file's doc comment for why this replaced `fork()`.
        // A separate target, not a source file inside `CortaTerminal`: it
        // must become its own Mach-O image so `posix_spawn` can launch it.
        .executableTarget(
            name: "corta-exec",
            swiftSettings: [.defaultIsolation(nil)]
        ),
        // Feeds stdin to a terminal and prints the grid, so the core can be
        // checked by hand against a real program's output without a window.
        .executableTarget(
            name: "corta-dump",
            dependencies: ["CortaTerminal"],
            swiftSettings: [.defaultIsolation(nil)]
        ),
        // Baseline measurements: parse throughput and scrollback memory,
        // measured, not estimated. Run with `-c release` for real numbers.
        .executableTarget(
            name: "corta-bench",
            dependencies: ["CortaTerminal"],
            swiftSettings: [.defaultIsolation(nil)]
        ),
        // Fuzz harness over the terminal feed path. Built with
        // `-Xswiftc -sanitize=fuzzer` it is a fuzz target; built plainly it
        // replays files named on the command line, so a crashing input can
        // be reproduced and the checked-in corpus can run in CI without a
        // fuzzer-enabled toolchain.
        .executableTarget(
            name: "corta-fuzz",
            dependencies: ["CortaTerminal"],
            swiftSettings: [.defaultIsolation(nil)]
        ),
        // The license-header rules (`docs/LICENSING.md`) and the tool that
        // checks and adds them. A library of its own so the rules are
        // testable without the file system; nothing in the terminal core
        // depends on it.
        .target(
            name: "LicenseHeaders",
            swiftSettings: [.defaultIsolation(nil)]
        ),
        .executableTarget(
            name: "corta-license",
            dependencies: ["LicenseHeaders"],
            swiftSettings: [.defaultIsolation(nil)]
        ),
        .testTarget(
            name: "LicenseHeadersTests",
            dependencies: ["LicenseHeaders"],
            swiftSettings: [.defaultIsolation(nil)]
        ),
        // The release rules (`docs/RELEASING.md`) and the one tool that
        // enforces them. The judgements over text are a library so they are
        // testable without a built app; the tool gathers the facts.
        .target(
            name: "ReleaseCheck",
            swiftSettings: [.defaultIsolation(nil)]
        ),
        .executableTarget(
            name: "corta-release-check",
            dependencies: ["ReleaseCheck"],
            swiftSettings: [.defaultIsolation(nil)]
        ),
        .testTarget(
            name: "ReleaseCheckTests",
            dependencies: ["ReleaseCheck"],
            swiftSettings: [.defaultIsolation(nil)]
        ),
        .testTarget(
            name: "CortaTerminalTests",
            dependencies: ["CortaTerminal"],
            // Golden-file inputs and expectations. Read from the source
            // directory through `#filePath`, so they are neither compiled
            // nor copied into a bundle.
            exclude: ["Golden"],
            swiftSettings: [.defaultIsolation(nil)]
        ),
    ]
)
