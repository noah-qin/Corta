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

import XCTest

extension MeasurementUITests {
    /// Same machine, toolchain and font; only the visible Space producers change.
    @MainActor func testSpaceFloodOneAndSixPanels() throws {
        for count in [1, 6] {
            measurementStage = try UIFixtures.stage("space-flood-\(count)")
            metricsFile = measurementStage.appendingPathComponent("space-metrics-\(UUID().uuidString).log")
            let app = UIFixtures.app(stage: measurementStage, runner: Self.self)
            app.launchEnvironment["CORTA_RENDER_METRICS"] = metricsFile.path
            app.launch()
            defer { app.terminate() }
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
            app.typeKey("s", modifierFlags: [.command, .option])
            pause(5)
            XCTAssertEqual(app.textViews.count, count)
            for terminal in app.textViews.allElementsBoundByIndex {
                let text = terminal.value as? String ?? ""
                XCTAssertGreaterThan(text.components(separatedBy: "\n").filter { $0 == "y" }.count, 8)
            }
            pause(22)
            report(try waitForMetrics(["cpuFrame", "gpu", "frameInterval"], timeout: 10)
                .map { "Space \(count)-panel flood \($0)" })
            let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            shot.name = "Space \(count) live producers"
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
    }

}
