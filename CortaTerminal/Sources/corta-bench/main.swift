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

import Darwin
import Foundation

/// `corta-bench` — measures the numbers `docs/PERFORMANCE.md` §1 sets
/// targets for, so they are recorded, not estimated. Run release for real
/// numbers:
///
///     swift run -c release corta-bench
///
/// A mode flag runs one measurement alone; without one, the full suite runs
/// in order. `--history` narrows the suite to the history benchmarks.
let arguments = CommandLine.arguments

let modes: [(flag: String, run: () -> Void)] = [
    ("--reader-qos", benchmarkReaderQoS),
    ("--cold-history", probeColdHistory),
    ("--profile-cjk", profileCJKFlood),
    ("--search-only", probeSearchOnly),
    ("--unicode", benchmarkUnicodeCorpora),
    ("--compression", benchmarkCompressionCodecs),
    ("--scroll-allocations", profileSteadyScrolling),
    ("--memory-only", benchmarkScrollbackMemory),
    ("--reflow-only", benchmarkReflowCost),
]
if let mode = modes.first(where: { arguments.contains($0.flag) }) {
    mode.run()
    exit(0)
}

let history = arguments.contains("--history")
let suite: [(historyOnly: Bool, run: () -> Void)] = [
    (false, benchmarkParseThroughput),
    (false, benchmarkScrollbackMemory),
    (false, benchmarkKeypressLatency),
    (false, diagnoseScrollbackFootprint),
    (true, benchmarkReflowCost),
    (false, benchmarkResizeStrategies),
    (false, benchmarkSearchCost),
    (false, benchmarkSnapshotLatencyUnderFlood),
    (false, benchmarkFeedUnderSnapshotter),
    (false, benchmarkOutputWakesUnderFlood),
    (false, benchmarkWriteBackpressure),
    (false, benchmarkSearchResponseDistribution),
    (true, benchmarkNonASCIISearchResponse),
    (false, benchmarkSessionSpawnDecomposition),
    (false, benchmarkMultiPaneFixedCost),
    (false, benchmarkKeypressFairnessUnderFlood),
]
for step in suite where step.historyOnly || !history {
    step.run()
}

print("peak RSS across this run: \(String(format: "%.1f", megabytes(peakResidentBytes()))) MB")
