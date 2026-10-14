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

/// The hosts offered under a connect field: the ones connected to recently,
/// and the concrete `Host` names in the user's OpenSSH configuration. Both
/// are suggestions — picking one fills the field — and both pass the same
/// character check a typed host does (`SSHDestination`), so neither file can
/// put anything into the argv a person could not have typed.
nonisolated enum RemoteHostName {
    /// What the connect form accepts as a bare destination: a host,
    /// `user@host`, an IPv6 literal — never a port or a key, which a
    /// reported name or a config alias has no business carrying.
    static func isAcceptable(_ name: String) -> Bool {
        SSHTarget.named(name) != nil
    }
}

// MARK: - ~/.ssh/config

/// Reads the `Host` names from `~/.ssh/config` and the files it `Include`s.
///
/// Read-only and never executed: no `Match exec`, no `ProxyCommand`, no
/// tokens are expanded — only the names after `Host` are looked at, and a
/// pattern (`*`, `?`, `!`) is not a host anyone can connect to by name, so
/// it is left out. Bounded the way untrusted input is: a file larger than
/// `maximumFileSize` is skipped, `Include` nests at most `maximumDepth`
/// deep, and at most `maximumFiles` files and `maximumAliases` names are
/// read in all.
nonisolated enum SSHConfigHosts {
    static let maximumFileSize = 256 * 1024
    static let maximumDepth = 4
    static let maximumFiles = 32
    static let maximumAliases = 200

    /// The aliases in the user's configuration, in file order, without
    /// duplicates. An unreadable or absent file is simply no aliases.
    ///
    /// The real home, not `AppPaths.userHomeDirectory`: a development build's
    /// stage relocates Corta's own files, but the `ssh` it spawns still reads
    /// `~/.ssh/config`, and the list must name what that `ssh` will resolve.
    static func aliases(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String] {
        let sshDirectory = home.appendingPathComponent(".ssh", isDirectory: true)
        var reader = Reader(home: home, sshDirectory: sshDirectory)
        reader.read(sshDirectory.appendingPathComponent("config"), depth: 0)
        return reader.aliases
    }

    /// One file's `Host` names and `Include` arguments, in order.
    static func parse(_ text: String) -> (hosts: [String], includes: [String]) {
        var hosts: [String] = []
        var includes: [String] = []
        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            var line = Substring(rawLine)
            if let hash = line.firstIndex(of: "#") { line = line[..<hash] }
            let tokens = tokenize(line)
            guard let keyword = tokens.first else { continue }
            let arguments = tokens.dropFirst()
            switch keyword.lowercased() {
            case "host":
                for name in arguments where !name.contains(where: { "*?!".contains($0) }) {
                    hosts.append(name)
                }
            case "include":
                includes.append(contentsOf: arguments)
            default:
                continue
            }
        }
        return (hosts, includes)
    }

    /// `ssh_config`'s word splitting, as far as `Host` and `Include` need
    /// it: whitespace or one `=` between keyword and arguments, and double
    /// quotes around an argument that holds spaces.
    private static func tokenize(_ line: Substring) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        var sawKeyword = false
        for character in line {
            if character == "\"" {
                quoted.toggle()
                continue
            }
            let separates =
                !quoted && (character.isWhitespace || (character == "=" && !sawKeyword))
            if separates {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                    sawKeyword = true
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private struct Reader {
        let home: URL
        let sshDirectory: URL
        var aliases: [String] = []
        private var seen: Set<String> = []
        private var visitedFiles: Set<String> = []

        init(home: URL, sshDirectory: URL) {
            self.home = home
            self.sshDirectory = sshDirectory
        }

        mutating func read(_ file: URL, depth: Int) {
            // Followed, because dotfile managers (stow, home-manager, chezmoi)
            // make `~/.ssh/config` a link; the checks below apply to the
            // file it points at.
            let path = file.resolvingSymlinksInPath().standardizedFileURL.path
            guard depth <= SSHConfigHosts.maximumDepth,
                visitedFiles.count < SSHConfigHosts.maximumFiles,
                visitedFiles.insert(path).inserted,
                let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                attributes[.type] as? FileAttributeType == .typeRegular,
                let size = attributes[.size] as? Int, size <= SSHConfigHosts.maximumFileSize,
                let data = FileManager.default.contents(atPath: path),
                let text = String(data: data, encoding: .utf8)
            else { return }
            let parsed = SSHConfigHosts.parse(text)
            for host in parsed.hosts
            where aliases.count < SSHConfigHosts.maximumAliases
                && RemoteHostName.isAcceptable(host) && seen.insert(host).inserted
            {
                aliases.append(host)
            }
            for pattern in parsed.includes {
                for match in expand(pattern) { read(match, depth: depth + 1) }
            }
        }

        /// `Include`'s path rules: `~/` is the home directory, a relative
        /// path is relative to `~/.ssh`, and wildcards are globbed.
        private func expand(_ pattern: String) -> [URL] {
            let absolute: String
            if pattern.hasPrefix("~/") {
                absolute = home.appendingPathComponent(String(pattern.dropFirst(2))).path
            } else if pattern.hasPrefix("/") {
                absolute = pattern
            } else {
                absolute = sshDirectory.appendingPathComponent(pattern).path
            }
            var result = glob_t()
            defer { globfree(&result) }
            guard glob(absolute, 0, nil, &result) == 0 else { return [] }
            return (0..<Int(result.gl_pathc)).compactMap { index in
                result.gl_pathv[index].map { URL(fileURLWithPath: String(cString: $0)) }
            }
        }
    }
}

// MARK: - Recent hosts

/// Connections made recently, newest first — app state in Application
/// Support, like the directory history, not a setting. Only a destination
/// the user typed or picked and then connected to is recorded, with the
/// user, port and key it was made with; a host a remote shell merely
/// reported is not. Cleared from Settings ▸ Privacy & Security.
@MainActor
final class RecentHostsStore {
    static let shared = RecentHostsStore(fileURL: RecentHostsStore.defaultFileURL)

    static let limit = 8

    static var defaultFileURL: URL {
        AppPaths.applicationSupportDirectory.appendingPathComponent("recent-hosts.json")
    }

    /// Injected so tests use a temporary file.
    let fileURL: URL
    private(set) var targets: [SSHTarget] = []

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    /// Moves `target` to the front, trimmed to `limit`. One entry per
    /// destination (`displayName`): connecting again with another key
    /// replaces the key remembered.
    func record(_ target: SSHTarget) {
        guard let target = Self.checked(target) else { return }
        targets.removeAll { $0.displayName == target.displayName }
        targets.insert(target, at: 0)
        if targets.count > Self.limit { targets.removeLast(targets.count - Self.limit) }
        save()
    }

    func remove(_ target: SSHTarget) {
        targets.removeAll { $0.displayName == target.displayName }
        save()
    }

    /// Forgets every host and deletes the file.
    func clear() {
        targets.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// The rules a typed connection passes, re-applied to a stored one: an
    /// edited or damaged file offers nothing a person could not have typed.
    /// A key that has since moved is kept — connecting says it is missing.
    private static func checked(_ target: SSHTarget) -> SSHTarget? {
        try? SSHTarget.parse(
            host: target.host, user: target.user ?? "",
            port: target.port.map(String.init) ?? "",
            identityFile: target.identityFile ?? "", checkingFiles: false
        ).get()
    }

    /// `hosts` is what every build reads: `host` or `user@host`. `targets`,
    /// added beside it, carries the fields; an older build ignores it and
    /// still finds the hosts a port does not change the meaning of.
    private nonisolated struct Persisted: Codable {
        static let currentVersion = 1
        var version: Int
        var hosts: [String]
        var targets: [SSHTarget]?
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
            let persisted = try? JSONDecoder().decode(Persisted.self, from: data),
            persisted.version <= Persisted.currentVersion
        else { return }
        let stored = persisted.targets ?? persisted.hosts.compactMap(SSHTarget.named)
        var seen = Set<String>()
        targets = Array(
            stored.compactMap(Self.checked).filter { seen.insert($0.displayName).inserted }
                .prefix(Self.limit))
    }

    /// A handful of entries, written at most once per connection: small
    /// enough to write in place. Owner-only, since host names and key paths
    /// say where you work.
    private func save() {
        // A host with a port is left out of `hosts`: an older build would
        // read `host:port` as a host name.
        let hosts = targets.filter { $0.port == nil }
            .map { SSHTarget(host: $0.host, user: $0.user).displayName }
        guard
            let data = try? JSONEncoder().encode(
                Persisted(version: Persisted.currentVersion, hosts: hosts, targets: targets))
        else { return }
        try? PrivateFile.write(data, to: fileURL)
    }
}
