import CortaTerminal
import SwiftUI

/// The About window's content, in SwiftUI.
///
/// Everything shown here is read from the bundle rather than typed in a
/// second time — a version number written twice is a version number that
/// goes stale: `CFBundleShortVersionString` comes from `MARKETING_VERSION`,
/// and the terminal's own XTVERSION answer comes from `CortaVersion`, shown
/// alongside it precisely so a mismatch between the two is visible instead
/// of silent.
struct AboutView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
                .padding(.bottom, 6)

            Text(Self.bundleString("CFBundleName") ?? "Corta")
                .font(.system(size: 22, weight: .semibold))

            Text(L10n.text("about.tagline"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)

            // Selectable, so the one line a bug report needs can be copied
            // out of here rather than transcribed from a screenshot.
            Text(Self.versionLine)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .help(L10n.text("about.version.tooltip"))
                .padding(.bottom, 6)

            HStack(spacing: 4) {
                Link(L10n.text("about.website"), destination: Self.url("https://github.com/noah-qin/Corta"))
                Link(
                    L10n.text("about.releaseNotes"),
                    destination: Self.url("https://github.com/noah-qin/Corta/releases"))
                Link(
                    L10n.text("about.license"),
                    destination: Self.url("https://github.com/noah-qin/Corta/blob/main/LICENSE"))
            }
            .font(.system(size: 11))
            .padding(.bottom, 8)

            Text(Self.copyrightLine)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(EdgeInsets(top: 28, leading: 24, bottom: 20, trailing: 24))
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// `Version 0.1.0 (1)`, plus the terminal's self-reported version when
    /// it disagrees with the bundle's — see the type's own doc comment.
    private static var versionLine: String {
        let short = bundleString("CFBundleShortVersionString") ?? "—"
        let build = bundleString("CFBundleVersion") ?? "—"
        var line = L10n.format("about.version", short, build)
        if short != CortaVersion.string {
            line += " · " + L10n.format("about.reportsVersion", CortaVersion.string)
        }
        return line
    }

    /// The bundle's copyright when it carries one, and a sensible line when
    /// it does not — an About window with a blank where the copyright goes
    /// is what this replaced.
    private static var copyrightLine: String {
        if let copyright = bundleString("NSHumanReadableCopyright"), !copyright.isEmpty {
            return copyright
        }
        return "Apache License 2.0"
    }

    private static func bundleString(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    /// A hardcoded, well-formed URL literal failing to parse would be a
    /// programmer error, not a runtime condition — `!` says so rather than
    /// threading an `Optional` through three call sites for a string this
    /// file itself wrote.
    private static func url(_ string: String) -> URL { URL(string: string)! }
}
