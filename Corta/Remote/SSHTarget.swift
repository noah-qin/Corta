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

/// Where an SSH or SFTP connection goes, as the user entered it: a host or
/// `~/.ssh/config` alias, and optionally a user, a port and a private key.
///
/// Each part becomes its own argv element for system OpenSSH — never shell
/// text — and a part left out falls to `~/.ssh/config` and ssh's defaults,
/// so an alias keeps its own `User`, `Port` and `IdentityFile`.
nonisolated struct SSHTarget: Hashable, Codable, Sendable {
    var host: String
    var user: String?
    var port: Int?
    /// An absolute path to a private key, passed as `-i`.
    var identityFile: String?

    /// Unchecked: `parse` is the way in for anything typed or stored.
    init(host: String, user: String? = nil, port: Int? = nil, identityFile: String? = nil) {
        self.host = host
        self.user = user
        self.port = port
        self.identityFile = identityFile
    }

    enum Problem: Error, Equatable {
        case host, user, userTwice, port, identityFile, identityFileMissing
    }

    /// Validates what a form or a stored record holds. `host` may still
    /// carry `user@` — typed from habit, or a recent host saved before the
    /// user field existed; with the user field filled as well that is
    /// ambiguous, and refused rather than one silently winning.
    ///
    /// `checkingFiles` also requires the key to exist as a readable file:
    /// on for a connection, off for reading back a record whose key may
    /// have moved since (the connection then says so).
    static func parse(
        host rawHost: String, user rawUser: String = "", port rawPort: String = "",
        identityFile rawIdentity: String = "", checkingFiles: Bool = true
    ) -> Result<SSHTarget, Problem> {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        var user = rawUser.trimmingCharacters(in: .whitespacesAndNewlines)
        if let at = host.firstIndex(of: "@") {
            guard user.isEmpty else { return .failure(.userTwice) }
            user = String(host[..<at])
            host = String(host[host.index(after: at)...])
            guard !user.isEmpty else { return .failure(.user) }
        }
        // `[2001:db8::1]` is how an IPv6 literal is written beside a port;
        // ssh is given the address itself, and the port as `-p`.
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
            guard host.contains(":") else { return .failure(.host) }
        }
        guard isAcceptableHost(host) else { return .failure(.host) }
        guard user.isEmpty || isAcceptableUser(user) else { return .failure(.user) }
        let portText = rawPort.trimmingCharacters(in: .whitespaces)
        var port: Int?
        if !portText.isEmpty {
            guard let value = Int(portText), (1...65535).contains(value) else {
                return .failure(.port)
            }
            port = value
        }
        // Not trimmed: the path comes from an open panel, and a file whose
        // name ends in a space is still that file.
        let identity = rawIdentity
        if !identity.isEmpty {
            guard isAcceptableIdentityPath(identity) else { return .failure(.identityFile) }
            if checkingFiles, !isReadableFile(identity) { return .failure(.identityFileMissing) }
        }
        return .success(SSHTarget(
            host: host, user: user.isEmpty ? nil : user, port: port,
            identityFile: identity.isEmpty ? nil : identity))
    }

    /// A destination with no form behind it — a pane's report, a recent
    /// host from before the form had fields: `host` or `user@host`.
    static func named(_ name: String) -> SSHTarget? {
        try? parse(host: name, checkingFiles: false).get()
    }

    /// Options for ssh, ahead of its `--`. A chosen key is offered first —
    /// command-line identities come before any `IdentityFile` in
    /// `~/.ssh/config` — and `IdentitiesOnly` keeps an agent's other keys
    /// out: an agent holding several would otherwise try each first, and a
    /// server counting `MaxAuthTries` refuses the connection before
    /// reaching the one the user picked.
    var sshOptions: [String] {
        var options: [String] = []
        if let user { options += ["-l", user] }
        if let port { options += ["-p", String(port)] }
        if let identityFile { options += ["-i", identityFile, "-oIdentitiesOnly=yes"] }
        return options
    }

    /// `ssh <options> -- <host>`, for a terminal.
    var sshArguments: [String] { sshOptions + ["--", host] }

    /// `user@host`, with `:port` when one was given — an IPv6 literal in
    /// brackets then, so the port reads as one. What titles, recents and
    /// dialogs show; the key is left out, since it says how to sign in, not
    /// where to.
    var displayName: String {
        var name = user.map { "\($0)@" } ?? ""
        if let port {
            let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
            name += "\(bracketed):\(port)"
        } else {
            name += host
        }
        return name
    }

    /// The whole target as one string, read back by `init(key:)`: the SFTP
    /// window registry, remote editing's connections and its saved copies
    /// name a connection by this, so a relaunch, a reconnect or an upload
    /// reaches the same user, port and key. `displayName`, then ` -i ` and
    /// the key's path — a display name never holds a space, so the split is
    /// unambiguous. A plain host's key is its name, as saved copies from
    /// before the fields existed already are.
    var key: String {
        identityFile.map { "\(displayName) -i \($0)" } ?? displayName
    }

    /// How a `key` is shown: its display name, without the key's path.
    static func displayName(forKey key: String) -> String {
        SSHTarget(key: key)?.displayName ?? key
    }

    /// Reads back a `key`, under the rules a typed target passes.
    ///
    /// Only for names Corta made: a pane's report is read with `named(_:)`,
    /// which takes no port and no key — a remote shell cannot pick the file
    /// ssh signs in with.
    init?(key: String) {
        var name = Substring(key)
        var identity = ""
        if let marker = key.range(of: " -i ") {
            name = key[..<marker.lowerBound]
            identity = String(key[marker.upperBound...])
        }
        var user = ""
        var rest = name
        if let at = name.firstIndex(of: "@") {
            user = String(name[..<at])
            rest = name[name.index(after: at)...]
            guard !user.isEmpty else { return nil }
        }
        var host = String(rest)
        var port = ""
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let after = rest[rest.index(after: close)...]
            guard host.contains(":"), after.isEmpty || after.hasPrefix(":") else { return nil }
            port = String(after.dropFirst())
        } else if rest.count(where: { $0 == ":" }) == 1, let colon = rest.firstIndex(of: ":") {
            host = String(rest[..<colon])
            port = String(rest[rest.index(after: colon)...])
            guard !port.isEmpty else { return nil }
        }
        guard let target = try? Self.parse(
            host: host, user: user, port: port, identityFile: identity, checkingFiles: false
        ).get() else { return nil }
        self = target
    }

    // MARK: - Rules

    /// Letters, digits, `.`, `_`, `-`, and `:` for IPv6 literals; never a
    /// leading `-`, the shape of an option — `--` already stops ssh reading
    /// one, and this keeps the name from looking like one anywhere. A single
    /// `:` is `host:port`, which ssh would read as a host name: the port has
    /// its own field.
    static func isAcceptableHost(_ host: String) -> Bool {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:")
        return !host.isEmpty && host.count <= 255 && !host.hasPrefix("-")
            && host.unicodeScalars.allSatisfy(allowed.contains)
            && host.count(where: { $0 == ":" }) != 1
    }

    static func isAcceptableUser(_ user: String) -> Bool {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return !user.isEmpty && user.count <= 64 && !user.hasPrefix("-")
            && user.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// Absolute, and free of what ssh expands in an identity path — `%`
    /// tokens, `${}` variables — so the file read is the file chosen.
    static func isAcceptableIdentityPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 1024
            && !path.contains("%") && !path.contains("$")
            && !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func isReadableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue && FileManager.default.isReadableFile(atPath: path)
    }
}

/// What the connect form edits: the four fields, as typed.
nonisolated struct SSHTargetFields: Equatable, Sendable {
    var host = ""
    var user = ""
    var port = ""
    var identityFile = ""

    init(host: String = "", user: String = "", port: String = "", identityFile: String = "") {
        self.host = host
        self.user = user
        self.port = port
        self.identityFile = identityFile
    }

    init(_ target: SSHTarget) {
        host = target.host
        user = target.user ?? ""
        port = target.port.map(String.init) ?? ""
        identityFile = target.identityFile ?? ""
    }

    var target: Result<SSHTarget, SSHTarget.Problem> {
        SSHTarget.parse(host: host, user: user, port: port, identityFile: identityFile)
    }

    var isEmpty: Bool { host.trimmingCharacters(in: .whitespaces).isEmpty }
}
