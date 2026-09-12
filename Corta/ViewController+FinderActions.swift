import Cocoa
import CortaTerminal

/// B08 — the Finder/output-path half of "focused Finder, drag/drop and
/// output-path actions for current/new pane and parent/project-root
/// navigation." Outbound drag-and-drop is deliberately not part of this:
/// there is no `NSDraggingSource` precedent anywhere in the app, and
/// building one means a new mouse-drag-threshold gesture living alongside
/// `TerminalView+Mouse.swift`'s existing selection-drag handling — real
/// regression risk for one word in a four-part bullet. Revealing the
/// directory in Finder and copying its path cover the same need through
/// existing, safe APIs.
extension ViewController {
    /// Whether any of these actions can do something — `session
    /// .workingDirectory` is already host-filtered to `nil` for a remote or
    /// not-yet-reported directory (`Performer+OSC.swift`'s
    /// `setWorkingDirectory`), the same guarantee `ViewController
    /// +FileReferences.swift` leans on.
    var hasKnownWorkingDirectory: Bool {
        isOperable && session.workingDirectory != nil
    }

    /// Reveals the pane's working directory in Finder — the same call
    /// `SettingsWindowController.revealConfigFile()` already makes for the
    /// config file.
    @objc func revealWorkingDirectoryInFinder(_ sender: Any?) {
        guard let directory = hasKnownWorkingDirectory ? session.workingDirectory : nil else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: directory)])
    }

    /// The "output-path action": puts the working directory on the
    /// clipboard, the same shape `copyLastCommandOutput` already reports
    /// through a toast either way.
    @objc func copyWorkingDirectoryPath(_ sender: Any?) {
        guard let directory = hasKnownWorkingDirectory ? session.workingDirectory : nil else {
            terminalView?.showToast(L10n.text("toast.noWorkingDirectory"), kind: .warning)
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(directory, forType: .string)
        terminalView?.showToast(L10n.text("toast.copiedWorkingDirectory"))
    }

    /// `cd ..`, through the same safety-gated primitive B08's PR #60 built
    /// (`ViewController+DirectoryNavigation.swift`) — no new gate, just a
    /// new source for the path.
    @objc func changeDirectoryToParent(_ sender: Any?) {
        guard let directory = hasKnownWorkingDirectory ? session.workingDirectory : nil else {
            return
        }
        let parent = (directory as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != directory else { return }
        changeDirectory(to: parent)
    }

    /// `cd` to the nearest `.git` ancestor (`DirectoryHistory.projectRoot`),
    /// same gate. A directory with no such ancestor is reported rather than
    /// silently doing nothing — `DirectoryHistory.projectRoot(for:)`'s own
    /// doc comment is explicit that a wrong guess here would be worse than
    /// admitting there is no project root to find.
    @objc func changeDirectoryToProjectRoot(_ sender: Any?) {
        guard let directory = hasKnownWorkingDirectory ? session.workingDirectory : nil else {
            return
        }
        guard let root = DirectoryHistory.projectRoot(for: directory) else {
            terminalView?.showToast(L10n.text("toast.noProjectRoot"), kind: .warning)
            return
        }
        changeDirectory(to: root)
    }

    /// Splits the focused pane with a new one rooted at the parent
    /// directory — `SplitViewController.splitFocusedPane(workingDirectory:)`
    /// already accepts an explicit directory; this only supplies which one.
    @objc func openParentDirectoryInNewPane(_ sender: Any?) {
        guard let directory = hasKnownWorkingDirectory ? session.workingDirectory : nil else {
            return
        }
        let parent = (directory as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != directory else { return }
        splitController?.splitFocusedPane(orientation: .columns, workingDirectory: parent)
    }

    @objc func openProjectRootInNewPane(_ sender: Any?) {
        guard let directory = hasKnownWorkingDirectory ? session.workingDirectory : nil else {
            return
        }
        guard let root = DirectoryHistory.projectRoot(for: directory) else {
            terminalView?.showToast(L10n.text("toast.noProjectRoot"), kind: .warning)
            return
        }
        splitController?.splitFocusedPane(orientation: .columns, workingDirectory: root)
    }
}
