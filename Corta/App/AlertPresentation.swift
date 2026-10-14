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

extension NSAlert {
    /// As a sheet on `window`, so it blocks that window and nothing else;
    /// app-modal when there is no window to attach to, or when it already
    /// has a sheet — a second sheet queues behind the first, and never
    /// runs if the first closes the window. `completion` runs with the
    /// response either way — after this returns for a sheet, before it
    /// returns for the app-modal fallback.
    static func canPresentSheet(on window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized && window.attachedSheet == nil
    }

    func present(for window: NSWindow?, completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        guard let window, Self.canPresentSheet(on: window) else {
            completion(runModal())
            return
        }
        beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { completion(response) }
        }
    }
}
