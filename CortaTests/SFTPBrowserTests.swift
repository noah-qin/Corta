import AppKit
import CortaTerminal
import Foundation
import Testing

@testable import Corta

/// B14 — the SFTP browser's app layer: gating, the command-table entry,
/// the model's navigation and error states, the transfer queue, and the
/// conflict-choice mapping. Every engine interaction goes through
/// `FakeSFTPClient` over the `SFTPClient` protocol seam — no ssh, no
/// network, and local filesystem staging confined to per-test temp
/// directories that are removed afterwards.

@MainActor
private func connectedModel(
    fake: FakeSFTPClient,
    host: String = "build-box",
    startDirectory: String? = "/srv/app"
) async -> SFTPBrowserModel {
    let model = SFTPBrowserModel(host: host, startDirectory: startDirectory) { host in
        fake.connectedHosts.append(host)
        return fake
    }
    model.connect()
    await waitUntil("connected") { model.connectionState == .connected }
    return model
}

// MARK: - Gating and command wiring

@MainActor
struct SFTPBrowserWiringTests {
    @Test("the menu item is offered exactly for remote panes")
    func gating() {
        #expect(
            ViewController.canBrowseRemoteFiles(
                state: .remote(host: "h", directory: "/d", provenance: .osc7)))
        #expect(ViewController.canBrowseRemoteFiles(state: .remoteUnknown(provenance: .foregroundProcess)))
        #expect(!ViewController.canBrowseRemoteFiles(state: .local))
        #expect(!ViewController.canBrowseRemoteFiles(state: .unknown))
    }

    @Test("the command table entry is complete and unbound by default")
    func commandTable() {
        let command = TerminalCommand.browseRemoteFiles
        #expect(command.rawValue == "browse-remote-files")
        #expect(!command.title.isEmpty)
        #expect(command.title == L10n.text("command.browseRemoteFiles"))
        #expect(command.category == .terminal)
        #expect(command.defaultShortcut == nil)
        #expect(command.action == #selector(ViewController.browseRemoteFiles(_:)))
    }

    @Test("the Shell menu carries the item, after the directory commands")
    func shellMenu() throws {
        let menu = try #require(NSApp.mainMenu)
        let shell = try #require(
            menu.items.first { $0.title == L10n.text("menu.shell") || $0.title == "Shell" }?.submenu)
        let actions = shell.items.compactMap(\.action)
        let browse = try #require(
            actions.firstIndex(of: #selector(ViewController.browseRemoteFiles(_:))))
        let directories = try #require(
            actions.firstIndex(of: #selector(ViewController.revealWorkingDirectoryInFinder(_:))))
        let state = try #require(
            actions.firstIndex(of: #selector(ViewController.clearScreen(_:))))
        // In the directory-navigation group: after those, before the state
        // commands, within the same separator-delimited run.
        #expect(browse > directories && browse < state)
    }
}

// MARK: - Pure helpers

struct SFTPBrowserFormattingTests {
    @Test("mode bits render as ls spells them")
    func permissionStrings() {
        #expect(SFTPBrowserModel.permissionString(0o100644) == "-rw-r--r--")
        #expect(SFTPBrowserModel.permissionString(0o040755) == "drwxr-xr-x")
        #expect(SFTPBrowserModel.permissionString(0o120777) == "lrwxrwxrwx")
        #expect(SFTPBrowserModel.permissionString(0o104755) == "-rwsr-xr-x")
        #expect(SFTPBrowserModel.permissionString(0o104644) == "-rwSr--r--")
        #expect(SFTPBrowserModel.permissionString(0o042775) == "drwxrwsr-x")
        #expect(SFTPBrowserModel.permissionString(0o042644) == "drw-r-Sr--")
        #expect(SFTPBrowserModel.permissionString(0o041777) == "drwxrwxrwt")
    }

    @Test("kinds come from the permission bits, unknown defaults to file")
    func kinds() {
        #expect(SFTPBrowserModel.kind(ofPermissions: nil) == .file)
        #expect(SFTPBrowserModel.kind(ofPermissions: 0o040755) == .directory)
        #expect(SFTPBrowserModel.kind(ofPermissions: 0o120777) == .symlink)
        #expect(SFTPBrowserModel.kind(ofPermissions: 0o100644) == .file)
        #expect(SFTPBrowserModel.kind(ofPermissions: 0o060600) == .other)
    }

    @Test("path helpers are absolute-path arithmetic only")
    func paths() {
        #expect(SFTPBrowserModel.joinPath("/", "a") == "/a")
        #expect(SFTPBrowserModel.joinPath("/srv", "a") == "/srv/a")
        #expect(SFTPBrowserModel.parentPath(of: "/srv/app") == "/srv")
        #expect(SFTPBrowserModel.parentPath(of: "/srv") == "/")
        #expect(SFTPBrowserModel.parentPath(of: "/") == "/")
        #expect(SFTPBrowserModel.normalized(path: "/srv/") == "/srv")
        #expect(SFTPBrowserModel.normalized(path: "/") == "/")
    }

    @Test("keep-both candidates count up from 2 and keep the extension")
    func keepBothNames() {
        #expect(
            SFTPBrowserModel.keepBothCandidate("/tmp/report.pdf", attempt: 1)
                == "/tmp/report 2.pdf")
        #expect(
            SFTPBrowserModel.keepBothCandidate("/tmp/report.pdf", attempt: 2)
                == "/tmp/report 3.pdf")
        #expect(SFTPBrowserModel.keepBothCandidate("/tmp/README", attempt: 1) == "/tmp/README 2")
    }

    @Test("every typed error category gets its own wording")
    func errorWording() {
        let host = "build-box"
        let cases: [(SFTPError, String)] = [
            (
                .server(SFTPStatus(code: .permissionDenied, message: Array("denied".utf8))),
                L10n.format("sftp.error.permissionDenied", host, "denied")
            ),
            (
                .server(SFTPStatus(code: .failure, message: Array("nope".utf8))),
                L10n.format("sftp.error.server", host, Int(SFTPStatus.Code.failure.rawValue), "nope")
            ),
            (
                .transport(.authenticationFailed(diagnostics: "Permission denied\n")),
                L10n.format("sftp.error.authentication", host, "Permission denied")
            ),
            (
                .transport(.hostUnreachable(diagnostics: "timed out")),
                L10n.format("sftp.error.unreachable", host, "timed out")
            ),
            (
                .transport(.subprocessFailed(exitCode: 255, diagnostics: "boom")),
                L10n.format("sftp.error.subprocess", host, 255, "boom")
            ),
            (.transport(.spawnFailed(code: 2)), L10n.format("sftp.error.spawn", 2)),
            (.transport(.executablePathNotAbsolute), L10n.text("sftp.error.spawnPath")),
            (.transport(.ioFailed(code: 5)), L10n.format("sftp.error.channel", host, 5)),
            (
                .transport(.connectionLost), L10n.format("sftp.error.connectionLost", host)
            ),
            (.protocolViolation("bad"), L10n.format("sftp.error.protocol", host, "bad")),
            (.cancelled, L10n.text("sftp.transfer.cancelled")),
            (.destinationConflict(path: "/x"), L10n.format("sftp.error.conflict", "/x")),
            (
                .localIOFailed(operation: "open", code: 13),
                L10n.format("sftp.error.localIO", "open", 13)
            ),
        ]
        for (error, expected) in cases {
            #expect(SFTPBrowserModel.errorMessage(error, host: host) == expected, "\(error)")
        }
        // The categories read differently, not one generic "error".
        let messages = Set(cases.map { SFTPBrowserModel.errorMessage($0.0, host: host) })
        #expect(messages.count == cases.count)
    }
}

