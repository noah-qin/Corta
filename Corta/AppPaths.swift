import Foundation

/// Where Corta reads its config and keeps its own state — and the one
/// switch that moves both somewhere else for a launched-app check.
///
/// `CORTA_STAGE_DIR` names an absolute directory; when set, the config file
/// is `<dir>/config` and everything Corta writes for itself (session
/// restore, directory history, remote-edit copies) lives under
/// `<dir>/ApplicationSupport`. It exists because `$HOME` cannot do this on
/// macOS: `NSHomeDirectory()`, `homeDirectoryForCurrentUser` and the
/// Application Support lookup all answer from the account record, not the
/// environment, so a launch with `HOME` overridden still reads the
/// developer's own config and writes into their real Application Support
/// — the opposite of what a staged check (`CONFORMANCE.md` §4.4) needs.
/// Same class as `CORTA_RESTORE_WINDOWS`: read from the launch
/// environment, never a config key, and ignored unless absolute.
nonisolated enum AppPaths {
    static let stageDirectory: URL? = {
        guard let raw = ProcessInfo.processInfo.environment["CORTA_STAGE_DIR"],
            raw.hasPrefix("/")
        else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }()

    /// `~/.config/corta/config`, or the stage's `config`.
    static var configFileURL: URL {
        if let stageDirectory { return stageDirectory.appendingPathComponent("config") }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/corta/config")
    }

    /// `~/Library/Application Support/Corta`, or the stage's
    /// `ApplicationSupport`.
    static var applicationSupportDirectory: URL {
        if let stageDirectory {
            return stageDirectory.appendingPathComponent("ApplicationSupport", isDirectory: true)
        }
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Corta", isDirectory: true)
    }
}
