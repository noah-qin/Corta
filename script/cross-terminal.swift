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

// Launches Corta, Ghostty and iTerm2 under one held configuration for the
// cross-terminal latency run (issue #279, `docs/TESTING.md`, *Against other
// terminals*), and turns Typometer's CSV export into p50/p95/p99/max.
//
//   swift script/cross-terminal.swift prepare [--corta <Corta.app>]
//   swift script/cross-terminal.swift check
//   swift script/cross-terminal.swift launch corta|ghostty|iterm2 [--metrics|--throughput]
//   swift script/cross-terminal.swift report <typometer.csv>...
//   swift script/cross-terminal.swift throughput-report
//   swift script/cross-terminal.swift cleanup
//
// Run from the repository root. Everything it writes lives in
// `.build/cross-terminal/`, except iTerm2's `corta-bench` dynamic profile,
// which iTerm2 only reads from its own folder and `cleanup` removes (D13).
// Nothing touches a terminal's normal settings: Corta gets a scratch
// `CORTA_STAGE_DIR`, Ghostty a config file passed for that launch only.

import AppKit
import Carbon
import Foundation

let fileManager = FileManager.default
let root = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
let run = root.appendingPathComponent(".build/cross-terminal", isDirectory: true)
let latencyShell = run.appendingPathComponent("latency-shell")
let cortaStage = run.appendingPathComponent("corta-stage", isDirectory: true)
let ghosttyConfig = run.appendingPathComponent("ghostty.config")
let results = run.appendingPathComponent("results", isDirectory: true)
let cortaAppRecord = run.appendingPathComponent("corta-app-path")
let defaultCortaApp = run.appendingPathComponent("derived/Build/Products/Release/Corta.app")
let ghosttyApp = URL(fileURLWithPath: "/Applications/Ghostty.app")
let iTermApp = URL(fileURLWithPath: "/Applications/iTerm.app")
let iTermProfile = fileManager.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/iTerm2/DynamicProfiles/corta-bench.json")
let ghosttyThroughputConfig = run.appendingPathComponent("ghostty-throughput.config")
/// `alacritty/vtebench`, cloned and built here at a pinned commit.
let vtebenchSource = run.appendingPathComponent("vtebench-src", isDirectory: true)
let vtebench = vtebenchSource.appendingPathComponent("target/release/vtebench")
/// ~100 MB of `corta-bench`'s `makeCorpus` lines; never checked in.
let catCorpus = run.appendingPathComponent("cat-corpus.txt")

func throughputShell(_ terminal: String) -> URL {
    run.appendingPathComponent("throughput-\(terminal)")
}

/// The held variables (`PERFORMANCE.md` §5.2 and #279's table).
let columns = 120
let rows = 30
/// Not the 12 pt default: Typometer finds the typed '.' in a half-size
/// capture and then watches one physical pixel of it, which Corta's 12 pt
/// period on a 2x panel does not cover, so the run never starts. At 18 pt it
/// does. The throughput runs use it in all three.
let fontSize = 18
/// Ghostty is the exception the other way: at 18 pt its period misses the
/// watched pixel the way Corta's does at 12 pt, and at 12 pt it does not.
/// Font size does not enter the keypress-to-glass path; the record says
/// which size each terminal ran at. Latency runs only.
let ghosttyFontSize = 12
/// The face Corta's default resolves to (`NSFont.monospacedSystemFont`):
/// SF Mono, which neither Ghostty nor iTerm2 can find by the name "SF Mono".
let systemMonospacedFamily = ".AppleSystemUIFontMonospaced"
let systemMonospacedPostScript = ".AppleSystemUIFontMonospaced-Regular"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func write(_ text: String, to url: URL, executable: Bool = false) throws {
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
    if executable {
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

@discardableResult
func shell(_ arguments: [String], environment: [String: String]? = nil) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: arguments[0])
    process.arguments = Array(arguments.dropFirst())
    if let environment { process.environment = environment }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

func bundleVersion(_ app: URL) -> String {
    guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
        return "not installed"
    }
    let short = info["CFBundleShortVersionString"] as? String ?? "?"
    let build = info["CFBundleVersion"] as? String ?? "?"
    return "\(short) (\(build))"
}