// MARK: - The model against the fake

@MainActor
struct SFTPBrowserModelTests {
    @Test("connecting lists the pane's directory, filtering the server's dot entries")
    func connectLists() async {
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [
            makeEntry("."), makeEntry(".."),
            makeEntry("zeta.txt", permissions: 0o100644),
            makeEntry("sub", permissions: 0o040755),
            makeEntry("alpha.txt", permissions: 0o100644),
        ]
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        #expect(model.connectionState == .connected)
        #expect(model.currentPath == "/srv/app")
        // Directories first, then by name; "." and ".." never shown.
        #expect(model.entries.map(\.name) == ["sub", "alpha.txt", "zeta.txt"])
        #expect(model.entries.map(\.kind) == [.directory, .file, .file])
        #expect(fake.connectedHosts == ["build-box"])
    }

    @Test("a server without statvfs reports volume information as unavailable")
    func volumeUnsupported() async {
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = []
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        await waitUntil("volume probed") { model.volumeStatus != .unknown }
        #expect(model.volumeStatus == .unsupported)
    }

    @Test("a server with statvfs reports free space")
    func volumeAvailable() async {
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = []
        fake.volumeInfoResult = SFTPVolumeInfo(
            blockSize: 4096, fragmentSize: 4096, blocks: 1000, blocksFree: 500,
            blocksAvailable: 400, files: 0, filesFree: 0, filesAvailable: 0,
            filesystemID: 0, flags: 0, nameMaximum: 255)
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        await waitUntil("volume probed") { model.volumeStatus != .unknown }
        // Spelled out: the inline literal arithmetic inside `#expect` is a
        // type-check timeout on Xcode 27's compiler.
        let expected: SFTPBrowserModel.VolumeStatus = .available(
            free: UInt64(400 * 4096), total: UInt64(1000 * 4096))
        #expect(model.volumeStatus == expected)
    }

