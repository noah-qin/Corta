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
import Carbon.HIToolbox
import Darwin
import XCTest

/// The app-level numbers `PERFORMANCE.md` §5.6 quotes, taken from a real
/// window, a real display link and real AppKit — what `corta-bench` and
/// `CortaPerformanceTests` cannot see. Run under `TestPlans/Release`:
///
///     xcodebuild test -scheme Corta -testPlan Release -configuration Benchmark \
///       -destination 'platform=macOS' -only-testing:CortaUITests/MeasurementUITests
///
/// It drives the keyboard and the frontmost window for about five minutes:
/// do not use the machine while it runs. It is in no plan CI runs — the
/// runner's GPU cannot report Metal 4 and its numbers would not be this
/// machine's (`PERFORMANCE.md` §5.2).
///
/// Two kinds of result. XCTest's metrics (launch time, CPU, memory) are
/// regression baselines Xcode tracks across runs; they are averages over
/// iterations, so they are never the quoted figure. The quoted figures
/// are distributions (§5.1): `CORTA_RENDER_METRICS` names a file, the app
/// appends a p50/p95/p99 line to it each time a ring fills, and the test
/// attaches the file and prints every line prefixed `measurement:`.
///
/// `CORTA_MAX_DRAWABLES` and `CORTA_FRAME_LATENCY` in the runner's
/// environment (`TEST_RUNNER_CORTA_MAX_DRAWABLES=2 xcodebuild …`) are
/// passed to every launch, so an A/B is two runs with one variable.
final class MeasurementUITests: XCTestCase {
    /// Written by the app, read here. The runner is sandboxed: it may read
    /// anywhere but write only its own container, which the app cannot
    /// read — so the app creates the file and removes it on request.
    private var metricsFile: URL!
    private var previousInputSource: TISInputSource?
    private var measurementStage: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        measurementStage = try UIFixtures.stage("measurement")
        metricsFile = measurementStage.appendingPathComponent("metrics-\(UUID().uuidString).log")
        // Commands are typed; a CJK input method would compose them.
        previousInputSource = LatinInputSource.select()
        report(Self.environmentHeader())
    }

    override func tearDownWithError() throws {
        LatinInputSource.restore(previousInputSource)
    }

    // MARK: - P09: launch to first window

    /// Process start to a responsive first window, five warm launches.
    @MainActor
    func testLaunchToFirstWindow() throws {
        let app = makeApp(renderMetrics: false)
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)]) {
            app.launch()
        }
        app.terminate()
    }

    // MARK: - P10: idle and occluded

    /// A frontmost window with no output should cost next to nothing: the
    /// display link parks. Five four-second samples.
    @MainActor
    func testIdleCPU() throws {
        let app = try launchSettled(renderMetrics: false)
        measure(metrics: [XCTCPUMetric(application: app)], options: Self.fourSecondSamples) {
            pause(4)
        }
        app.terminate()
    }

    /// The same window minimised: an occluded window must not render.
    @MainActor
    func testOccludedCPU() throws {
        let app = try launchSettled(renderMetrics: false)
        app.windows.firstMatch.buttons[XCUIIdentifierMinimizeWindow].click()
        pause(3)
        measure(metrics: [XCTCPUMetric(application: app)], options: Self.fourSecondSamples) {
            pause(4)
        }
        app.terminate()
    }

    // MARK: - P11 / P07: a sustained flood, 1, 2 and 4 panes

    @MainActor func testFloodOnePane() throws { try flood(panes: 1) }
    @MainActor func testFloodTwoPanes() throws { try flood(panes: 2) }
    @MainActor func testFloodFourPanes() throws { try flood(panes: 4) }

    /// `yes` in every pane for about twenty seconds — a 600-frame ring at
    /// 60 Hz fills in ten; a bounded burst drains in milliseconds and
    /// damages a handful of frames. The rings give `cpuFrame`, `gpu` and
    /// `drawableWait` distributions; XCTest gives the app's CPU and memory
    /// over the same window.
    @MainActor
    private func flood(panes: Int) throws {
        let app = try launchSettled()
        let centres = split(app, into: panes)
        for centre in centres {
            app.windows.firstMatch.coordinate(withNormalizedOffset: centre).click()
            app.typeText("yes\n")
        }
        pause(2)
        measure(metrics: [XCTCPUMetric(application: app), XCTMemoryMetric(application: app)],
                options: Self.fourSecondSamples) {
            pause(4)
        }
        // Read the latest full rings while every producer is still running.
        // Stopping panes one by one can fill another ring with a changing
        // workload, so its tail is not an N-pane steady-state measurement.
        let lines = try waitForMetrics(["cpuFrame", "gpu"], timeout: 10)
        report(lines.map { "\(panes)-pane flood \($0)" })
        for centre in centres {
            app.windows.firstMatch.coordinate(withNormalizedOffset: centre).click()
            app.typeKey("c", modifierFlags: .control)
        }
        removeMetricsFile(through: app)
        app.terminate()
    }

    /// Interactive only: kept out of background runs like the other UI
    /// measurements. A region flood and a sustained history gesture each
    /// fill their own frame/GPU rings.
    @MainActor
    func testRegionAndHistoryScrolling() throws {
        var app = try launchSettled()
        app.typeText("printf '\\033[1;39r'; while :; do printf 'region line\\r\\n'; done\n")
        pause(22)
        app.typeKey("c", modifierFlags: .control)
        report(try waitForMetrics(["cpuFrame", "gpu"], timeout: 10).map { "region scroll \($0)" })
        app.typeText("printf '\\033[r'\n")
        removeMetricsFile(through: app)
        app.terminate()

        app = try launchSettled()
        app.typeText("i=0; while [ $i -lt 10000 ]; do printf 'history %s\\r\\n' \"$i\"; i=$((i+1)); done\n")
        pause(3)
        for _ in 0..<800 {
            app.windows.firstMatch.scroll(byDeltaX: 0, deltaY: 20)
            pause(0.03)
        }
        report(try waitForMetrics(["cpuFrame", "gpu"], timeout: 10).map { "history scroll \($0)" })
        removeMetricsFile(through: app)
        app.terminate()
    }

    // MARK: - Recovery: closing a window returns its memory

    /// Opens and closes a window per iteration after a short flood has
    /// grown the first one's scrollback. A physical-memory figure that
    /// climbs with every iteration is a leak; one that stays flat is the
    /// window's memory coming back.
    @MainActor
    func testOpenAndCloseWindowReturnsMemory() throws {
        let app = try launchSettled(renderMetrics: false)
        app.typeText("yes | head -n 200000\n")
        pause(3)
        measure(metrics: [XCTMemoryMetric(application: app)]) {
            app.typeKey("n", modifierFlags: .command)
            pause(1.5)
            // Both counts checked: a keystroke that never lands measures
            // nothing and looks like a flat line.
            XCTAssertEqual(app.windows.count, 2, "⌘N did not open a window")
            app.typeText("yes | head -n 200000\n")
            pause(2)
            app.typeKey("w", modifierFlags: .command)
            pause(1.5)
            XCTAssertEqual(app.windows.count, 1, "⌘W left the new window open")
        }
        app.terminate()
    }

    // MARK: - Keypress to glass (§5.7)

    /// 320 digits about 150 ms apart; the app closes each sample when the
    /// frame with its echo is on the glass (`MTLDrawable.presentedTime`)
    /// and writes the distribution once 200 have landed. Synthetic events
    /// are stamped when XCTest posts them, so the keyboard's HID stage is
    /// not in the number: it is a lower bound on what a finger sees, and a
    /// person typing is the `--manual` command in `PERFORMANCE.md` §5.7.
    /// Stops the moment Corta is not frontmost rather than typing
    /// elsewhere.
    @MainActor
    func testKeypressToGlass() throws {
        let app = try launchSettled()
        for index in 0..<320 {
            guard app.state == .runningForeground else {
                return XCTFail("Corta left the foreground after \(index) keystrokes; typing stopped")
            }
            // A digit: what earlier runs typed, and what a CJK input
            // method passes straight through if one is still selected.
            app.typeKey("1", modifierFlags: [])
            pause(0.15)
        }
        let lines = try waitForMetrics(["keypressToPresent"], timeout: 30)
        report(lines.map { "scripted keypress→glass \($0)" })
        app.typeKey("u", modifierFlags: .control)  // clear the line of digits
        removeMetricsFile(through: app)
        app.terminate()
    }

    /// Launched-app checks for the input/render path, kept out of CI.
    @MainActor
    func testMenuPaste() throws {
        let app = try launchSettled(renderMetrics: false)
        defer { app.terminate() }
        let clipboard = NSPasteboard.general
        let saved = (clipboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        addTeardownBlock { clipboard.clearContents(); clipboard.writeObjects(saved) }
        clipboard.clearContents()
        clipboard.setString("paste-check-280", forType: .string)
        app.typeKey("v", modifierFlags: .command)
        pause(0.5)
        XCTAssertTrue((app.textViews.firstMatch.value as? String)?.contains("paste-check-280") == true)
        app.typeKey("c", modifierFlags: .control)
    }

    // MARK: - Harness

    private static var fourSecondSamples: XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        return options
    }

    @MainActor
    private func makeApp(renderMetrics: Bool = true) -> XCUIApplication {
        let app = UIFixtures.app(stage: measurementStage, runner: Self.self)
        // Session restore would carry the previous test's windows in.
        app.launchEnvironment["CORTA_RESTORE_WINDOWS"] = "0"
        // No rc files: the prompt is up at once and nothing redraws around
        // an echo. The same shell for every run is what makes runs comparable.
        app.launchEnvironment["SHELL"] = "/bin/sh"
        if renderMetrics { app.launchEnvironment["CORTA_RENDER_METRICS"] = metricsFile.path }
        let runner = ProcessInfo.processInfo.environment
        for key in ["CORTA_MAX_DRAWABLES", "CORTA_FRAME_LATENCY", "CORTA_RENDER_METRICS_KEYSTROKES", "CORTA_FRAME_DRIVER"] {
            if let value = runner[key] { app.launchEnvironment[key] = value }
        }
        return app
    }

    /// Launched, frontmost, window up and the shell's prompt drawn.
    @MainActor
    private func launchSettled(renderMetrics: Bool = true) throws -> XCUIApplication {
        let app = makeApp(renderMetrics: renderMetrics)
        addTeardownBlock { app.terminate() }
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "no window within ten seconds")
        pause(2)
        window.click()
        _ = LatinInputSource.select()
        pause(0.5)
        return app
    }

    /// Splits the window into `panes` (1, 2 or 4) and returns each pane's
    /// centre as a normalised offset in the window, for clicking into it.
    @MainActor
    private func split(_ app: XCUIApplication, into panes: Int) -> [CGVector] {
        let window = app.windows.firstMatch
        switch panes {
        case 2:
            app.typeKey("d", modifierFlags: .command)  // left | right
            pause(1.5)
            return [CGVector(dx: 0.25, dy: 0.5), CGVector(dx: 0.75, dy: 0.5)]
        case 4:
            app.typeKey("d", modifierFlags: .command)  // left | right, right focused
            pause(1)
            app.typeKey("D", modifierFlags: [.command, .shift])  // right splits down
            pause(1)
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).click()
            app.typeKey("D", modifierFlags: [.command, .shift])  // left splits down
            pause(1.5)
            return [CGVector(dx: 0.25, dy: 0.25), CGVector(dx: 0.75, dy: 0.25),
                    CGVector(dx: 0.25, dy: 0.75), CGVector(dx: 0.75, dy: 0.75)]
        default:
            return [CGVector(dx: 0.5, dy: 0.5)]
        }
    }

    /// The newest summary line for each metric, once every one has
    /// appeared; fails if a ring never filled.
    private func waitForMetrics(_ metrics: [String], timeout: TimeInterval) throws -> [String] {
        var latest: [String: String] = [:]
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let text = (try? String(contentsOf: metricsFile, encoding: .utf8)) ?? ""
            for line in text.split(separator: "\n") {
                if let metric = metrics.first(where: { line.hasPrefix("\($0):") }) {
                    latest[metric] = String(line)
                }
            }
            if latest.count == metrics.count { break }
            pause(1)
        } while Date() < deadline
        let text = (try? String(contentsOf: metricsFile, encoding: .utf8)) ?? ""
        let attachment = XCTAttachment(string: text)
        attachment.name = "render-metrics"
        attachment.lifetime = .keepAlways
        add(attachment)
        let missing = metrics.filter { latest[$0] == nil }
        guard missing.isEmpty else {
            throw RingNeverFilled(metrics: missing, seconds: Int(timeout))
        }
        return metrics.compactMap { latest[$0] }
    }

    /// The app made the file, so the app's shell removes it.
    @MainActor
    private func removeMetricsFile(through app: XCUIApplication) {
        app.typeText("rm -f '\(metricsFile.path)'\n")
        pause(0.5)
    }

    /// The rows `PERFORMANCE.md` §5.2 says a quoted run must fix.
    private static func environmentHeader() -> [String] {
        func sysctl(_ name: String) -> String {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "?" }
            return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
        }
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        // The runner is built with the configuration the app is, so its
        // flags say which one this run used.
        #if DEBUG
            let build = "Debug, -Onone — not a number to quote"
        #else
            let build = "Release, -O"
        #endif
        let runner = ProcessInfo.processInfo.environment
        return [
            "machine: \(sysctl("hw.model")) / \(sysctl("machdep.cpu.brand_string")); macOS \(os)",
            "build: \(build)",
            "max drawables: \(runner["CORTA_MAX_DRAWABLES"] ?? "default"); frame latency: \(runner["CORTA_FRAME_LATENCY"] ?? "default")",
        ]
    }

    private func report(_ lines: [String]) {
        for line in lines { print("measurement: \(line)") }
    }
}

private struct RingNeverFilled: Error, CustomStringConvertible {
    var metrics: [String]
    var seconds: Int
    var description: String {
        "no \(metrics.joined(separator: ", ")) summary within \(seconds) s — the ring never filled"
    }
}

/// Lets the run loop turn — accessibility queries and the app's own
/// events — rather than blocking the runner's main thread.
private func pause(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}
