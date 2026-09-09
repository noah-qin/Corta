import Foundation
import Testing

@testable import Corta
@testable import CortaTerminal

/// Q02 — the two places a version number is written by hand have to agree.
///
/// `CortaVersion.string` is what XTVERSION answers a program with;
/// `MARKETING_VERSION` is what the bundle, the update feed and the About panel
/// show a person. `CortaVersion`'s own doc comment says a release that bumps
/// one and forgets the other leaves the terminal telling programs it is a
/// version it is not — and that is precisely what had happened: the constant
/// still said 0.1.0 after the release it names had shipped.
@MainActor
struct VersionAgreementTests {

    @Test("the version a program is told matches the version the bundle claims")
    func reportedVersionMatchesTheBundle() throws {
        let bundleVersion = try #require(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            "the test host has no CFBundleShortVersionString")
        #expect(bundleVersion == CortaVersion.string)
    }

    /// Sparkle compares `CFBundleVersion` — the build number — not the
    /// marketing version. Shipping two releases with the same build number
    /// means the second is invisible to everyone running the first, and
    /// `generate_appcast` overwrites the earlier feed entry instead of
    /// adding one. That happened on the first attempt at 0.1.1: both it and
    /// 0.1.0 carried build 1.
    ///
    /// The check is deliberately weak — it cannot know what the *previous*
    /// release shipped — but it pins the two facts that matter: the build
    /// number is a number, and it is not the value 0.1.0 went out with.
    @Test("the build number is one Sparkle can compare against 0.1.0's")
    func buildNumberMovedPast0_1_0() throws {
        let build = try #require(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        let number = try #require(Int(build), "CFBundleVersion must be an integer: \(build)")
        // 0.1.0 shipped build 1. Anything at or below it is invisible to a
        // user running 0.1.0.
        #expect(number > 1, "build \(number) cannot be offered to a 0.1.0 install")
    }

    @Test("the XTVERSION payload is the shape every consumer parses")
    func reportIsNameAndVersion() {
        #expect(CortaVersion.report == "Corta(\(CortaVersion.string))")
    }
}
