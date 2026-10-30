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
    /// Which group the command palette lists it under.
    ///
    /// Thirty commands in one flat list is thirty things to read before
    /// finding the one you want; grouped, it is five short lists whose
    /// headings say which one to read. The grouping is the one the menu bar
    /// already uses, so the palette teaches where a command lives rather than
    /// replacing that knowledge.
    var category: CommandCategory {
        switch self {
        case .newWindow, .newTab, .previousTab, .nextTab, .renameTab, .close, .quickTerminal, .openProject,
            .toggleSpace, .nextWaitingSession, .sendSelectionToMember:
            return .window
        case .splitRight, .splitDown, .focusLeft, .focusRight, .focusUp, .focusDown,
            .growPaneHorizontally, .shrinkPaneHorizontally, .growPaneVertically,
            .shrinkPaneVertically, .equalizePanes, .zoomPane, .reopenClosedPane:
            return .panes
        case .increaseFontSize, .decreaseFontSize, .resetFontSize, .scrollPageUp,
            .scrollPageDown, .scrollToTop, .scrollToBottom, .previousCommand, .nextCommand,
            .previousFailedCommand, .nextFailedCommand, .copyLastCommandOutput,
            .snapshotRunningCommandOutput, .exportCommandOutput, .openFileReferenceInCommand,
            .revealWorkingDirectory, .copyWorkingDirectoryPath, .changeDirectoryToParent,
            .changeDirectoryToProjectRoot, .openParentDirectoryInNewPane,
            .openProjectRootInNewPane, .searchCommandHistory:
            return .view
        case .clearScreen, .clearHistory, .resetTerminal, .reconnectRemote, .browseRemoteFiles,
            .secureKeyboardEntry:
            return .terminal
        case .find, .copy, .paste, .selectAll, .exportText: return .edit
        case .settings, .commandPalette: return .app
        }
    }

    /// Where the command sits inside its group before any search or recency
    /// reordering: lower comes first. Ordered by how often a command is
    /// reached for, not alphabetically — an alphabetical list puts "Actual
    /// Size" above "Split Pane Right", which is not the order anybody wants.
    var paletteRank: Int {
        switch self {
        case .newTab: return 0
        case .newWindow: return 1
        case .close: return 2
        case .quickTerminal: return 3
        case .previousTab: return 4
        case .nextTab: return 5
        case .renameTab: return 6
        case .toggleSpace: return 7
        case .nextWaitingSession: return 8
        case .sendSelectionToMember: return 9
        case .openProject: return 10
        case .splitRight: return 0
        case .splitDown: return 1
        case .focusLeft: return 2
        case .focusRight: return 3
        case .focusUp: return 4
        case .focusDown: return 5
        case .zoomPane: return 6
        case .reopenClosedPane: return 7
        case .equalizePanes: return 8
        case .growPaneHorizontally: return 9
        case .shrinkPaneHorizontally: return 10
        case .growPaneVertically: return 11
        case .shrinkPaneVertically: return 12
        case .increaseFontSize: return 0
        case .decreaseFontSize: return 1
        case .resetFontSize: return 2
        case .scrollPageUp: return 3
        case .scrollPageDown: return 4
        case .scrollToTop: return 5
        case .scrollToBottom: return 6
        case .previousCommand: return 7
        case .nextCommand: return 8
        case .previousFailedCommand: return 9
        case .nextFailedCommand: return 10
        case .copyLastCommandOutput: return 11
        case .snapshotRunningCommandOutput: return 12
        case .exportCommandOutput: return 13
        case .openFileReferenceInCommand: return 14
        case .revealWorkingDirectory: return 15
        case .copyWorkingDirectoryPath: return 16
        case .changeDirectoryToParent: return 17
        case .changeDirectoryToProjectRoot: return 18
        case .openParentDirectoryInNewPane: return 19
        case .openProjectRootInNewPane: return 20
        case .searchCommandHistory: return 21
        case .copy: return 0
        case .paste: return 1
        case .selectAll: return 2
        case .find: return 3
        case .exportText: return 4
        case .clearScreen: return 0
        case .clearHistory: return 1
        case .resetTerminal: return 2
        case .reconnectRemote: return 3
        case .browseRemoteFiles: return 4
        case .secureKeyboardEntry: return 5
        case .settings: return 0
        case .commandPalette: return 1
        }
    }
}
