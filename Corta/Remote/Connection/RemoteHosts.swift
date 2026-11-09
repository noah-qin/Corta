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
        read(home: home).aliases
    }

    /// The aliases a connect dialog offers, and the git hosts it leaves out:
    /// a `Host` whose `User` is `git`, or whose name or `HostName` is a git
    /// hosting service, takes git commands only — never a shell or files.
    /// Runs file reads outside the UI actor while retaining task cancellation.
    @concurrent static func loadSuggestions() async -> (hosts: [String], hiddenGitHosts: [String]) {
        guard !Task.isCancelled else { return ([], []) }
        return suggestions()
    }

    static func suggestions(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> (hosts: [String], hiddenGitHosts: [String]) {
        let reader = read(home: home)
        let hidden = reader.aliases.filter { reader.gitHosts.contains($0) || isGitHost($0) }
        return (reader.aliases.filter { !hidden.contains($0) }, hidden)
    }

    private static func read(home: URL) -> Reader {
        let sshDirectory = home.appendingPathComponent(".ssh", isDirectory: true)
        var reader = Reader(home: home, sshDirectory: sshDirectory)
        reader.read(sshDirectory.appendingPathComponent("config"), depth: 0)
        return reader
    }

    /// Services whose ssh is for git alone, and their subdomains
    /// (`ssh.github.com`, `altssh.gitlab.com`).
    static let gitHostingDomains = [
        "github.com", "gitlab.com", "bitbucket.org", "ssh.dev.azure.com",
        "vs-ssh.visualstudio.com", "codeberg.org", "gitee.com", "git.sr.ht",
    ]

    /// `host` or `user@host` names a git hosting service.
    static func isGitHost(_ name: String) -> Bool {
        let host = (name.split(separator: "@").last.map(String.init) ?? name).lowercased()
        return gitHostingDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// One file's `Host` names and `Include` arguments, in order, and the
    /// names whose block makes them git hosts (`User git`, a git
    /// `HostName`).
    struct Parsed {
        var hosts: [String]
        var includes: [String]
        var gitHosts: Set<String>
    }

    static func parse(_ text: String) -> Parsed {
        var hosts: [String] = []
        var includes: [String] = []
        var gitHosts: Set<String> = []
        // The names the current `Host` line declared; a `Match` ends them.
        var block: [String] = []
        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            var line = Substring(rawLine)
            if let hash = line.firstIndex(of: "#") { line = line[..<hash] }
            let tokens = tokenize(line)
            guard let keyword = tokens.first else { continue }
            let arguments = tokens.dropFirst()
            switch keyword.lowercased() {
            case "host":
                block = arguments.filter { !$0.contains(where: { "*?!".contains($0) }) }
                hosts.append(contentsOf: block)
            case "match":
                block = []
            case "user":
                if arguments.first == "git" { gitHosts.formUnion(block) }
            case "hostname":
                if let name = arguments.first, isGitHost(name) { gitHosts.formUnion(block) }
            case "include":
                includes.append(contentsOf: arguments)
            default:
                continue
            }
        }
        return Parsed(hosts: hosts, includes: includes, gitHosts: gitHosts)
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
        var gitHosts: Set<String> = []
        private var seen: Set<String> = []
        private var visitedFiles: Set<String> = []

        init(home: URL, sshDirectory: URL) {
            self.home = home
            self.sshDirectory = sshDirectory
        }

        mutating func read(_ file: URL, depth: Int) {
            guard !Task.isCancelled else { return }
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
            gitHosts.formUnion(parsed.gitHosts)
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
    static let shared: RecentHostsStore = {
        // Read in the background: the first connect dialog or window no
        // longer waits on the file.
        let store = RecentHostsStore(fileURL: defaultFileURL, loadsInBackground: true)
        activeShared = store
        return store
    }()
    private static weak var activeShared: RecentHostsStore?

    static func flushSharedAtQuit(into group: DispatchGroup, deadline: DispatchTime) {
        activeShared?.flush(into: group, deadline: deadline)
    }

    nonisolated static let limit = 8

    static var defaultFileURL: URL {
        AppPaths.applicationSupportDirectory.appendingPathComponent("recent-hosts.json")
    }

    /// Injected so tests use a temporary file.
    let fileURL: URL
    var targets: [SSHTarget] { history.targets }
    private(set) var preservesNewerFile = false
    private(set) var persistenceError: (any Error)?
    private var preservesUnreadableFile = false
    private let writeQueue: DispatchQueue
    private var persistenceGeneration = 0
    private var history = History()
    /// Keep changes made after a clear started separately until deletion succeeds.
    private var clearing: Clearing?

    private struct Clearing {
        let deletion: HistoryFileDeletion
        var history = History()
        var changed = false
    }

    var isClearing: Bool { clearing != nil }

    private struct History {
        var targets: [SSHTarget] = []
        /// By displayName; absent in a file an older build wrote.
        var lastUsed: [String: Date] = [:]

        mutating func record(_ target: SSHTarget, at date: Date) {
            targets.removeAll { $0.displayName == target.displayName }
            targets.insert(target, at: 0)
            if targets.count > RecentHostsStore.limit { targets.removeLast(targets.count - RecentHostsStore.limit) }
            lastUsed[target.displayName] = date
            lastUsed = lastUsed.filter { name, _ in targets.contains { $0.displayName == name } }
        }

        mutating func remove(_ target: SSHTarget) {
            targets.removeAll { $0.displayName == target.displayName }
            lastUsed[target.displayName] = nil
        }
    }

    private enum Change {
        case record(SSHTarget, Date)
        case remove(SSHTarget)
    }

    /// The background read, until applied (`loadsInBackground`).
    private var pendingLoad: PendingLoad<LoadOutcome>?
    /// Changes made before the file was read, replayed onto it.
    private var changesBeforeLoad: [Change] = []
    var isLoaded: Bool { pendingLoad == nil }

    /// `loadsInBackground`: read on `writeQueue` and applied on the main
    /// actor; changes made before then are kept and replayed, and nothing is
    /// written over a file not yet read. Unset, read here, as tests rely on.
    init(
        fileURL: URL, writeQueue: DispatchQueue = DispatchQueue(label: "Corta.RecentHostsStore", qos: .utility),
        loadsInBackground: Bool = false
    ) {
        self.fileURL = fileURL
        self.writeQueue = writeQueue
        guard loadsInBackground else {
            apply(Self.read(fileURL))
            return
        }
        let pending = PendingLoad<LoadOutcome>()
        pendingLoad = pending
        writeQueue.async { [weak self] in
            pending.deliver(Self.read(fileURL))
            Task { @MainActor [weak self] in self?.applyPendingLoad() }
        }
    }

    private func applyPendingLoad() {
        guard let pending = pendingLoad, let outcome = pending.take() else { return }
        pendingLoad = nil
        apply(outcome)
        let changes = changesBeforeLoad
        changesBeforeLoad.removeAll()
        for change in changes {
            switch change {
            case .record(let target, let date): history.record(target, at: date)
            case .remove(let target): history.remove(target)
            }
        }
        if !changes.isEmpty { save() }
    }

    /// Moves `target` to the front, trimmed to `limit`. One entry per
    /// destination (`displayName`): connecting again with another key
    /// replaces the key remembered.
    func record(_ target: SSHTarget, at date: Date = Date()) {
        guard let target = Self.checked(target) else { return }
        history.record(target, at: date)
        guard isLoaded else {
            changesBeforeLoad.append(.record(target, date))
            return
        }
        clearing?.history.record(target, at: date)
        noteChange()
    }

    func remove(_ target: SSHTarget) {
        history.remove(target)
        guard isLoaded else {
            changesBeforeLoad.append(.remove(target))
            return
        }
        clearing?.history.remove(target)
        noteChange()
    }

    func lastUsed(_ target: SSHTarget) -> Date? {
        history.lastUsed[target.displayName]
    }

    /// Deletes the file after earlier writes, keeping connections made while it was being deleted.
    func clear() async {
        if !isLoaded {
            await withCheckedContinuation { continuation in writeQueue.async { continuation.resume() } }
            applyPendingLoad()
        }
        guard !preservesNewerFile, !preservesUnreadableFile, !isClearing else { return }
        let deletion = HistoryFileDeletion(fileURL, on: writeQueue)
        clearing = Clearing(deletion: deletion)
        persistenceGeneration += 1
        await deletion.wait()
        finishClear(deletion)
    }

    private func finishClear(_ deletion: HistoryFileDeletion) {
        guard let clearing, clearing.deletion === deletion, let result = deletion.result else { return }
        self.clearing = nil
        switch result {
        case .success:
            history = clearing.history
            persistenceError = nil
            if !history.targets.isEmpty { save() }
        case .failure(let error):
            persistenceError = error
            if clearing.changed { save(reportSuccess: false) }
        }
    }

    private func noteChange() {
        if isClearing {
            clearing?.changed = true
        } else {
            save()
        }
    }

    /// Finishes queued work within the quit deadline.
    func flush() {
        let group = DispatchGroup()
        let deadline = DispatchTime.now() + .seconds(1)
        flush(into: group, deadline: deadline)
        _ = group.wait(timeout: deadline)
    }

    /// `flush` without its wait, for a quit that waits for every store at
    /// once.
    func flush(into group: DispatchGroup, deadline: DispatchTime) {
        if let pending = pendingLoad {
            pending.wait(until: deadline)
            applyPendingLoad()
        }
        if let deletion = clearing?.deletion {
            deletion.wait(until: deadline)
            finishClear(deletion)
        }
        group.enter()
        writeQueue.async { group.leave() }
    }

    /// Waits for writes already scheduled, without blocking the caller.
    func waitForWrites() async {
        await withCheckedContinuation { continuation in
            writeQueue.async { continuation.resume() }
        }
    }

    /// The rules a typed connection passes, re-applied to a stored one: an
    /// edited or damaged file offers nothing a person could not have typed.
    /// A key that has since moved is kept — connecting says it is missing.
    nonisolated private static func checked(_ target: SSHTarget) -> SSHTarget? {
        try? SSHTarget.parse(
            host: target.host, user: target.user ?? "",
            port: target.port.map(String.init) ?? "",
            identityFile: target.identityFile ?? "", checkingFiles: false
        ).get()
    }

    /// `hosts` is what every build reads: `host` or `user@host`. `targets`,
    /// added beside it, carries the fields; an older build ignores it and
    /// still finds the hosts a port does not change the meaning of.
    private nonisolated struct Persisted: Codable, Sendable {
        static let currentVersion = 1
        var version: Int
        var hosts: [String]
        var targets: [SSHTarget]?
        /// Added beside the others, as `targets` was; seconds since 1970.
        var used: [String: Double]?
    }

    /// What reading the file found; read anywhere, applied on the main actor.
    enum LoadOutcome: Sendable {
        case nothing
        case unreadable(any Error)
        case newer
        case targets([SSHTarget], lastUsed: [String: Date])
    }

    nonisolated static func read(_ fileURL: URL) -> LoadOutcome {
        struct VersionProbe: Decodable { let version: Int }
        let data: Data
        do {
            guard let loaded = try PrivateFile.readBounded(fileURL) else { return .nothing }
            data = loaded
        } catch {
            return .unreadable(error)
        }
        if let probe = try? JSONDecoder().decode(VersionProbe.self, from: data),
            probe.version > Persisted.currentVersion
        {
            return .newer
        }
        guard
            let persisted = try? JSONDecoder().decode(Persisted.self, from: data),
            persisted.version <= Persisted.currentVersion
        else { return .nothing }
        let stored = persisted.targets ?? persisted.hosts.compactMap(SSHTarget.named)
        var seen = Set<String>()
        let targets = Array(
            stored.compactMap(Self.checked).filter { seen.insert($0.displayName).inserted }
                .prefix(Self.limit))
        let lastUsed = (persisted.used ?? [:])
            .filter { name, _ in seen.contains(name) }
            .mapValues { Date(timeIntervalSince1970: $0) }
        return .targets(targets, lastUsed: lastUsed)
    }

    private func apply(_ outcome: LoadOutcome) {
        switch outcome {
        case .nothing:
            history = History()
        case .unreadable(let error):
            preservesUnreadableFile = true
            persistenceError = error
        case .newer:
            preservesNewerFile = true
        case .targets(let targets, let lastUsed):
            history.targets = targets
            history.lastUsed = lastUsed
        }
    }

    /// Snapshots on the main actor, encodes and writes on the serial queue.
    private func save(reportSuccess: Bool = true) {
        guard isLoaded, !preservesNewerFile, !preservesUnreadableFile else { return }
        // A host with a port is left out of `hosts`: an older build would
        // read `host:port` as a host name.
        let hosts = targets.filter { $0.port == nil }
            .map { SSHTarget(host: $0.host, user: $0.user).displayName }
        let persisted = Persisted(
            version: Persisted.currentVersion, hosts: hosts, targets: targets,
            used: history.lastUsed.mapValues(\.timeIntervalSince1970))
        let fileURL = fileURL
        persistenceGeneration += 1
        let generation = persistenceGeneration
        writeQueue.async { [weak self] in
            let result = Result { try PrivateFile.write(JSONEncoder().encode(persisted), to: fileURL) }
            Task { @MainActor [weak self] in
                guard let self, generation == self.persistenceGeneration else { return }
                switch result {
                case .success:
                    if reportSuccess { self.persistenceError = nil }
                case .failure(let error):
                    self.persistenceError = error
                }
            }
        }
    }
}
