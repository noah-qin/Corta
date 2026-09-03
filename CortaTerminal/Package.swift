// swift-tools-version: 6.2

import PackageDescription

// The terminal core is deliberately NOT `@MainActor`. The Xcode project
// sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which is right for
// the AppKit shell and wrong for the parser, grid and PTY reader — they
// run off the main thread (`docs/DESIGN.md` §2.2). Disabling default
// isolation here is the entire reason this package exists.
let package = Package(
    name: "CortaTerminal",
    platforms: [.macOS("26.5")],
    products: [
        .library(name: "CortaTerminal", targets: ["CortaTerminal"]),
        .executable(name: "corta-dump", targets: ["corta-dump"]),
        .executable(name: "corta-bench", targets: ["corta-bench"]),
        .executable(name: "corta-exec", targets: ["corta-exec"]),
        .executable(name: "corta-fuzz", targets: ["corta-fuzz"]),
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
        // M1.21's baseline: parse throughput and scrollback memory,
        // measured, not estimated. Run with `-c release` for real numbers.
        .executableTarget(
            name: "corta-bench",
            dependencies: ["CortaTerminal"],
            swiftSettings: [.defaultIsolation(nil)]
        ),
        // M6.11 — the libFuzzer harness over the feed path. Built with
        // `-Xswiftc -sanitize=fuzzer` it is a fuzz target; built plainly it
        // replays files named on the command line, so a crashing input can
        // be reproduced and the checked-in corpus can run in CI without a
        // fuzzer-enabled toolchain.
        .executableTarget(
            name: "corta-fuzz",
            dependencies: ["CortaTerminal"],
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