    @Test("an authentication failure is named as one, with a way back")
    func connectAuthenticationFailure() async {
        let fake = FakeSFTPClient()
        fake.connectError = .transport(
            .authenticationFailed(diagnostics: "Permission denied (publickey)."))
        let model = SFTPBrowserModel(host: "build-box", startDirectory: nil) { _ in fake }
        model.connect()
        await waitUntil("failed") {
            guard case .failed = model.connectionState else { return false }
            return true
        }
        guard case .failed(let message) = model.connectionState else {
            Issue.record("expected a failed connection")
            return
        }
        #expect(message == L10n.format(
            "sftp.error.authentication", "build-box", "Permission denied (publickey)."))
        #expect(fake.closed, "a refused connection must not linger")

        // Retry works: the same model connects once the error clears.
        fake.connectError = nil
        fake.listings["/home/tester"] = []
        model.connect()
        await waitUntil("connected after retry") { model.connectionState == .connected }
        // No pane directory to start from: the server's REALPATH answer.
        #expect(model.currentPath == "/home/tester")
    }

    @Test("a remoteUnknown launch asks for the host and adopts the typed one")
    func hostEntry() async {
        let fake = FakeSFTPClient()
        fake.listings["/home/tester"] = []
        let model = SFTPBrowserModel(host: nil, startDirectory: nil) { host in
            fake.connectedHosts.append(host)
            return fake
        }
        #expect(model.connectionState == .needsHost)
        model.connect()  // empty field: a no-op, not a connection to ""
        #expect(model.connectionState == .needsHost)
        #expect(fake.connectedHosts.isEmpty)
        model.hostField = "  build-box  "
        model.connect()
        await waitUntil("connected") { model.connectionState == .connected }
        #expect(fake.connectedHosts == ["build-box"], "trimmed before use")
        #expect(model.host == "build-box")
    }

    @Test("the path field rejects relative paths honestly")
    func relativePathRejected() async {
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [makeEntry("a.txt")]
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        model.navigate(to: "relative/dir")
        #expect(model.listingError == L10n.text("sftp.path.notAbsolute"))
        #expect(model.currentPath == "/srv/app", "no navigation happened")
    }

    @Test("navigating into a directory lists it; up walks back")
    func navigation() async {
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [makeEntry("sub", permissions: 0o040755)]
        fake.listings["/srv/app/sub"] = [makeEntry("deep.txt")]
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }

        model.navigateInto(model.entries[0])
        await waitUntil("entered sub") { model.currentPath == "/srv/app/sub" }
        #expect(model.entries.map(\.name) == ["deep.txt"])

        model.navigateUp()
        await waitUntil("back up") { model.currentPath == "/srv/app" }
        #expect(model.entries.map(\.name) == ["sub"])
    }

    @Test("a permission-denied listing keeps the current directory and says why")
    func listingPermissionDenied() async {
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [makeEntry("a.txt")]
        fake.listingErrors["/root"] = .server(
            SFTPStatus(code: .permissionDenied, message: Array("denied".utf8)))
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        model.navigate(to: "/root")
        await waitUntil("error shown") { model.listingError != nil }
        #expect(
            model.listingError
                == L10n.format("sftp.error.permissionDenied", "build-box", "denied"))
        #expect(model.currentPath == "/srv/app")
    }

    @Test("new directory, rename and delete reach the client with full paths")
    func directoryOperations() async throws {
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [
            makeEntry("a.txt"), makeEntry("old", permissions: 0o040755),
        ]
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }

        model.requestNewDirectory()
        let prompt = try #require(model.textPrompt)
        #expect(prompt.message.contains("/srv/app"))
        model.commitTextPrompt("newdir")
        await waitUntil("mkdir") { fake.madeDirectories == ["/srv/app/newdir"] }

        let entry = try #require(model.entries.first { $0.name == "a.txt" })
        model.requestRename(entry)
        #expect(model.textPrompt?.initialText == "a.txt")
        model.commitTextPrompt("b.txt")
        await waitUntil("rename") { !fake.renamed.isEmpty }
        #expect(fake.renamed.first.map { [$0.from, $0.to] } == ["/srv/app/a.txt", "/srv/app/b.txt"])
    }

    @Test("a name with a slash is rejected before the server hears about it")
    func invalidNameRejected() async {
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = []
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        model.requestNewDirectory()
        model.commitTextPrompt("a/b")
        #expect(model.listingError == L10n.text("sftp.name.invalid"))
        #expect(fake.madeDirectories.isEmpty)
    }

    @Test("delete asks, naming host, path and entry count, then removes a directory as one")
    func deleteConfirmation() async throws {
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [
            makeEntry("a.txt"), makeEntry("old", permissions: 0o040755),
        ]
        fake.listings["/srv/app/old"] = [makeEntry("."), makeEntry(".."), makeEntry("x")]
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }

        // A directory's confirmation names host and path and counts what
        // is inside ("." and ".." are the server's bookkeeping, excluded).
        model.selection = ["old"]
        model.requestDelete(model.selectedEntries)
        await waitUntil("directory confirmation") { model.deleteConfirmation != nil }
        let confirmation = try #require(model.deleteConfirmation)
        #expect(confirmation.title.contains("build-box"))
        #expect(confirmation.message.contains("/srv/app/old"))
        #expect(confirmation.message.contains("build-box"))
        #expect(confirmation.message.contains("1"))

        model.confirmDelete()
        await waitUntil("deleted") { !fake.removedDirectories.isEmpty }
        #expect(fake.removedDirectories == ["/srv/app/old"])
        #expect(fake.removed.isEmpty, "a directory goes to rmdir, never to remove")
    }

    // MARK: - Transfers

    @Test("a download with no conflict runs under .fail and completes")
    func downloadNoConflict() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [makeEntry("a.txt", size: 100)]
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        let destination = directory.appendingPathComponent("a.txt")
        model.pickDownloadDestination = { _ in .file(destination) }
        model.selection = ["a.txt"]
        model.requestDownload()

        await waitUntil("done") {
            guard let transfer = model.transfers.first, case .done = transfer.state else {
                return false
            }
            return true
        }
        let call = try #require(fake.transferCalls.first)
        #expect(!call.isUpload)
        #expect(call.remotePath == "/srv/app/a.txt")
        #expect(call.localPath == destination.path)
        #expect(call.policy == "fail")
        #expect(call.disposition == .remove)
        #expect(model.transfers.first?.state == .done(bytes: 100))
        #expect(model.conflictPrompts.isEmpty)
    }

    @Test("an existing destination raises the conflict sheet; each choice maps to its policy")
    func downloadConflictChoices() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appendingPathComponent("a.txt")
        try "already here".write(to: existing, atomically: true, encoding: .utf8)

        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [makeEntry("a.txt", size: 100)]
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        model.pickDownloadDestination = { _ in .file(existing) }
        model.selection = ["a.txt"]
        model.requestDownload()

        await waitUntil("conflict sheet") { !model.conflictPrompts.isEmpty }
        let prompt = try #require(model.conflictPrompts.first)
        #expect(prompt.path == existing.path)
        #expect(!prompt.partialOnly)
        #expect(!prompt.canResume)
        // Both ends are described for the sheet; the wording itself is
        // locale-formatted, so the check stops at non-emptiness.
        #expect(!prompt.destinationDescription.isEmpty)
        #expect(!prompt.sourceDescription.isEmpty)

        // Skip: the row records the decision, nothing is sent.
        model.resolveConflict(prompt.id, choice: .skip)
        #expect(model.transfers.first?.state == .skipped)
        #expect(fake.transferCalls.isEmpty)

        // Overwrite maps to the engine's policy.
        model.requestDownload()
        await waitUntil("second conflict") { !model.conflictPrompts.isEmpty }
        model.resolveConflict(model.conflictPrompts[0].id, choice: .overwrite)
        await waitUntil("overwrite ran") { !fake.transferCalls.isEmpty }
        #expect(fake.transferCalls.last?.policy == "overwrite")
        #expect(fake.transferCalls.last?.localPath == existing.path)

        // Keep both: a renamed destination, still under .fail.
        model.requestDownload()
        await waitUntil("third conflict") { !model.conflictPrompts.isEmpty }
        model.resolveConflict(model.conflictPrompts[0].id, choice: .keepBoth)
        await waitUntil("keep-both ran") { fake.transferCalls.count >= 2 }
        let kept = try #require(fake.transferCalls.last)
        #expect(kept.localPath == directory.appendingPathComponent("a 2.txt").path)
        #expect(kept.policy == "fail")
    }

    @Test("a partial alone raises the partial wording and offers resume")
    func downloadPartialConflict() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("a.txt")
        try "partial".write(
            to: URL(fileURLWithPath: SFTPTransferEngine.partialPath(for: destination.path)),
            atomically: true, encoding: .utf8)

        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [makeEntry("a.txt", size: 100)]
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        model.pickDownloadDestination = { _ in .file(destination) }
        model.selection = ["a.txt"]
        model.requestDownload()

        await waitUntil("conflict sheet") { !model.conflictPrompts.isEmpty }
        let prompt = try #require(model.conflictPrompts.first)
        #expect(prompt.partialOnly)
        #expect(prompt.canResume)

        model.resolveConflict(prompt.id, choice: .resume)
        await waitUntil("resume ran") { !fake.transferCalls.isEmpty }
        let call = try #require(fake.transferCalls.last)
        #expect(call.policy == "resume")
        // A resumed run keeps its partial on interruption — the visible
        // `.corta-part` file, never a silent one at the destination name.
        #expect(call.disposition == .keepForResume)
    }

    @Test("an upload conflict is detected through the remote listing")
    func uploadConflict() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("up.txt")
        try "outgoing".write(to: source, atomically: true, encoding: .utf8)

        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = []
        // The remote destination already exists.
        fake.lstatResults["/srv/app/up.txt"] = SFTPAttributes(size: 42, permissions: 0o100644)
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        model.pickUploadFiles = { [source] }
        model.requestUpload()

        await waitUntil("conflict sheet") { !model.conflictPrompts.isEmpty }
        let prompt = try #require(model.conflictPrompts.first)
        #expect(prompt.path == "/srv/app/up.txt")
        model.resolveConflict(prompt.id, choice: .overwrite)
        await waitUntil("upload ran") { !fake.transferCalls.isEmpty }
        let call = try #require(fake.transferCalls.first)
        #expect(call.isUpload)
        #expect(call.remotePath == "/srv/app/up.txt")
        #expect(call.policy == "overwrite")
    }

    @Test("cancel stops a running transfer and the row says so")
    func cancelTransfer() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [makeEntry("big.bin", size: 1_000_000)]
        fake.onTransfer = { _, progress in
            progress?(.init(completedBytes: 100, totalBytes: 1_000_000))
            while !Task.isCancelled { try await Task.sleep(for: .milliseconds(10)) }
            throw SFTPError.cancelled
        }
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        model.pickDownloadDestination = { _ in .file(directory.appendingPathComponent("big.bin")) }
        model.selection = ["big.bin"]
        model.requestDownload()

        await waitUntil("active") {
            guard case .active = model.transfers.first?.state else { return false }
            return true
        }
        let id = try #require(model.transfers.first?.id)
        model.cancelTransfer(id)
        await waitUntil("cancelled") {
            guard case .cancelled = model.transfers.first?.state else { return false }
            return true
        }
        // A .fail-policy run keeps nothing: no resumable partial is claimed.
        #expect(model.transfers.first?.state == .cancelled(partialKept: false))
    }

    @Test("a transport failure is retryable; retry re-runs under the same policy")
    func retryTransportFailure() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [makeEntry("a.txt", size: 100)]
        var attempts = 0
        fake.onTransfer = { _, _ in
            attempts += 1
            if attempts == 1 { throw SFTPError.transport(.connectionLost) }
        }
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        model.pickDownloadDestination = { _ in .file(directory.appendingPathComponent("a.txt")) }
        model.selection = ["a.txt"]
        model.requestDownload()

        await waitUntil("failed") {
            guard case .failed = model.transfers.first?.state else { return false }
            return true
        }
        guard case .failed(let message, let retryable) = model.transfers.first?.state else {
            Issue.record("expected a failed transfer")
            return
        }
        #expect(retryable, "transport-class failures offer Retry")
        #expect(message == L10n.format("sftp.error.connectionLost", "build-box"))

        let id = try #require(model.transfers.first?.id)
        model.retryTransfer(id)
        await waitUntil("retried to done") {
            guard case .done = model.transfers.first?.state else { return false }
            return true
        }
        #expect(attempts == 2)
        #expect(fake.transferCalls.count == 2)
        #expect(fake.transferCalls.last?.policy == "fail", "the same policy it ran with")
    }

    @Test("a server refusal is a definitive answer: failed, not retryable")
    func serverFailureIsNotRetryable() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [makeEntry("a.txt", size: 100)]
        fake.onTransfer = { _, _ in
            throw SFTPError.server(SFTPStatus(code: .failure, message: Array("no".utf8)))
        }
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        model.pickDownloadDestination = { _ in .file(directory.appendingPathComponent("a.txt")) }
        model.selection = ["a.txt"]
        model.requestDownload()

        await waitUntil("failed") {
            guard case .failed = model.transfers.first?.state else { return false }
            return true
        }
        guard case .failed(_, let retryable) = model.transfers.first?.state else {
            Issue.record("expected a failed transfer")
            return
        }
        #expect(!retryable)
        let id = try #require(model.transfers.first?.id)
        model.retryTransfer(id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(fake.transferCalls.count == 1, "no retry for a definitive answer")
    }
}
