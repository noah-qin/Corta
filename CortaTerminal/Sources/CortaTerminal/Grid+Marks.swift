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

/// Absolute rows — `totalPushed + screenRow` — for marks written long after
/// their row has scrolled into history (a slow command's exit status).
extension Grid {
    public func absoluteRow(ofScreenRow row: Int) -> Int {
        scrollback.totalPushed + row
    }

    public func screenRow(ofAbsoluteRow absolute: Int) -> Int? {
        let row = absolute - scrollback.totalPushed
        return row >= 0 && row < rows ? row : nil
    }

    /// `nil` once evicted.
    public func line(atAbsoluteRow absolute: Int) -> Line? {
        let row = absolute - scrollback.totalPushed
        if row >= 0 { return row < rows ? line(row) : nil }
        let index = scrollback.count + row
        return index >= 0 ? scrollback[index] : nil
    }

    public mutating func setMark(_ mark: LineMark, atAbsoluteRow absolute: Int) {
        let row = absolute - scrollback.totalPushed
        if row >= 0 {
            guard row < rows else { return }
            lines[row].mark = mark
        } else {
            scrollback.setMark(mark, at: scrollback.count + row)
        }
    }

    public var failedPromptRows: [Int] {
        promptRows(matching: { $0 == .promptFailed })
    }

    /// Walked, not indexed: an index would need fixing up by eviction, reflow,
    /// resize and the alternate screen. One pass per ⌘↑, not per frame.
    public var promptRows: [Int] { promptRows(matching: \.isPrompt) }

    private func promptRows(matching predicate: (LineMark) -> Bool) -> [Int] {
        var rows: [Int] = []
        let base = scrollback.totalPushed - scrollback.count
        for index in 0..<scrollback.count where predicate(scrollback[index].mark) {
            rows.append(base + index)
        }
        for row in 0..<self.rows where predicate(line(row).mark) {
            rows.append(scrollback.totalPushed + row)
        }
        return rows
    }

    public var outputStartRows: [Int] {
        promptRows(matching: { $0 == .outputStart })
    }
}
