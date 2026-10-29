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

import AppKit

nonisolated extension TerminalCommand {
    /// The shortcut a fresh install has. `nil` means the command is reachable
    /// from a menu and the palette but carries no key until the user gives it
    /// one — which is the right default for anything that would otherwise
    /// shadow a key the child process wants.
    var defaultShortcut: Shortcut? {
        switch self {
        case .newWindow: return Shortcut("n", .command)
        case .newTab: return Shortcut("t", .command)
        case .previousTab: return Shortcut("[", [.command, .shift])
        case .nextTab: return Shortcut("]", [.command, .shift])
        case .renameTab: return nil
        case .close: return Shortcut("w", .command)
        // ⌘O, "open" on the Mac; a terminal has no document to open otherwise.
        case .openProject: return Shortcut("o", .command)
        // ⌥⌘S for Space. ⌃⌘S stays the system's Show Sidebar.
        case .toggleSpace: return Shortcut("s", [.command, .option])
        case .splitRight: return Shortcut("d", .command)
        case .splitDown: return Shortcut("d", [.command, .shift])
        case .focusLeft: return Shortcut(Shortcut.parse("left")!.key, [.command, .option])
        case .focusRight: return Shortcut(Shortcut.parse("right")!.key, [.command, .option])
        case .focusUp: return Shortcut(Shortcut.parse("up")!.key, [.command, .option])
        case .focusDown: return Shortcut(Shortcut.parse("down")!.key, [.command, .option])
        case .growPaneHorizontally:
            return Shortcut(Shortcut.parse("right")!.key, [.control, .command])
        case .shrinkPaneHorizontally:
            return Shortcut(Shortcut.parse("left")!.key, [.control, .command])
        case .growPaneVertically:
            return Shortcut(Shortcut.parse("down")!.key, [.control, .command])
        case .shrinkPaneVertically:
            return Shortcut(Shortcut.parse("up")!.key, [.control, .command])
        case .equalizePanes: return nil
        // ⇧⌘⏎ is tmux's `resize-pane -Z` habit written the Mac way, and no
        // menu item or system shortcut claims it.
        case .zoomPane: return Shortcut("\r", [.command, .shift])
        // ⇧⌘T is "bring back the tab I closed" in every browser; a pane is
        // the same gesture one level down.
        case .reopenClosedPane: return Shortcut("t", [.command, .shift])
        case .increaseFontSize: return Shortcut("=", .command)
        case .decreaseFontSize: return Shortcut("-", .command)
        case .resetFontSize: return Shortcut("0", .command)
        case .find: return Shortcut("f", .command)
        case .copy: return Shortcut("c", .command)
        case .paste: return Shortcut("v", .command)
        case .selectAll: return Shortcut("a", .command)
        case .scrollPageUp: return Shortcut(Shortcut.parse("pageup")!.key, .shift)
        case .scrollPageDown: return Shortcut(Shortcut.parse("pagedown")!.key, .shift)
        case .scrollToTop: return Shortcut(Shortcut.parse("home")!.key, .shift)
        case .scrollToBottom: return Shortcut(Shortcut.parse("end")!.key, .shift)
        case .previousCommand: return Shortcut(Shortcut.parse("up")!.key, .command)
        case .nextCommand: return Shortcut(Shortcut.parse("down")!.key, .command)
        // ⌘K is the key every Mac terminal puts on "clear what is on
        // screen". The other two ship unbound: both discard history, and a
        // key that throws away a build log by accident is not a default.
        // ⇧⌘↑/↓ sit next to ⌘↑/↓, which jump between all commands — the
        // shift narrows the same gesture to the ones that failed.
        case .previousFailedCommand:
            return Shortcut(Shortcut.parse("up")!.key, [.command, .shift])
        case .nextFailedCommand:
            return Shortcut(Shortcut.parse("down")!.key, [.command, .shift])
        case .copyLastCommandOutput: return nil
        case .snapshotRunningCommandOutput: return nil
        case .exportCommandOutput: return nil
        case .openFileReferenceInCommand: return nil
        case .revealWorkingDirectory: return nil
        case .copyWorkingDirectoryPath: return nil
        case .changeDirectoryToParent: return nil
        case .changeDirectoryToProjectRoot: return nil
        case .openParentDirectoryInNewPane: return nil
        case .openProjectRootInNewPane: return nil
        case .searchCommandHistory: return nil
        // ⇧⌘S, the save-as of an app that has no document to save.
        case .exportText: return Shortcut("s", [.command, .shift])
        case .clearScreen: return Shortcut("k", .command)
        case .clearHistory: return nil
        case .resetTerminal: return nil
        // Unbound, like the other commands that throw state away: a key
        // that kills a live connection's pane state by accident is not a
        // default. And it is enabled only for a dead remote pane, where a
        // keypress is rarely how anyone gets there.
        case .reconnectRemote: return nil
        // Unbound: it opens a window against a specific pane's host, which
        // is a mouse's or a menu's gesture more than a keystroke's — and a
        // key spent here is a key the child process can never have.
        case .browseRemoteFiles: return nil
        // Unbound in the app: the Quick Terminal's key is the *system-wide*
        // hotkey `quick-terminal-key` names, held by `GlobalHotKey`, and
        // an in-app key equivalent beside it would be a second binding for
        // the same gesture that only works while Corta is frontmost.
        case .quickTerminal: return nil
        // Unbound: a key that flips a system-wide input mode by accident
        // is not a default, and the state is a checkmark in a menu, not a
        // thing anyone toggles rapidly.
        case .secureKeyboardEntry: return nil
        case .settings: return Shortcut(",", .command)
        case .commandPalette: return Shortcut("p", [.command, .shift])
        }
    }
}
