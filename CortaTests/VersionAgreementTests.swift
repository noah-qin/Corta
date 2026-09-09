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

    @Test("the XTVERSION payload is the shape every consumer parses")
    func reportIsNameAndVersion() {
        #expect(CortaVersion.report == "Corta(\(CortaVersion.string))")
    }
}
