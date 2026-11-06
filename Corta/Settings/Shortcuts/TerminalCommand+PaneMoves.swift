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

/// The move and swap commands' rows of `TerminalCommand`'s tables.
nonisolated extension TerminalCommand {
    var paneMoveTitle: String {
        switch self {
        case .movePaneLeft: return L10n.text("command.movePaneLeft")
        case .movePaneRight: return L10n.text("command.movePaneRight")
        case .movePaneUp: return L10n.text("command.movePaneUp")
        case .movePaneDown: return L10n.text("command.movePaneDown")
        case .swapPaneLeft: return L10n.text("command.swapPaneLeft")
        case .swapPaneRight: return L10n.text("command.swapPaneRight")
        case .swapPaneUp: return L10n.text("command.swapPaneUp")
        case .swapPaneDown: return L10n.text("command.swapPaneDown")
        case .movePaneToNewTab: return L10n.text("command.movePaneToNewTab")
        case .movePaneToPreviousTab: return L10n.text("command.movePaneToPreviousTab")
        case .movePaneToNextTab: return L10n.text("command.movePaneToNextTab")
        default: return rawValue
        }
    }

    var paneMoveAction: Selector {
        switch self {
        case .movePaneLeft: return #selector(SplitViewController.movePaneLeft(_:))
        case .movePaneRight: return #selector(SplitViewController.movePaneRight(_:))
        case .movePaneUp: return #selector(SplitViewController.movePaneUp(_:))
        case .movePaneDown: return #selector(SplitViewController.movePaneDown(_:))
        case .swapPaneLeft: return #selector(SplitViewController.swapPaneLeft(_:))
        case .swapPaneRight: return #selector(SplitViewController.swapPaneRight(_:))
        case .swapPaneUp: return #selector(SplitViewController.swapPaneUp(_:))
        case .swapPaneDown: return #selector(SplitViewController.swapPaneDown(_:))
        case .movePaneToNewTab: return #selector(SplitViewController.movePaneToNewTab(_:))
        case .movePaneToPreviousTab: return #selector(SplitViewController.movePaneToPreviousTab(_:))
        default: return #selector(SplitViewController.movePaneToNextTab(_:))
        }
    }
}
