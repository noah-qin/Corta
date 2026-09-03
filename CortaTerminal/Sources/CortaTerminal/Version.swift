/// The version string the terminal reports about itself.
///
/// **This is the only place a version number is written by hand outside the
/// Xcode project**, and the two have to agree: the app bundle's version comes
/// from `MARKETING_VERSION` in `project.pbxproj`, while XTVERSION
/// (`Performer+Query.swift`) answers with the constant below. A release that
/// bumps one and forgets the other leaves a terminal telling programs it is a
/// version it is not.
///
/// It is not read from `Bundle.main` on purpose. The core is a plain SwiftPM
/// package with no bundle of its own, it is linked into test drivers and
/// command-line tools (`corta-dump`, `corta-bench`) that have no app bundle at
/// all, and the XTVERSION answer must be a compile-time constant so it can
/// never carry bytes that came from the stream (`SECURITY.md` §2.1).
///
/// Releasing: bump `MARKETING_VERSION` (all six build configurations), this
/// constant, and the `CHANGELOG.md` heading together.
public enum CortaVersion {
    /// Semantic version, matching `MARKETING_VERSION` and the changelog.
    public static let string = "0.1.0"

    /// The XTVERSION payload: the convention every consumer parses is
    /// `Name(version)`, the way xterm answers `XTerm(<patch>)`.
    public static let report = "Corta(\(string))"
}
