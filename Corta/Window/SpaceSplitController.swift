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

/// Space's navigation split: islands apart, and a Toggle Sidebar that collapses the plain item it holds
/// (AppKit's own acts only on a sidebar-behaviour item).
@MainActor
final class SpaceSplitController: NSSplitViewController {
    override func loadView() {
        splitView = SpaceNavigationSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        super.loadView()
    }

    override func toggleSidebar(_ sender: Any?) {
        guard let item = splitViewItems.first else { return }
        NSAnimationContext.runAnimationGroup { _ in item.animator().isCollapsed.toggle() }
    }
}

/// Between the sidebar's island and the grid's, only the background.
private final class SpaceNavigationSplitView: NSSplitView {
    override func drawDivider(in rect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        rect.fill()
    }
}
