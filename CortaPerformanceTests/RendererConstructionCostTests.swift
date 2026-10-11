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

import Corta
import CoreText
import Darwin
import Foundation
import Metal
import Testing

extension PerformanceSuites {
    /// Pane-creation cost driver. Every pane's `TerminalRenderer` builds a
    /// `Metal4Backend`; without the per-device pipeline cache, each of those
    /// would compile three `MTLRenderPipelineState`s and re-serialise the
    /// `MTLBinaryArchive`, so splitting a window paid a shader-compile-sized
    /// cost per new pane. This is the measurement harness
    /// for that change — not an assertion (same convention as
    /// `FrameCPUBaselineTests`): the per-construction distribution is written to
    /// a file so it survives outside the ephemeral test log.
    @Suite struct RendererConstructionCostTests {
        @Test func measureAtlasStorageModes() throws {
            let device = try #require(MTLCreateSystemDefaultDevice())
            let font = CTFontCreateWithName("Menlo" as CFString, 12, nil)
            func footprint() -> UInt64 {
                var info = task_vm_info_data_t()
                var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
                let result = withUnsafeMutablePointer(to: &info) { pointer in
                    pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                    }
                }
                return result == KERN_SUCCESS ? info.phys_footprint : 0
            }
            var warm: TerminalRenderer? = try TerminalRenderer(device: device, font: font, scale: 2)
            _ = warm?.atlasAllocatedBytes
            warm = nil
            Thread.sleep(forTimeInterval: 0.25)
            var report = "four-pane atlas storage (Menlo 12 @2x, \(BenchmarkBuild.configuration))\n"
            for mode in [MTLStorageMode.managed, .shared] {
                let before = footprint(), allocated = device.currentAllocatedSize
                let start = DispatchTime.now().uptimeNanoseconds
                let renderers = try (0..<4).map { _ in
                    try TerminalRenderer(device: device, font: font, scale: 2, atlasStorageMode: mode)
                }
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
                withExtendedLifetime(renderers) {
                    report += "\(mode): texture allocated \(renderers.map(\.atlasAllocatedBytes)), device delta \(Int64(device.currentAllocatedSize) - Int64(allocated)), footprint delta \(Int64(footprint()) - Int64(before)), init \(ms) ms\n"
                }
            }
            try report.write(toFile: "/tmp/corta-atlas-storage.txt", atomically: true, encoding: .utf8)
        }

        @Test func measureRendererConstructionCost() throws {
            guard let device = MTLCreateSystemDefaultDevice() else {
                Issue.record("No Metal device available in this environment")
                return
            }

            // Construction #1 is forced cold (`discardPipelines`) so the report
            // shows the compile cost panes no longer pay past the first;
            // #2...#8 are the warm-cache cost every split pane actually hits.
            // Only a launch's first creation reads the binary archive, and the
            // test host's already happened, so cold here means a real
            // compile — an upper bound on what a real launch's first pane pays.
            let constructions = 8
            var durations: [Double] = []
            QuadPipelineCache.discardPipelines()
            for _ in 0..<constructions {
                let start = DispatchTime.now()
                _ = try Metal4Backend(device: device)
                let elapsedMs =
                    Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                durations.append(elapsedMs)
            }

            let sorted = durations.sorted()
            let count = sorted.count
            let p50 = sorted[count / 2]
            let p95 = sorted[min(count - 1, Int(Double(count) * 0.95))]
            let max = sorted[count - 1]
            let perConstruction = durations.enumerated()
                .map { "  #\($0.offset + 1): \(String(format: "%.3f", $0.element)) ms" }
                .joined(separator: "\n")
            let report = """
                renderer construction cost (\(constructions) Metal4Backend inits, one device, \(BenchmarkBuild.configuration)):
                \(perConstruction)
                p50 \(String(format: "%.3f", p50)) ms, p95 \(String(format: "%.3f", p95)) ms, max \(String(format: "%.3f", max)) ms

                """
            let outputPath =
                ProcessInfo.processInfo.environment["CORTA_CONSTRUCTION_OUTPUT"]
                ?? "/tmp/corta-renderer-construction.txt"
            try? report.write(toFile: outputPath, atomically: true, encoding: .utf8)
            #expect(p50 >= 0)  // always true; the measurement is the point
        }
    }
}
