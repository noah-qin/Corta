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

import Cocoa
import CortaTerminal

extension ViewController {
    func effectiveCursorStyle(grid: Grid) -> CursorStyle {
        if grid.cursorStyleIsExplicit { return grid.cursorStyle }
        let config = ConfigurationStore.shared.configuration
        return config.cursorShape.style(blinking: config.cursorBlink)
    }

    private var canBlinkCursor: Bool {
        !didTeardown && hasUserFocus && scrollOffset == 0
            && view.window?.occlusionState.contains(.visible) == true
    }

    func stopCursorBlink() {
        cursorBlinkTimer?.invalidate()
        cursorBlinkTimer = nil
        cursorBlinkVisible = true
    }

    func updateCursorBlink(grid: Grid, style: CursorStyle, reset: Bool) {
        let blinking = style == .blinkingBlock || style == .blinkingBar || style == .blinkingUnderline
        guard blinking && canBlinkCursor else {
            stopCursorBlink()
            return
        }
        if reset || lastBlinkCursor != grid.cursor || lastBlinkStyle != style {
            stopCursorBlink()
        }
        lastBlinkCursor = grid.cursor
        lastBlinkStyle = style
        guard cursorBlinkTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.canBlinkCursor else {
                    self.stopCursorBlink()
                    return
                }
                self.cursorBlinkVisible.toggle()
                self.invalidateDisplay()
            }
        }
        timer.tolerance = 0.05
        cursorBlinkTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
