import Cocoa
import CortaTerminal

/// B14 — Shell ▸ Browse Remote Files…: opens the SFTP browser for the host
/// this pane's terminal is actually talking to (`PaneRemoteState`, B13).
///
/// The gate is the pane state and nothing else: `.remote` knows the host
/// (the remote shell's own OSC 7 report), `.remoteUnknown` knows the pane
/// is remote but not where — the browser window asks, since neither the
/// launcher's argv nor the screen's text is an honest source
/// (`PaneRemoteState`'s doc comment). `.local` and `.unknown` panes have
/// no offer: a browser over a local pane would be a file manager wearing
/// a remote UI, and an uncertain pane may be attached anywhere.
extension ViewController {
    /// The pure half of the gate, so the rule is testable without a pane,
    /// a pty or a window.
    nonisolated static func canBrowseRemoteFiles(state: PaneRemoteState) -> Bool {
        switch state {
        case .remote, .remoteUnknown: return true
        case .local, .unknown: return false
        }
    }

    var canBrowseRemoteFiles: Bool {
        Self.canBrowseRemoteFiles(state: paneRemoteState)
    }

    @objc func browseRemoteFiles(_ sender: Any?) {
        guard isOperable, canBrowseRemoteFiles else { return }
        SFTPBrowserController.show(for: self)
    }
}
