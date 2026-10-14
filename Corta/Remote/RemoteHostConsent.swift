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

import Foundation

/// Hosts the user agreed to reach over SFTP this run.
///
/// A remote pane's host comes from OSC 7, which is child output and can
/// name any host. `SECURITY.md` §7: displayed, never connected to without
/// the user's own command. So the first connection to a reported host asks,
/// with the name shown and editable; a typed host is consent already.
/// In memory only, or one approval becomes a standing permission for a
/// name later output could reuse.
@MainActor
enum RemoteHostConsent {
    private(set) static var confirmedHosts: Set<String> = []

    static func isConfirmed(_ host: String) -> Bool {
        confirmedHosts.contains(host)
    }

    /// Records consent, given after the user saw the host.
    static func confirm(_ host: String) {
        confirmedHosts.insert(host)
    }
}
