// Copyright 2026 Noah Qin
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Darwin

/// A child's environment (`SECURITY.md` §4.3): nothing describing *our*
/// terminal or Corta's internals; everything else passes, since a shell
/// without `PATH` or `SSH_AUTH_SOCK` is not usable.
public enum ChildEnvironment {
    /// `$TERM` is a deliberate lie until conformance is proven (D08 in
    /// `DECISIONS.md`).
    public static let term = "xterm-256color"

    /// `TERM*` is replaced, never inherited; `COLUMNS`/`LINES` would freeze a
    /// stale size (`TIOCSWINSZ` is the authority); `CORTA_` is internal.
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

    /// Pure, so the policy is testable.
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
        // 24-bit colour, or Claude Code quantises its orange to a pink cube entry.
        result["COLORTERM"] = "truecolor"
        // Without a locale zsh edits byte by byte and CJK arrives as stray
        // continuation bytes. Only filled in when the user set none.
        if result["LANG"] == nil, result["LC_ALL"] == nil, result["LC_CTYPE"] == nil {
            result["LANG"] = utf8Locale
        }
        return result
    }

    /// Falls back to `en_US.UTF-8`, present on every install.
    static var utf8Locale: String {
        let identifier = Locale.current.identifier
            .split(separator: "@").first.map(String.init) ?? ""
        let normalised = identifier.replacingOccurrences(of: "-", with: "_")
        // A bare language is not a locale name; language_REGION is.
        guard normalised.contains("_") else { return "en_US.UTF-8" }
        return "\(normalised).UTF-8"
    }

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

    public static func `default`() -> [String: String] {
        sanitized(inheriting: processEnvironment())
    }
}
