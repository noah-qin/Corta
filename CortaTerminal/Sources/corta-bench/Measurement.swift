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

// Process measurements and how a distribution is reported.

func currentResidentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return info.resident_size
}

func currentFootprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}

func megabytes(_ bytes: UInt64) -> Double { Double(bytes) / 1_048_576 }

/// The distribution of a latency sample set, not its average.
///
/// An average is the one statistic a latency measurement should not be
/// reported as. Keypress latency is not normally distributed — it is a tight
/// body with a tail of vsync misses and scheduling hiccups — and the tail is
/// the part a person feels: 45 ms average with a 90 ms p99 is a terminal that
/// stutters once a second while averaging "fine". So every latency number
/// here reports p50, p95, p99 and the maximum, and the average only as a
/// cross-check against the p50.
struct LatencyDistribution {
    let count: Int
    let meanMs: Double
    let p50Ms: Double
    let p95Ms: Double
    let p99Ms: Double
    let maxMs: Double

    /// - Parameter samplesNanoseconds: need not be sorted.
    init?(samplesNanoseconds: [UInt64]) {
        guard !samplesNanoseconds.isEmpty else { return nil }
        let sorted = samplesNanoseconds.sorted()
        func percentile(_ fraction: Double) -> Double {
            // Nearest-rank, the definition that needs no interpolation and
            // cannot report a value no sample actually had.
            let rank = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
            return Double(sorted[min(max(0, rank), sorted.count - 1)]) / 1e6
        }
        count = sorted.count
        meanMs = Double(sorted.reduce(0, +)) / Double(sorted.count) / 1e6
        p50Ms = percentile(0.50)
        p95Ms = percentile(0.95)
        p99Ms = percentile(0.99)
        maxMs = Double(sorted[sorted.count - 1]) / 1e6
    }

    var description: String {
        "p50 \(String(format: "%.3f", p50Ms)) ms / p95 \(String(format: "%.3f", p95Ms)) ms / "
            + "p99 \(String(format: "%.3f", p99Ms)) ms / max \(String(format: "%.3f", maxMs)) ms "
            + "(mean \(String(format: "%.3f", meanMs)) ms, \(count) samples)"
    }
}

func throughput(_ byteCount: Int, elapsedSeconds: Double) -> Double {
    megabytes(UInt64(byteCount)) / elapsedSeconds
}

/// `ru_maxrss` is bytes on Darwin. Read at the very end so it covers the
/// heaviest benchmark in the process — the run's own peak, not the app's.
func peakResidentBytes() -> UInt64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return UInt64(usage.ru_maxrss)
}

func currentThreadCount() -> Int {
    var threads: thread_act_array_t?
    var count = mach_msg_type_number_t(0)
    guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS else { return -1 }
    let result = Int(count)
    if let threads {
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), vm_size_t(result) * vm_size_t(MemoryLayout<thread_act_t>.stride))
    }
    return result
}