func cortaApp() -> URL {
    if let recorded = try? String(contentsOf: cortaAppRecord, encoding: .utf8) {
        return URL(fileURLWithPath: recorded.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return defaultCortaApp
}

// MARK: - Environment

struct Environment {
    var lines: [(String, String)] = []
    var warnings: [String] = []
}

func currentInputSource() -> String {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
        let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
    else { return "unknown" }
    return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
}

func environment() -> Environment {
    var record = Environment()
    let commit = shell(["/usr/bin/git", "-C", root.path, "rev-parse", "--short", "HEAD"]).output
    let dirty = !shell(["/usr/bin/git", "-C", root.path, "status", "--porcelain", "--untracked-files=no"]).output.isEmpty
    record.lines.append(("Date", ISO8601DateFormatter().string(from: Date())))
    record.lines.append(("Checkout", commit + (dirty ? " (uncommitted changes)" : "")))
    record.lines.append(("Machine", shell(["/usr/sbin/sysctl", "-n", "hw.model"]).output
        + ", " + shell(["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"]).output))
    record.lines.append(("macOS", ProcessInfo.processInfo.operatingSystemVersionString))
    for screen in NSScreen.screens {
        let size = screen.frame.size
        record.lines.append((
            "Display",
            "\(screen.localizedName): \(Int(size.width))×\(Int(size.height)) pt @\(Int(screen.backingScaleFactor))x, "
                + "\(screen.maximumFramesPerSecond) Hz"))
    }
    let power = shell(["/usr/bin/pmset", "-g", "ps"]).output.components(separatedBy: "\n").first ?? ""
    let onMains = power.contains("AC Power")
    record.lines.append(("Power", onMains ? "mains" : "battery — \(power)"))
    if !onMains { record.warnings.append("On battery: plug in (§5.2; iTerm2 also drops to its CPU renderer on battery).") }
    let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    record.lines.append(("Low Power Mode", lowPower ? "on" : "off"))
    if lowPower { record.warnings.append("Low Power Mode is on: Corta caps its frame rate (#282). Turn it off.") }
    let input = currentInputSource()
    record.lines.append(("Input source", input))
    if !(input.hasSuffix(".ABC") || input.hasSuffix(".US")) {
        record.warnings.append(
            "Input source is \(input): Typometer types '.', which Pinyin turns into '。'. Switch to ABC.")
    }
    let app = cortaApp()
    record.lines.append(("Corta", "\(bundleVersion(app)) — \(app.path)"))
    if !fileManager.fileExists(atPath: app.path) { record.warnings.append("No Corta build at \(app.path).") }
    record.lines.append(("Ghostty", bundleVersion(ghosttyApp)))
    record.lines.append(("iTerm2", bundleVersion(iTermApp)))
    let iTermDefaults = UserDefaults(suiteName: "com.googlecode.iterm2")
    let metal = iTermDefaults?.object(forKey: "UseMetal").map { "\($0)" } ?? "unset (iTerm2's default: on)"
    record.lines.append(("iTerm2 GPU renderer", metal))
    return record
}

/// Every `cat` the latency shell started, with the terminal above it and
/// the grid its tty reports — the check that a window is 120×30 and running
/// the test program, without screen access.
func benchPanes() -> [String] {
    let table = shell(["/bin/ps", "-axwwo", "pid=,ppid=,tty=,comm="]).output
    var parent: [Int: Int] = [:]
    var command: [Int: String] = [:]
    var tty: [Int: String] = [:]
    for line in table.components(separatedBy: "\n") {
        let fields = line.split(separator: " ").map(String.init)
        guard fields.count >= 4, let pid = Int(fields[0]), let ppid = Int(fields[1]) else { continue }
        parent[pid] = ppid
        tty[pid] = fields[2]
        command[pid] = fields[3...].joined(separator: " ")
    }
    var panes: [String] = []
    for (pid, name) in command where name == "cat" || name.hasSuffix("/cat") {
        var ancestor = parent[pid] ?? 1
        var terminal: String?
        while ancestor > 1, terminal == nil {
            let path = command[ancestor] ?? ""
            if path.contains("cross-terminal/derived") || path.contains("Corta.app") {
                terminal = "Corta"
            } else if path.contains("Ghostty.app") {
                terminal = "Ghostty"
            } else if path.contains("iTerm") {
                terminal = "iTerm2"
            }
            ancestor = parent[ancestor] ?? 1
        }
        guard let terminal, let device = tty[pid], device != "??" else { continue }
        let size = shell(["/bin/stty", "-f", "/dev/\(device)", "size"]).output.split(separator: " ")
        let grid = size.count == 2 ? "\(size[1])×\(size[0])" : "unknown"
        let mark = grid == "\(columns)×\(rows)" ? "ok" : "⚠️ expected \(columns)×\(rows)"
        panes.append("\(terminal): cat (pid \(pid)) on \(device), grid \(grid) \(mark)")
    }
    return panes.sorted()
}

func printEnvironment(_ record: Environment) {
    for (key, value) in record.lines { print("  \(key): \(value)") }
    let panes = benchPanes()
    print("  Test panes: " + (panes.isEmpty ? "none open" : ""))
    for pane in panes { print("    \(pane)") }
    if record.warnings.isEmpty {
        print("\nReady.")
    } else {
        print("")
        for warning in record.warnings { print("  ⚠️  \(warning)") }
    }
}

// MARK: - Commands

func prepare(_ arguments: [String]) throws {
    guard fileManager.fileExists(atPath: root.appendingPathComponent("Corta.xcodeproj").path) else {
        fail("run from the repository root")
    }
    if let index = arguments.firstIndex(of: "--corta"), index + 1 < arguments.count {
        let app = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
        guard fileManager.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/Corta").path) else {
            fail("\(app.path) is not a Release Corta.app")
        }
        try write(app.path + "\n", to: cortaAppRecord)
    }
    try fileManager.createDirectory(at: results, withIntermediateDirectories: true)

    // #279's test program: the tty echoes, no line editor sits in between,
    // so every terminal draws the same bytes. Ignores the login-shell
    // arguments each terminal passes.
    //
    // The cursor is hidden first (DECTCEM), in all three alike. Typometer
    // finds the typed '.' from what changed on screen and then watches one
    // pixel of it; a visible cursor is part of that change, pulls the
    // watched point above the dot, which sits on the baseline, and the wait
    // for a pixel that never changes polls 10,000 times between timeout
    // checks — at ~8 ms a poll on macOS, a hang.
    try write(
        "#!/bin/sh\nprintf '\\033[?25l'\nexec cat > /dev/null\n", to: latencyShell, executable: true)

    // A new Corta window opens short of `rows` (#305) by a fixed height —
    // three rows at 12 pt, two at 18 pt; ask for that many more so the
    // child still gets the held grid. `check` reads the winsize back, so
    // the day #305 lands this shows up as a warning.
    let cortaRowShortfall = 2
    try write(
        """
        # Written by script/cross-terminal.swift; scratch stage, deleted by cleanup.
        font-size = \(fontSize)
        columns = \(columns)
        rows = \(rows + cortaRowShortfall)
        cursor-blink = false
        update-auto-check = false
        suggest-applications-folder = false

        """, to: cortaStage.appendingPathComponent("config"))

    func ghosttyConfigText(fontSize: Int, command: URL) -> String {
        """
        # Written by script/cross-terminal.swift; passed with
        # --config-default-files=false, so ~/.config/ghostty is not read.
        font-family = "\(systemMonospacedFamily)"
        font-size = \(fontSize)
        window-width = \(columns)
        window-height = \(rows)
        cursor-style-blink = false
        window-vsync = true
        command = \(command.path)
        shell-integration = none
        window-save-state = never
        confirm-close-surface = false
        quit-after-last-window-closed = true
        auto-update = off

        """
    }
    try write(ghosttyConfigText(fontSize: ghosttyFontSize, command: latencyShell), to: ghosttyConfig)
    try write(
        ghosttyConfigText(fontSize: fontSize, command: throughputShell("ghostty")), to: ghosttyThroughputConfig)

    // Throughput (#279 §4): vtebench's default set, then `cat` of the corpus
    // three times, timed by wall clock inside the terminal. vtebench writes
    // its payload to the terminal and its numbers to the .dat file, so its
    // stdout stays on the tty. The script exits when done, which closes
    // the window.
    for terminal in ["corta", "ghostty", "iterm2"] {
        try write(
            """
            #!/bin/sh
            out="\(results.path)/throughput-\(terminal)-$(date +%Y%m%d-%H%M%S)"
            mkdir -p "$out"
            cd "\(vtebenchSource.path)"
            "\(vtebench.path)" --silent --dat "$out/vtebench.dat"
            now() { /usr/bin/perl -MTime::HiRes=time -e 'printf "%.4f", time'; }
            for i in 1 2 3; do
              start=$(now)
              cat "\(catCorpus.path)"
              end=$(now)
              echo "$i $start $end" >> "$out/cat.txt"
            done
            touch "$out/done"

            """, to: throughputShell(terminal), executable: true)
    }
    if !fileManager.fileExists(atPath: catCorpus.path) {
        // `corta-bench`'s `makeCorpus` shape, with the tty's own newline.
        let generate = shell([
            "/usr/bin/perl", "-e",
            #"open(F, ">", $ARGV[0]) or die; my ($n, $s) = (0, 0); while ($s < 100 * 1048576) { my $l = "\e[32mdrwxr-xr-x\e[0m  \e[34muser\e[0m  file-$n.log\n"; print F $l; $s += length $l; $n++ }"#,
            catCorpus.path,
        ])
        if generate.status != 0 { fail("could not write the cat corpus: \(generate.output)") }
    }

    func iTermProfileEntry(name: String, guid: String, command: URL) -> [String: Any] {
        [
            "Name": name,
            "Guid": guid,
            "Normal Font": "\(systemMonospacedPostScript) \(fontSize)",
            "Non Ascii Font": "\(systemMonospacedPostScript) \(fontSize)",
            "Use Non-ASCII Font": false,
            "Columns": columns,
            "Rows": rows,
            "Blinking Cursor": false,
            "Custom Command": "Yes",
            "Command": command.path,
            "Close Sessions On End": true,
            "Prompt Before Closing 2": 0,
        ]
    }
    let profile: [String: Any] = [
        "Profiles": [
            iTermProfileEntry(name: "corta-bench", guid: "corta-bench-2f6c1e0a-279", command: latencyShell),
            iTermProfileEntry(
                name: "corta-bench-throughput", guid: "corta-bench-throughput-2f6c1e0a-279",
                command: throughputShell("iterm2")),
        ]
    ]
    let json = try JSONSerialization.data(withJSONObject: profile, options: [.prettyPrinted, .sortedKeys])
    try fileManager.createDirectory(at: iTermProfile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try json.write(to: iTermProfile)

    let record = environment()
    var text = "# Cross-terminal run environment\n\n| Variable | Value |\n| --- | --- |\n"
    for (key, value) in record.lines { text += "| \(key) | \(value) |\n" }
    try write(text, to: results.appendingPathComponent("environment-\(Int(Date().timeIntervalSince1970)).md"))

    print("Prepared \(run.path)")
    print("  iTerm2 profile: \(iTermProfile.path) (removed by cleanup)\n")
    printEnvironment(record)
}

func launch(_ arguments: [String]) {
    guard fileManager.fileExists(atPath: latencyShell.path) else { fail("run `prepare` first") }
    guard let which = arguments.first else { fail("launch corta|ghostty|iterm2 [--throughput]") }
    let throughput = arguments.contains("--throughput")
    if throughput, !fileManager.fileExists(atPath: vtebench.path) {
        fail("build vtebench first: git clone https://github.com/alacritty/vtebench \(vtebenchSource.path) && cargo build --release --manifest-path \(vtebenchSource.path)/Cargo.toml")
    }
    switch which {
    case "corta":
        let app = cortaApp()
        let program = throughput ? throughputShell("corta") : latencyShell
        var command = [
            "/usr/bin/open", "-n", "-a", app.path,
            "--env", "SHELL=\(program.path)",
            "--env", "CORTA_STAGE_DIR=\(cortaStage.path)",
            "--env", "CORTA_RESTORE_WINDOWS=0",
        ]
        if arguments.contains("--metrics") {
            let file = results.appendingPathComponent("corta-render-metrics-\(Int(Date().timeIntervalSince1970)).txt")
            command += ["--env", "CORTA_RENDER_METRICS=\(file.path)"]
            print("Render metrics → \(file.path)")
        }
        let result = shell(command)
        if result.status != 0 { fail(result.output) }
    case "ghostty":
        let result = shell([
            "/usr/bin/open", "-n", "-a", ghosttyApp.path, "--args",
            "--config-default-files=false",
            "--config-file=\((throughput ? ghosttyThroughputConfig : ghosttyConfig).path)",
        ])
        if result.status != 0 { fail(result.output) }
    case "iterm2":
        let result = shell(["/usr/bin/open", "-a", iTermApp.path])
        if result.status != 0 { fail(result.output) }
        let name = throughput ? "corta-bench-throughput" : "corta-bench"
        print("iTerm2: choose Profiles ▸ \(name), then close any other iTerm2 window.")
    default:
        fail("unknown terminal \(which): corta, ghostty or iterm2")
    }
}

/// Nearest rank: the value at or below which `p` of the samples lie.
func percentile(_ sorted: [Double], _ p: Double) -> Double {
    let rank = Int((p * Double(sorted.count)).rounded(.up))
    return sorted[max(0, min(sorted.count - 1, rank - 1))]
}

func statisticsRow(_ name: String, _ samples: [Double]) -> String {
    let sorted = samples.sorted()
    let n = Double(sorted.count)
    let mean = sorted.reduce(0, +) / n
    let sd = n > 1 ? (sorted.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / (n - 1)).squareRoot() : 0
    let cells = [percentile(sorted, 0.5), percentile(sorted, 0.95), percentile(sorted, 0.99), sorted.last!,
                 sorted.first!, mean, sd].map { String(format: "%.1f", $0) }
    return "| \(name) | \(sorted.count) | " + cells.joined(separator: " | ") + " |"
}

/// Typometer's export: a header of quoted measurement titles, then one row
/// per sample index, a column per measurement, blank once a column ends.
func report(_ paths: [String]) {
    guard !paths.isEmpty else { fail("report <typometer.csv>...") }
    var measurements: [(title: String, samples: [Double])] = []
    for path in paths {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read \(path)") }
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard let header = lines.first else { continue }
        let titles = header.components(separatedBy: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
        var columns = Array(repeating: [Double](), count: titles.count)
        for line in lines.dropFirst() {
            for (index, field) in line.components(separatedBy: ",").enumerated() where index < titles.count {
                if let value = Double(field.trimmingCharacters(in: .whitespaces)) { columns[index].append(value) }
            }
        }
        for (title, samples) in zip(titles, columns) where !samples.isEmpty {
            measurements.append((title, samples))
        }
    }
    let header = "| Measurement | n | p50 | p95 | p99 | max | min | avg | SD |\n| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"
    print("Each measurement, ms:\n\n\(header)")
    for measurement in measurements { print(statisticsRow(measurement.title, measurement.samples)) }

    // Pooled by the title without its round number, ignoring case: "Corta 1",
    // "corta2" and "CORTA 3" are one terminal.
    var pooled: [String: [Double]] = [:]
    var order: [String] = []
    for measurement in measurements {
        let terminal = measurement.title.lowercased()
            .trimmingCharacters(in: CharacterSet.decimalDigits.union(.whitespaces))
        if pooled[terminal] == nil { order.append(terminal) }
        pooled[terminal, default: []] += measurement.samples
    }
    print("\nPooled per terminal, ms:\n\n\(header)")
    for terminal in order { print(statisticsRow(terminal, pooled[terminal]!)) }
}

/// Every `throughput-<terminal>-<time>` folder the throughput shells wrote:
/// vtebench's per-case milliseconds per sample (lower is faster) as the
/// median of each run, then the median of the runs; `cat` as MiB/s.
func throughputReport() {
    let folders = ((try? fileManager.contentsOfDirectory(atPath: results.path)) ?? [])
        .filter { $0.hasPrefix("throughput-") && fileManager.fileExists(atPath: results.appendingPathComponent("\($0)/done").path) }
        .sorted()
    guard !folders.isEmpty else { fail("no finished throughput runs in \(results.path)") }
    func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }
    var cases: [String] = []
    var perTerminal: [String: [String: [Double]]] = [:]  // terminal → case → run medians
    var catRates: [String: [Double]] = [:]
    var runs: [String: Int] = [:]
    let corpusBytes = Double((try? fileManager.attributesOfItem(atPath: catCorpus.path)[.size] as? Int) ?? 0)
    for folder in folders {
        let terminal = folder.split(separator: "-")[1].description
        runs[terminal, default: 0] += 1
        let directory = results.appendingPathComponent(folder)
        if let dat = try? String(contentsOf: directory.appendingPathComponent("vtebench.dat"), encoding: .utf8) {
            let lines = dat.split(separator: "\n").map { $0.split(separator: " ").map(String.init) }
            guard let header = lines.first else { continue }
            for name in header where !cases.contains(name) { cases.append(name) }
            for (index, name) in header.enumerated() {
                let samples = lines.dropFirst().compactMap { index < $0.count ? Double($0[index]) : nil }
                if !samples.isEmpty { perTerminal[terminal, default: [:]][name, default: []].append(median(samples)) }
            }
        }
        if let text = try? String(contentsOf: directory.appendingPathComponent("cat.txt"), encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let fields = line.split(separator: " ").compactMap { Double($0) }
                if fields.count == 3, fields[2] > fields[1], corpusBytes > 0 {
                    catRates[terminal, default: []].append(corpusBytes / 1_048_576 / (fields[2] - fields[1]))
                }
            }
        }
    }
    let terminals = ["corta", "ghostty", "iterm2"].filter { runs[$0] != nil }
    print("vtebench, ms per sample (median of each run's samples, then of \(terminals.map { "\($0) ×\(runs[$0]!)" }.joined(separator: ", ")) runs); lower is faster:\n")
    print("| Case | " + terminals.joined(separator: " | ") + " |")
    print("| --- |" + String(repeating: " ---: |", count: terminals.count))
    for name in cases {
        let cells = terminals.map { terminal -> String in
            guard let values = perTerminal[terminal]?[name], !values.isEmpty else { return "—" }
            return String(format: "%.1f", median(values))
        }
        print("| `\(name)` | " + cells.joined(separator: " | ") + " |")
    }
    print("\n`cat` of \(String(format: "%.0f", corpusBytes / 1_048_576)) MiB, MiB/s (median of every timing):\n")
    print("| " + terminals.joined(separator: " | ") + " |")
    print("|" + String(repeating: " ---: |", count: terminals.count))
    print("| " + terminals.map { String(format: "%.0f", median(catRates[$0] ?? [0])) }.joined(separator: " | ") + " |")
}

func cleanup() {
    if fileManager.fileExists(atPath: iTermProfile.path) {
        do {
            try fileManager.removeItem(at: iTermProfile)
            print("Removed \(iTermProfile.path)")
        } catch {
            fail("could not remove \(iTermProfile.path): \(error)")
        }
    } else {
        print("No iTerm2 profile to remove.")
    }
    print("Kept \(results.path) (the run's CSVs and environment).")
    print("When the record is written: rm -rf \(run.path)")
}

// MARK: - Main

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "prepare": try prepare(Array(arguments.dropFirst()))
    case "check": printEnvironment(environment())
    case "launch": launch(Array(arguments.dropFirst()))
    case "report": report(Array(arguments.dropFirst()))
    case "throughput-report": throughputReport()
    case "cleanup": cleanup()
    default:
        fail("usage: swift script/cross-terminal.swift prepare|check|launch|report|throughput-report|cleanup")
    }
} catch {
    fail("\(error)")
}
