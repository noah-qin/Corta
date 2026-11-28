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

import CortaTerminal

/// Plain text from the visible part of one terminal snapshot.
enum AgentScreenPreview {
    nonisolated static func lines(in grid: Grid.VisibleScreen) -> [String] {
        let rowLimit = 10
        let columnLimit = min(100, grid.columns)
        var lines: [String] = []
        for row in (0..<grid.rows).reversed() {
            let line = grid.line(row)
            guard !line.isEmpty else { continue }
            let text = lineText(line, in: grid, columns: columnLimit)
            if !text.isEmpty { lines.append(text) }
            if lines.count == rowLimit { break }
        }
        return lines.reversed()
    }

    nonisolated private static func lineText(_ line: Line, in grid: Grid.VisibleScreen, columns: Int) -> String {
        let count = min(columns, line.count)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        for column in 0..<count {
            let cell = line[column]
            if cell.attributes.contains(.wideSpacer) { continue }
            let isWide = cell.attributes.contains(.wide)
            if isWide && column + 1 == columns { break }
            if cell.attributes.contains(.invisible) {
                bytes.append(0x20)
                if isWide { bytes.append(0x20) }
            } else if let cluster = grid.graphemes.scalars(for: cell.grapheme) {
                for value in cluster { append(value, to: &bytes) }
            } else {
                append(cell.scalar, to: &bytes)
            }
        }

        // The core bounds each cluster. Keep all of the scalars in each
        // complete cell through the bytes-based cleaner.
        let byteLimit = count * GraphemeTable.maximumClusterScalars * 4
        var text = ProgramText.clean(String(decoding: bytes, as: UTF8.self), limit: byteLimit)
        while let scalar = text.unicodeScalars.last, scalar.properties.isWhitespace {
            text.unicodeScalars.removeLast()
        }
        return text
    }

    nonisolated private static func append(_ value: UInt32, to bytes: inout [UInt8]) {
        // Unicode separators can break a line of SwiftUI text, but occupy a
        // cell on screen. Preserve that spacing without creating a new row.
        if value == 0x2028 || value == 0x2029 {
            bytes.append(0x20)
        } else if let scalar = Unicode.Scalar(value) {
            bytes.append(contentsOf: scalar.utf8)
        }
    }
}
