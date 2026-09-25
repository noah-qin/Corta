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

    /// Whichever configuration this runs under, the test host must not
    /// resolve to the developer's own files: under Debug because the host
    /// *is* the development build, under Release because the test plan
    /// stages it. The `#require` is the assertion — a host with neither is
    /// a host that would write into `~/.zshrc`.
    @Test func theTestHostNeverResolvesToTheDevelopersOwnFiles() throws {
        let stage = try #require(
            AppPaths.stageDirectory,
            "the test host must be the development build, or run with CORTA_STAGE_DIR set")
        #expect(AppPaths.configFileURL.path.hasPrefix(stage.path + "/"))
        #expect(AppPaths.applicationSupportDirectory.path.hasPrefix(stage.path + "/"))
        for shell in ShellKind.allCases {
            #expect(shell.defaultRCFileURL.path.hasPrefix(stage.path + "/"))
        }
    }

    @Test func onlyTheInstalledBuildCarriesAnUpdater() {
        #expect(UpdateController.isAvailable == !AppPaths.isDevelopmentBuild)
    }
}
