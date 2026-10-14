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
import Synchronization

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
        let identity = rawIdentity.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Options for ssh, ahead of its `--`. A chosen key is the only one
    /// offered (`IdentitiesOnly`): an agent holding several would otherwise
    /// try each first, and a server counting `MaxAuthTries` refuses the
    /// connection before reaching the one the user picked.
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
    /// brackets then, so the port reads as one. What titles, recents and the
    /// SFTP window registry show and key on; the key is left out, since it
    /// says how to sign in, not where to.
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

    // MARK: - Rules

    /// Letters, digits, `.`, `_`, `-`, and `:`/`[]` for IPv6 literals; never
    /// a leading `-`, the shape of an option — `--` already stops ssh
    /// reading one, and this keeps the name from looking like one anywhere.
    /// A single `:` is `host:port`, which ssh would read as a host name: the
    /// port has its own field, and a `displayName` with one is not a host.
    static func isAcceptableHost(_ host: String) -> Bool {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:[]")
        guard !host.isEmpty, host.count <= 255, !host.hasPrefix("-"),
            host.unicodeScalars.allSatisfy(allowed.contains)
        else { return false }
        let bracketed = host.hasPrefix("[") && host.hasSuffix("]")
        let inner = bracketed ? host.dropFirst().dropLast() : Substring(host)
        guard !inner.contains("["), !inner.contains("]") else { return false }
        return inner.count(where: { $0 == ":" }) != 1 && (!bracketed || inner.contains(":"))
    }

    /// The portable POSIX user-name set. Nothing ssh would expand — its
    /// `%` tokens and `${}` variables — and no leading `-`.
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

    // MARK: - This run's targets

    /// Targets the user connected to this run, by `displayName`. The SFTP
    /// browser, remote editing and the window registry name a connection by
    /// that string; this is how one made with a port or a key is spawned
    /// with them again. A name never entered here is a plain destination.
    private static let entered = Mutex<[String: SSHTarget]>([:])

    static func remember(_ target: SSHTarget) {
        entered.withLock { $0[target.displayName] = target }
    }

    static func resolve(_ name: String) -> SSHTarget? {
        entered.withLock { $0[name] } ?? named(name)
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
