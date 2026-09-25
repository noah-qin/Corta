import Foundation

/// Where Corta reads its config, keeps its own state, and looks for the
/// shell rc file it installs into — and how a build that is not the one the
/// user installed is kept away from all three.
///
/// **Two identities.** A Debug build is a separate application: its bundle
/// identifier ends in `.dev` (`CORTA_BUNDLE_SUFFIX`, D22). That suffix is
/// what selects a stage directory here, so a development build is isolated
/// however it was launched — from Xcode, from a test host, or by a
/// double-click — rather than only when a launch script remembered to set
/// an environment variable.
///
/// **The stage directory** holds everything Corta owns: the config file at
/// `<dir>/config`, its own state (session restore, directory history,
/// remote-edit copies) under `<dir>/ApplicationSupport`, and the rc file
/// the shell-integration installer writes at `<dir>/<rc path>`. One
/// directory, so "did this build touch anything of the user's?" is a
/// question about one path.
///
/// `CORTA_STAGE_DIR` names an absolute directory and overrides the choice,
/// for a staged check of a Release build (`docs/CONFORMANCE.md` §4.4). It
/// exists because `$HOME` cannot do this on macOS: `NSHomeDirectory()`,
/// `homeDirectoryForCurrentUser` and the Application Support lookup all
/// answer from the account record, not the environment, so a launch with
/// `HOME` overridden still reads the developer's own config and writes into
/// their real Application Support — the opposite of what a staged check
/// needs. Same class as `CORTA_RESTORE_WINDOWS`: read from the launch
/// environment, never a config key, and ignored unless absolute.
nonisolated enum AppPaths {
    /// The suffix `CORTA_BUNDLE_SUFFIX` gives the Debug configuration.
    static let developmentBundleSuffix = ".dev"

    /// The development build's stage, beside — never inside — the state
    /// directory the installed build owns.
    static let developmentStageName = "Corta Dev"

    /// True when this bundle is the development build. Read once: a bundle
    /// identifier does not change while the process runs.
    static let isDevelopmentBuild = Bundle.main.bundleIdentifier?
        .hasSuffix(developmentBundleSuffix) ?? false

    static let stageDirectory: URL? = stageDirectory(
        environment: ProcessInfo.processInfo.environment,
        bundleIdentifier: Bundle.main.bundleIdentifier)

    /// The choice as a function of its two inputs, so a test can make it
    /// without a second bundle (D13 — never change the machine to test).
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

    /// `~/Library/Application Support/Corta`, or the stage's
    /// `ApplicationSupport`.
    static var applicationSupportDirectory: URL {
        if let stageDirectory {
            return stageDirectory.appendingPathComponent("ApplicationSupport", isDirectory: true)
        }
        return systemApplicationSupportDirectory.appendingPathComponent("Corta", isDirectory: true)
    }

    /// `~/Library/Caches/<bundle identifier>`, or the stage's `Caches` —
    /// disposable, regenerable content the system is free to purge.
    ///
    /// Keyed by the bundle identifier rather than by a fixed name because
    /// `QuadRenderer` prunes every compiled-shader archive in this
    /// directory that is not its own. With one shared directory the two
    /// builds delete each other's archive on every launch, and each one
    /// then recompiles its pipelines from source — a development build
    /// reaching into the session the developer is working in, which is
    /// exactly what D22 exists to stop.
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

    /// What a `~`-relative path the *user* owns resolves against —
    /// `~/.zshrc` and the rest of `ShellKind.defaultRCFileURL`.
    ///
    /// Staged, this is the stage directory: a development build that
    /// installs shell integration writes a file inside its own stage, and
    /// the rc file every real shell on the machine reads is untouched. That
    /// file is then not sourced by anything, which is the point — the
    /// installer's own diagnosis reports it accurately either way.
    static var userHomeDirectory: URL {
        stageDirectory ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private static var systemApplicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    }
}
