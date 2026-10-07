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

/// The version the terminal reports about itself (XTVERSION). It must match
/// `MARKETING_VERSION` — `VersionAgreementTests` checks — and is a constant,
/// not read from `Bundle.main`: the core has no bundle, and the answer must
/// never carry bytes from the stream (`SECURITY.md` §2.1).
public enum CortaVersion {
    public static let string = "1.1.8"

    /// `Name(version)`, the form xterm's `XTerm(<patch>)` set.
    public static let report = "Corta(\(string))"
}
