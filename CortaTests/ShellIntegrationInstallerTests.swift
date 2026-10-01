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
import Testing

@testable import Corta

/// Install, diagnose, remove. Every test points at a temporary rc
/// file, never the real `~/.zshrc` (`docs/DECISIONS.md` D13 — "Never change the machine
/// to test").
@MainActor
struct ShellIntegrationInstallerTests {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("corta-shell-integration-tests-\(UUID().uuidString)")
    private var file: URL { directory.appendingPathComponent(".zshrc") }
    private var installer: ShellIntegrationInstaller {
        ShellIntegrationInstaller(shell: .zsh, rcFileURL: file)
    }

    private func removeDirectory() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func writeFile(_ text: String) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    @Test("no rc file at all is reported as not installed")
    func absentFileIsNotInstalled() {
        defer { removeDirectory() }
        #expect(installer.status() == .notInstalled)
    }

    @Test("installing into an absent rc file creates it with the block")
    func installCreatesTheFile() throws {
        defer { removeDirectory() }
        #expect(installer.install())
        #expect(installer.status() == .installed)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("Corta shell integration"))
        #expect(text.contains(ShellIntegrationScript.zsh))
    }

    @Test("installing into a symlinked rc file keeps the link and edits its target")
    func installFollowsASymbolicLink() throws {
        defer { removeDirectory() }
        let repository = directory.appendingPathComponent("dotfiles")
        try FileManager.default.createDirectory(
            at: repository, withIntermediateDirectories: true)
        let target = repository.appendingPathComponent("zshrc")
        try "export PATH=/usr/local/bin:$PATH\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)

        #expect(installer.install())
        #expect(installer.status() == .installed)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
        let text = try String(contentsOf: target, encoding: .utf8)
        #expect(text.hasPrefix("export PATH=/usr/local/bin:$PATH\n"))
        #expect(text.contains(ShellIntegrationScript.zsh))

        #expect(installer.uninstall())
        #expect(installer.status() == .notInstalled)
        #expect(try String(contentsOf: target, encoding: .utf8) == "export PATH=/usr/local/bin:$PATH\n")
    }

