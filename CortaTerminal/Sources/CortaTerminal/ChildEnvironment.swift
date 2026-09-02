import Foundation
import Darwin

/// Builds the environment handed to a child process.
///
/// `SECURITY.md` §4.3 requires the environment to be sanitised: the child
/// must not inherit variables that describe *our* terminal or leak Corta's
/// internals. Everything else is passed through — a shell that loses `PATH`,
/// `HOME` or `SSH_AUTH_SOCK` is not a usable shell.
public enum ChildEnvironment {
    /// `$TERM` is a deliberate lie until conformance is proven — `DESIGN.md` §2.5.
    public static let term = "xterm-256color"

    /// Names dropped before the child sees them.
    ///
    /// - Terminal descriptions (`TERM`, `TERMCAP`, `TERMINFO`…) are replaced
    ///   with our own, never inherited from whatever launched Corta.
    /// - `COLUMNS` and `LINES` would freeze the child at a stale size; the
    ///   authority on size is `TIOCSWINSZ`.
    /// - `CORTA_` is reserved for our own internals.
    static let strippedNames: Set<String> = [
        "COLUMNS",
        "COLORTERM",
        "LINES",
        "LC_TERMINAL",
        "LC_TERMINAL_VERSION",
        "TERM",
        "TERMCAP",
        "TERMINFO",
        "TERMINFO_DIRS",
        "TERM_PROGRAM",
        "TERM_PROGRAM_VERSION",
        "TERM_SESSION_ID",
    ]

    static let strippedPrefix = "CORTA_"

    /// The sanitised environment for a child, derived from `source`.
    ///
    /// Pure, so that the policy above is testable without touching the
    /// process environment.
    public static func sanitized(
        inheriting source: [String: String],
        term: String = ChildEnvironment.term
    ) -> [String: String] {
        var result: [String: String] = [:]
        result.reserveCapacity(source.count + 2)
        for (name, value) in source {
            guard !strippedNames.contains(name) else { continue }
            guard !name.hasPrefix(strippedPrefix) else { continue }
            result[name] = value
        }
        result["TERM"] = term
        result["TERM_PROGRAM"] = "Corta"
        // The parser supports 24-bit SGR colours. Advertising that capability
        // keeps applications such as Claude Code from quantising its orange
        // brand colour to xterm-256's pink 215/135/135 cube entry.
        result["COLORTERM"] = "truecolor"
        // A child with no locale runs in the C locale, where zsh's line
        // editor handles input one byte at a time: typing CJK or an emoji
        // produced isolated continuation bytes on screen instead of the
        // character. Terminal.app and iTerm2 both derive this from system
        // preferences, which is why they looked fine and this did not.
        //
        // Only filled in when the inherited environment says nothing — a
        // user who has set `LANG` or `LC_ALL` themselves keeps their choice.
        if result["LANG"] == nil, result["LC_ALL"] == nil, result["LC_CTYPE"] == nil {
            result["LANG"] = utf8Locale
        }
        return result
    }

    /// The user's language and region as a UTF-8 locale name, e.g.
    /// `zh_CN.UTF-8`. Falls back to `en_US.UTF-8`, which every macOS install
    /// has, rather than to nothing.
    static var utf8Locale: String {
        let identifier = Locale.current.identifier
            .split(separator: "@").first.map(String.init) ?? ""
        let normalised = identifier.replacingOccurrences(of: "-", with: "_")
        // A bare language ("en") is not a locale name; only a
        // language_REGION pair names a file in /usr/share/locale.
        guard normalised.contains("_") else { return "en_US.UTF-8" }
        return "\(normalised).UTF-8"
    }

    /// This process's environment, read from `environ`.
    public static func processEnvironment() -> [String: String] {
        var result: [String: String] = [:]
        var entry = environ
        while let variable = entry.pointee {
            let text = String(cString: variable)
            if let separator = text.firstIndex(of: "=") {
                result[String(text[text.startIndex..<separator])] =
                    String(text[text.index(after: separator)...])
            }
            entry += 1
        }
        return result
    }

    /// The default: this process's environment, sanitised.
    public static func `default`() -> [String: String] {
        sanitized(inheriting: processEnvironment())
    }
}
