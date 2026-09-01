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
        return result
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