    @Test("installing appends after existing content, on its own line")
    func installAppendsAfterExistingContent() throws {
        defer { removeDirectory() }
        try writeFile("export PATH=/usr/local/bin:$PATH")
        #expect(installer.install())
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.hasPrefix("export PATH=/usr/local/bin:$PATH\n"))
        #expect(installer.status() == .installed)
    }

    @Test("installing twice changes nothing the second time")
    func installIsIdempotent() throws {
        defer { removeDirectory() }
        #expect(installer.install())
        let first = try String(contentsOf: file, encoding: .utf8)
        #expect(installer.install())
        let second = try String(contentsOf: file, encoding: .utf8)
        #expect(first == second)
    }

    @Test("uninstall removes exactly the installed block")
    func uninstallRemovesOnlyItsOwnBlock() throws {
        defer { removeDirectory() }
        try writeFile("# my own zshrc\nexport EDITOR=vim\n")
        let before = try String(contentsOf: file, encoding: .utf8)
        #expect(installer.install())
        #expect(installer.status() == .installed)
        #expect(installer.uninstall())
        let after = try String(contentsOf: file, encoding: .utf8)
        #expect(after == before)
        #expect(installer.status() == .notInstalled)
    }

    /// A block another version wrote is never rewritten behind the user's
    /// back, so a fix to the hooks would never reach it; the status says so,
    /// and `update()` replaces the hooks where they sit.
    @Test("an earlier version's block is outdated, and update replaces it in place")
    func anEarlierBlockIsOutdatedAndUpdatesInPlace() throws {
        defer { removeDirectory() }
        let block = "# >>> Corta shell integration >>>\n# older hooks\n# <<< Corta shell integration <<<\n"
        try writeFile("export EDITOR=vim\n\n" + block + "alias ll='ls -l'\n")
        #expect(installer.status() == .outdated)

        #expect(installer.update())
        #expect(installer.status() == .installed)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("# older hooks"))
        #expect(text.hasPrefix("export EDITOR=vim\n\n# >>> Corta shell integration >>>\n"))
        #expect(text.hasSuffix("# <<< Corta shell integration <<<\nalias ll='ls -l'\n"))

        #expect(installer.uninstall())
        #expect(try String(contentsOf: file, encoding: .utf8) == "export EDITOR=vim\nalias ll='ls -l'\n")
    }

    /// Without its end marker there is no whole block to replace: an Update
    /// offered there would report success and change nothing.
    @Test("a block missing its end marker is not offered an update")
    func aBrokenBlockIsNotOutdated() throws {
        defer { removeDirectory() }
        try writeFile("# >>> Corta shell integration >>>\n# older hooks\n")
        #expect(installer.status() == .installed)
        #expect(!installer.update())
        #expect(try String(contentsOf: file, encoding: .utf8) == "# >>> Corta shell integration >>>\n# older hooks\n")
    }

    @Test("uninstalling when nothing is installed is a no-op that still succeeds")
    func uninstallOfNothingSucceeds() throws {
        defer { removeDirectory() }
        try writeFile("export EDITOR=vim\n")
        #expect(installer.uninstall())
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text == "export EDITOR=vim\n")
    }

    @Test("a known competing integration is named, not just flagged")
    func conflictingIntegrationIsNamed() throws {
        defer { removeDirectory() }
        try writeFile("source ~/.iterm2_shell_integration.zsh\n")
        #expect(installer.status() == .conflicting("iTerm2"))
    }

    @Test("installing over a conflicting integration still installs")
    func installOverAConflictStillInstalls() throws {
        defer { removeDirectory() }
        try writeFile("source ~/.iterm2_shell_integration.zsh\n")
        #expect(installer.install())
        #expect(installer.status() == .installed)
    }

    @Test("bash and fish install, diagnose and uninstall exactly like zsh", arguments: [
        ShellKind.bash, ShellKind.fish,
    ])
    func otherShellsRoundTrip(_ shell: ShellKind) throws {
        defer { removeDirectory() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rcFile = directory.appendingPathComponent(shell.rawValue + "rc")
        let otherInstaller = ShellIntegrationInstaller(shell: shell, rcFileURL: rcFile)
        #expect(otherInstaller.status() == .notInstalled)
        #expect(otherInstaller.install())
        #expect(otherInstaller.status() == .installed)
        let text = try String(contentsOf: rcFile, encoding: .utf8)
        #expect(text.contains(shell.script))
        #expect(otherInstaller.uninstall())
        #expect(otherInstaller.status() == .notInstalled)
    }

    @Test("each shell's script is distinct and non-empty")
    func scriptsAreDistinct() {
        let scripts = ShellKind.allCases.map(\.script)
        #expect(Set(scripts).count == ShellKind.allCases.count)
        #expect(scripts.allSatisfy { !$0.isEmpty })
    }

    // MARK: - bash's two files

    private func bashIntegration() throws -> (ShellIntegration, bashrc: URL, login: URL) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bashrc = directory.appendingPathComponent(".bashrc")
        let login = ShellKind.bashLoginFile(in: directory)
        return (
            ShellIntegration(installers: [
                ShellIntegrationInstaller(shell: .bash, rcFileURL: bashrc),
                ShellIntegrationInstaller(shell: .bash, rcFileURL: login),
            ]), bashrc, login
        )
    }

    @Test("a login bash's file is the first readable one bash would read")
    func bashLoginFileFollowsBash() {
        let home = URL(fileURLWithPath: "/home/test")
        func file(_ readable: Set<String>) -> String {
            ShellKind.bashLoginFile(in: home) { readable.contains($0) }.lastPathComponent
        }
        #expect(file([]) == ".bash_profile")
        #expect(file(["/home/test/.profile"]) == ".profile")
        #expect(file(["/home/test/.bash_login", "/home/test/.profile"]) == ".bash_login")
        #expect(file(["/home/test/.bash_profile", "/home/test/.profile"]) == ".bash_profile")
        #expect(file(["/home/test/.bashrc"]) == ".bash_profile")
    }

    @Test("bash installs into ~/.bashrc and the login file, and reports both")
    func bashInstallsIntoBothFiles() throws {
        defer { removeDirectory() }
        let (integration, bashrc, login) = try bashIntegration()
        #expect(integration.status() == .notInstalled)
        #expect(integration.install())
        #expect(integration.status() == .installed)
        #expect(try String(contentsOf: bashrc, encoding: .utf8).contains(ShellKind.bash.script))
        #expect(try String(contentsOf: login, encoding: .utf8).contains(ShellKind.bash.script))
    }

    @Test("a block in ~/.bashrc alone, from an earlier version, is outdated and Update adds the other")
    func bashrcOnlyInstallIsCompletedByUpdate() throws {
        defer { removeDirectory() }
        let (integration, bashrc, login) = try bashIntegration()
        #expect(integration.installers[0].install())
        #expect(!FileManager.default.fileExists(atPath: login.path))
        #expect(integration.status() == .outdated)
        #expect(integration.update())
        #expect(integration.status() == .installed)
        #expect(try String(contentsOf: bashrc, encoding: .utf8).components(separatedBy: "Corta shell integration >>>").count == 2)
    }

    @Test("removing deletes a file the block was alone in, and keeps one the user wrote in")
    func uninstallDeletesAFileLeftEmpty() throws {
        defer { removeDirectory() }
        let (integration, bashrc, login) = try bashIntegration()
        try "alias ll='ls -l'\n".write(to: bashrc, atomically: true, encoding: .utf8)
        #expect(integration.install())
        #expect(integration.uninstall())
        #expect(integration.status() == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: login.path), "an empty login file would hide ~/.profile")
        #expect(try String(contentsOf: bashrc, encoding: .utf8) == "alias ll='ls -l'\n")
    }

    @Test("the bash block runs only in an interactive bash, and parses in a POSIX shell")
    func bashBlockIsSafeInTheLoginFile() throws {
        let script = ShellKind.bash.script
        let firstLine = try #require(script.split(separator: "\n").first)
        #expect(firstLine.hasPrefix("if [ -n \"$BASH_VERSION\" ]"))
        #expect(firstLine.contains("*i*"))
        guard FileManager.default.isExecutableFile(atPath: "/bin/dash") else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/dash")
        process.arguments = ["-c", script + "\necho ok"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0)
        #expect(output == "ok\n", "dash printed: \(output)")
    }
}
