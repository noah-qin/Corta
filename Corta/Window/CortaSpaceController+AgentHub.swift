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

extension CortaSpaceController {
    func configureAgentHubCallbacks() {
        AgentHub.shared.userDeliveryChanged = { [weak self] id, delivery in
            guard let self, self.isActive, self.session(withID: id)?.project === self.selectedProject else { return }
            self.content.showNote(L10n.format("space.member.sent", AgentHub.shared.deliveryName(delivery)))
        }
        AgentHub.shared.snapshot = { [weak self] id in self?.wakeSnapshot(for: id) }
        AgentHub.shared.writeNudge = { [weak self] id in self?.writeNudge(to: id) ?? false }
        AgentHub.shared.contextLines = { [weak self] id in
            guard let self, let session = self.session(withID: id)?.session else { return [] }
            return self.gitContext(for: session)
        }
        AgentHub.shared.inputRevision = { [weak self] id in
            self?.session(withID: id)?.session.pane?.terminalView?.userInputRevision
        }
    }

}
