import Foundation
import Testing

@testable import Corta

/// B07 — install, diagnose, remove. Every test points at a temporary rc
/// file, never the real `~/.zshrc` (`CLAUDE.md` — "Never change the machine
/// to test").
@MainActor
struct ShellIntegrationInstallerTests {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("corta-shell-integration-tests-\(UUID().uuidString)")
    private var file: URL { directory.appendingPathComponent(".zshrc") }
    private var installer: ShellIntegrationInstaller { ShellIntegrationInstaller(rcFileURL: file) }

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
}
