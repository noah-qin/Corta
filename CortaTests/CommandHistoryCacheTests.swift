import CortaTerminal
import Foundation
import Synchronization
import Testing

@testable import Corta

@MainActor
struct CommandHistoryCacheTests {
    private func terminal() -> Terminal {
        var terminal = Terminal(rows: 12, columns: 60)
        for directory in ["/project/src", "/project/src", "/elsewhere"] {
            terminal.feed(Array("\u{1B}]7;file://localhost\(directory)\u{7}".utf8))
            terminal.feed(Array("\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}echo hello\r\n".utf8))
            terminal.feed(Array("\u{1B}]133;C\u{7}hello\r\n\u{1B}]133;D;0\u{7}".utf8))
        }
        return terminal
    }

    @Test func projectLookupIsDeduplicatedAndOffMainThread() async {
        let calls = Mutex<[String]>([])
        let model = CommandHistoryModel { path in
            #expect(!Thread.isMainThread)
            calls.withLock { $0.append(path) }
            return path.hasPrefix("/project") ? "/project" : nil
        }
        let terminal = terminal()
        model.refresh(
            records: terminal.commandRecords.records(inDirectory: nil),
            grid: terminal.grid, directory: "/project/src")
        #expect(model.rows.count == 3)
        model.projectOnly = true
        await model.resolveProjectRoots()
        #expect(model.rows.count == 2)
        #expect(calls.withLock { $0.sorted() } == ["/elsewhere", "/project/src"])
        model.query = "hello"
        _ = model.rows
        _ = model.rows
        #expect(calls.withLock { $0.count } == 2)
        model.directoryOnly = true
        #expect(model.rows.count == 2)
        model.exitFilter = .failed
        #expect(model.rows.isEmpty)
    }

    @Test func refreshInvalidatesRowsAndClearDropsCachedContent() {
        let model = CommandHistoryModel()
        let terminal = terminal()
        let records = terminal.commandRecords.records(inDirectory: nil)
        model.refresh(records: records, grid: terminal.grid, directory: nil)
        #expect(model.rows.count == 3)
        #expect(model.rows.allSatisfy { $0.commandText == "echo hello" })
        model.refresh(records: [], grid: terminal.grid, directory: nil)
        #expect(model.rows.isEmpty)
        model.refresh(records: records, grid: terminal.grid, directory: nil)
        model.clearHistory()
        #expect(model.rows.isEmpty)
        #expect(model.knownHosts.isEmpty)
    }
}
