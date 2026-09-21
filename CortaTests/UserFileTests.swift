import Foundation
import Testing

@testable import Corta

/// A user's file is written where the user keeps it: through a symbolic
/// link, with its permission bits intact. Every test works in its own
/// temporary directory (`docs/DECISIONS.md` D13).
struct UserFileTests {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("corta-user-file-tests-\(UUID().uuidString)")

    private func makeDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func removeDirectory() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    private func permissions(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
    }

    @Test("a plain file is written in place")
    func plainFileIsWritten() throws {
        try makeDirectory()
        defer { removeDirectory() }
        let file = directory.appendingPathComponent("config")
        try UserFile.write("a = 1\n", to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "a = 1\n")
        #expect(!isSymbolicLink(file))
    }

    @Test("the parent directory is created when it does not exist")
    func parentDirectoryIsCreated() throws {
        try makeDirectory()
        defer { removeDirectory() }
        let file = directory.appendingPathComponent("fish/config.fish")
        try UserFile.write("set -x A 1\n", to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "set -x A 1\n")
    }

    @Test("writing through a symbolic link keeps the link and updates its target")
    func symbolicLinkIsFollowed() throws {
        try makeDirectory()
        defer { removeDirectory() }
        let repository = directory.appendingPathComponent("dotfiles")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let target = repository.appendingPathComponent("zshrc")
        try "export A=1\n".write(to: target, atomically: true, encoding: .utf8)
        let link = directory.appendingPathComponent(".zshrc")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        try UserFile.write("export A=2\n", to: link)

        #expect(isSymbolicLink(link), "the link must survive the write")
        #expect(try String(contentsOf: target, encoding: .utf8) == "export A=2\n")
        #expect(try String(contentsOf: link, encoding: .utf8) == "export A=2\n")
    }

    @Test("a relative link destination resolves against the link's directory")
    func relativeLinkIsFollowed() throws {
        try makeDirectory()
        defer { removeDirectory() }
        let repository = directory.appendingPathComponent("dotfiles")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let target = repository.appendingPathComponent("zshrc")
        try "old\n".write(to: target, atomically: true, encoding: .utf8)
        let link = directory.appendingPathComponent(".zshrc")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "dotfiles/zshrc")

        try UserFile.write("new\n", to: link)

        #expect(isSymbolicLink(link))
        #expect(try String(contentsOf: target, encoding: .utf8) == "new\n")
    }

    @Test("a dangling link is followed: the file appears at its destination")
    func danglingLinkIsFollowed() throws {
        try makeDirectory()
        defer { removeDirectory() }
        let target = directory.appendingPathComponent("dotfiles/zshrc")
        let link = directory.appendingPathComponent(".zshrc")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        try UserFile.write("created\n", to: link)

        #expect(isSymbolicLink(link), "the link must not be replaced by a file")
        #expect(try String(contentsOf: target, encoding: .utf8) == "created\n")
    }

    @Test("the file's permission bits survive the atomic rewrite")
    func permissionsArePreserved() throws {
        try makeDirectory()
        defer { removeDirectory() }
        let file = directory.appendingPathComponent(".zshrc")
        try "secret\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(permissions(of: file) == 0o600)

        try UserFile.write("still secret\n", to: file)

        #expect(permissions(of: file) == 0o600)
        #expect(try String(contentsOf: file, encoding: .utf8) == "still secret\n")
    }
}
