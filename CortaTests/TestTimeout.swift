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

/// How much longer than the written figure every wait in this suite gets.
///
/// The app suite's waits are for a real child process to print, a reader
/// loop to observe an exit, a debounced sweep to finish — chains whose
/// latency is a property of the machine, not of the code. The figures are
/// written generously enough that reaching one means something is
/// genuinely wrong, which stops being true on a saturated runner:
/// `childExitOnItsOwnShowsAToast` waited ten seconds for a toast and did
/// not get one on a run where nothing was broken.
///
/// CI sets `TEST_RUNNER_CORTA_TEST_TIMEOUT_SCALE`, which reaches the test
/// host as `CORTA_TEST_TIMEOUT_SCALE`; nothing else does, so a local run
/// keeps the written number and a genuine hang still fails quickly. The
/// core package's `testTimeoutScale` is the same idea for the same reason
/// (#129), and the name is deliberately shared.
///
/// This scales a *ceiling*, never a sleep: a test that waits for a
/// condition finishes as soon as the condition holds, so a larger ceiling
/// costs nothing on a healthy run.
var testTimeoutScale: Int {
    max(1, ProcessInfo.processInfo.environment["CORTA_TEST_TIMEOUT_SCALE"].flatMap(Int.init) ?? 1)
}
