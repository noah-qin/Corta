import AppKit
import CortaTerminal
import SwiftUI

/// B14 — hosts `SFTPBrowserView` in a floating window, one per host, the
/// `CommandHistoryController` pattern with a registry instead of a single
/// shared window: a shared window re-targeted at another pane would either
/// abandon live transfers or lie about which host they belong to, so each
/// host keeps its own window (and session) for as long as it is open.
///
/// The controller owns everything AppKit: the window, the title, the file
/// panels (injected into the model as closures, so the model — and its
/// tests — never present one), and teardown. Closing the window closes
/// the connection and cancels its transfers.
@MainActor
final class SFTPBrowserController: NSWindowController, NSWindowDelegate {
    /// Open windows, keyed by the host they are connected to (or will be,
    /// once a `.remoteUnknown` launch's user-entered host connects).
    private static var byHost: [String: SFTPBrowserController] = [:]
    /// Windows not yet connected to anything — kept alive here until they
    /// connect (and move to `byHost`) or close.
    private static var unconnected: [ObjectIdentifier: SFTPBrowserController] = [:]

    let model: SFTPBrowserModel

    /// Opens the browser for a pane. Only called for `.remote` and
    /// `.remoteUnknown` states — `ViewController.canBrowseRemoteFiles`
    /// gates the menu item — and anything else is refused here as well,
    /// because a window over a local pane would be a silent local file
    /// manager wearing a remote UI.
    static func show(for pane: ViewController) {
        switch pane.paneRemoteState {
        case .remote(let host, let directory, _):
            if let open = byHost[host] {
                open.present()
                return
            }
            if RemoteHostConsent.isConfirmed(host) {
                let controller = SFTPBrowserController(host: host, startDirectory: directory)
                byHost[host] = controller
                controller.present()
                return
            }
            // The host is the remote shell's own report — child output,
            // not something the user typed (`RemoteHostConsent`). The first
            // connection to it is asked, with the name prefilled and
            // editable and its provenance stated; the answer is remembered
            // for the run.
            let controller = SFTPBrowserController(
                host: nil, startDirectory: directory, suggestedHost: host)
            unconnected[ObjectIdentifier(controller)] = controller
            controller.present()
        case .remoteUnknown:
            // The host is genuinely not known, and the B13 rule stands:
            // never the launcher's argv (aliases and `~/.ssh/config` names
            // read back wrong), never the screen. The window asks.
            let controller = SFTPBrowserController(host: nil, startDirectory: nil)
            unconnected[ObjectIdentifier(controller)] = controller
            controller.present()
        case .local, .unknown:
            return
        }
    }

    private init(host: String?, startDirectory: String?, suggestedHost: String? = nil) {
        model = SFTPBrowserModel(
            host: host, startDirectory: startDirectory, suggestedHost: suggestedHost)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 280)
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: SFTPBrowserView(model: model))
        model.onTitleChange = { [weak window] title in window?.title = title }
        model.onConnected = { [weak self] host in
            guard let self else { return }
            Self.unconnected.removeValue(forKey: ObjectIdentifier(self))
            Self.byHost[host] = self
            // Connected means the user pressed Connect with this name in
            // front of them (or the name was confirmed earlier this run).
            RemoteHostConsent.confirm(host)
        }
        model.pickUploadFiles = { [weak self] in await self?.pickUploadFiles() ?? [] }
        model.pickDownloadDestination = { [weak self] entries in
            await self?.pickDownloadDestination(for: entries)
        }
        // B14 remote editing — the Edit row action, run through the shared
        // coordinator so browser- and pane-initiated edits of the same
        // remote file land on the same managed copy.
        model.onEditFile = { [weak model] entry in
            guard let model, let host = model.host else { return }
            let remotePath = SFTPBrowserModel.joinPath(model.currentPath, entry.name)
            Task {
                do {
                    let opened = try await RemoteEditCoordinator.shared.open(
                        host: host, remotePath: remotePath, line: 1, column: nil)
                    if !opened {
                        model.listingError = L10n.text("toast.badOpenFileCommand")
                    }
                } catch {
                    let error = SFTPBrowserModel.sftpError(error)
                    model.listingError = SFTPBrowserModel.errorMessage(error, host: host)
                }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func present() {
        model.connect()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.disconnect()
        Self.unconnected.removeValue(forKey: ObjectIdentifier(self))
        if let host = model.host, Self.byHost[host] === self {
            Self.byHost.removeValue(forKey: host)
        }
    }

    // MARK: - Panels (injected into the model as closures)

    private func pickUploadFiles() async -> [URL] {
        guard let window else { return [] }
        let panel = NSOpenPanel()
        panel.title = L10n.text("sftp.action.upload")
        panel.canChooseFiles = true
        // No directory walking: the engine transfers files, and silently
        // recursing into a chosen folder would be a feature wearing a
        // picker's clothes.
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        let response = await panel.beginSheetModal(for: window)
        guard response == .OK else { return [] }
        return panel.urls
    }

    private func pickDownloadDestination(
        for entries: [SFTPBrowserModel.Entry]
    ) async -> SFTPBrowserModel.DownloadDestination? {
        guard let window else { return nil }
        if entries.count == 1, let entry = entries.first {
            // One file: a save panel, so the local name is the user's to
            // choose, prefilled with the remote one.
            let panel = NSSavePanel()
            panel.title = L10n.text("sftp.action.download")
            panel.nameFieldStringValue = entry.name
            let response = await panel.beginSheetModal(for: window)
            guard response == .OK, let url = panel.url else { return nil }
            return .file(url)
        }
        let panel = NSOpenPanel()
        panel.title = L10n.text("sftp.action.download")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        let response = await panel.beginSheetModal(for: window)
        guard response == .OK, let url = panel.url else { return nil }
        return .directory(url)
    }
}
