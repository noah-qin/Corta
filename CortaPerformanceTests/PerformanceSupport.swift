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
import Metal
import Testing

/// Every measurement in this bundle, one at a time. A figure taken while
/// another suite holds the GPU or the main thread measures both; `.serialized`
/// is recursive, so the suites nested in this one never overlap.
///
/// The bundle imports the app without `@testable`. `-enable-testing`, which
/// `@testable` needs, inhibits the optimisation a Release figure exists to
/// measure; so these suites reach only what `Corta` declares `public`, and
/// build under the `Benchmark` configuration — Release's compiler settings
/// with the development identity (D22) — through `TestPlans/Release`:
///
///     xcodebuild test -scheme Corta -testPlan Release -configuration Benchmark
@Suite(.serialized) enum PerformanceSuites {}

enum BenchmarkBuild {
    /// Written into every report, so a Debug run of the same plan (the
    /// scheme's default configuration) can never be read as the Release one.
    static var configuration: String {
        #if DEBUG
            "Debug, -Onone"
        #else
            "Release, -O"
        #endif
    }

    /// A render target of the format every pipeline is built against.
    static func renderTarget(device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: QuadPipelineCache.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return try #require(device.makeTexture(descriptor: descriptor))
    }
}
