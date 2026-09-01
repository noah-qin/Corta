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
        .library(name: "CortaTerminal", targets: ["CortaTerminal"])
    ],
    targets: [
        .target(
            name: "CortaTerminal",
            swiftSettings: [.defaultIsolation(nil)]
        ),
        .testTarget(
            name: "CortaTerminalTests",
            dependencies: ["CortaTerminal"],
            swiftSettings: [.defaultIsolation(nil)]
        ),
    ]
)
