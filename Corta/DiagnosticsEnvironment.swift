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
import OSLog

/// Every `CORTA_*` switch the app reads from its launch environment, and
/// the only place that reads one (`docs/TESTING.md`, "Environment
/// switches").
///
/// They are measurement and staging seams, deliberately not config keys
/// (D10): nobody should tune them, and a launch that sets none behaves as
/// shipped. Each accessor is pure over the environment it is given, so a
/// test passes a dictionary instead of changing the process (D13).
/// `ChildEnvironment` strips the `CORTA_` prefix, so none reaches a shell.
nonisolated enum DiagnosticsEnvironment {
    /// The variable names, for documentation and the stripping test.
    enum Switch: String, CaseIterable {
        case frameLatency = "CORTA_FRAME_LATENCY"
        case maxDrawables = "CORTA_MAX_DRAWABLES"
        case renderMetrics = "CORTA_RENDER_METRICS"
        case renderMetricsKeystrokes = "CORTA_RENDER_METRICS_KEYSTROKES"
        case restoreWindows = "CORTA_RESTORE_WINDOWS"
        case sftpSSH = "CORTA_SFTP_SSH"
        case stageDirectory = "CORTA_STAGE_DIR"

        /// Whether a Release build reads it. Only the switch that substitutes
        /// a program is withheld; the rest measure or stage a build.
        var isHonouredInRelease: Bool { self != .sftpSSH }
    }

    typealias Environment = [String: String]

    private static func value(_ name: Switch, in environment: Environment) -> String? {
        environment[name.rawValue]
    }

    /// `CORTA_FRAME_LATENCY=<n>`, n ≥ 1: the display link's
    /// `preferredFrameLatency`. Unset, the link keeps its default of 2
    /// (`PERFORMANCE.md` §5.7). All builds.
    static func frameLatency(in environment: Environment = ProcessInfo.processInfo.environment)
        -> Float?
    {
        guard let raw = value(.frameLatency, in: environment), let latency = Float(raw),
            latency >= 1
        else { return nil }
        return latency
    }

    /// `CORTA_MAX_DRAWABLES=2|3`: the Metal layer's `maximumDrawableCount`,
    /// for a double-buffering A/B as two launches of one binary. Unset, the
    /// default 3. All builds.
    static func maxDrawables(in environment: Environment = ProcessInfo.processInfo.environment)
        -> Int?
    {
        guard let raw = value(.maxDrawables, in: environment), let count = Int(raw),
            (2...3).contains(count)
        else { return nil }
        return count
    }

    /// `CORTA_RENDER_METRICS`, any value: `RenderMetrics` records frame
    /// timings and logs percentile summaries. All builds — a Release
    /// figure is the one quoted.
    static func isRenderMetricsEnabled(
        in environment: Environment = ProcessInfo.processInfo.environment
    ) -> Bool {
        value(.renderMetrics, in: environment) != nil
    }

    /// `CORTA_RENDER_METRICS=<absolute path>`: also append each summary line
    /// to that file, for a runner that cannot read the unified log. A
    /// relative value only enables the metrics. All builds.
    static func renderMetricsFile(
        in environment: Environment = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard let raw = value(.renderMetrics, in: environment), raw.hasPrefix("/") else {
            return nil
        }
        return URL(fileURLWithPath: raw)
    }

    /// `CORTA_RENDER_METRICS_KEYSTROKES=<n>`, n > 0: keystrokes per
    /// keypress-to-present summary; nil keeps `RenderMetrics`' default.
    /// All builds.
    static func renderMetricsKeystrokes(
        in environment: Environment = ProcessInfo.processInfo.environment
    ) -> Int? {
        guard let raw = value(.renderMetricsKeystrokes, in: environment), let count = Int(raw),
            count > 0
        else { return nil }
        return count
    }

    /// `CORTA_RESTORE_WINDOWS=0`: skip reopening last run's windows, so a UI
    /// test or measurement does not start inside the previous one's layout.
    /// Any other value, or none, leaves `restore-windows` in charge. All
    /// builds.
    static func isWindowRestoreSuppressed(
        in environment: Environment = ProcessInfo.processInfo.environment
    ) -> Bool {
        value(.restoreWindows, in: environment) == "0"
    }

    /// `CORTA_STAGE_DIR=<absolute path>`: the directory that holds the
    /// config, Application Support and rc files instead of the user's
    /// (`AppPaths`), for a staged Release check (`CONFORMANCE.md` §4.4). A
    /// relative value is ignored. All builds.
    static func stageDirectory(
        in environment: Environment = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard let raw = value(.stageDirectory, in: environment), raw.hasPrefix("/") else {
            return nil
        }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    /// `CORTA_SFTP_SSH=<absolute path>`: the program an SFTP connection runs
    /// in place of `/usr/bin/ssh`, with the same argv — how
    /// `RemoteWorkflowUITests` drives the real flow against a local
    /// `sftp-server`. That program would hold the user's SSH session, so
    /// only a Debug build reads it (`SECURITY.md` §4.3), only an absolute
    /// path to an existing executable file is accepted (no `PATH` search),
    /// and its use is logged.
    static func sftpSSHExecutable(
        in environment: Environment = ProcessInfo.processInfo.environment,
        isDebugBuild: Bool = DiagnosticsEnvironment.isDebugBuild,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        guard isDebugBuild, let raw = value(.sftpSSH, in: environment) else { return nil }
        guard raw.hasPrefix("/"), isExecutable(raw) else {
            log.error(
                "CORTA_SFTP_SSH ignored: not an absolute path to an executable: \(raw, privacy: .public)"
            )
            return nil
        }
        log.notice("CORTA_SFTP_SSH: SFTP runs \(raw, privacy: .public) instead of ssh")
        return raw
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    private static let log = Logger(subsystem: "dev.noahqin.Corta", category: "diagnostics")
}
