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

/// Self-reported metadata, never an identity or an execution instruction.
public struct ProgramStatus: Sendable, Equatable {
    public static let maximumSubtasks = 32
    public static let maximumEntries = maximumSubtasks + 1
    public enum State: String, Sendable { case unknown, idle, working, blocked, done, error }
    public enum Kind: String, Sendable { case question, permission, auth }
    public var state: State
    public var kind: Kind?
    public var app: String = ""
    public var title: String = ""
    public var message: String = ""
    public var progress: Int?
    public var color: String?
    public var statusColor: String?

    public init(state: State, kind: Kind? = nil, app: String = "", title: String = "",
                message: String = "", progress: Int? = nil, color: String? = nil, statusColor: String? = nil) {
        self.state = state; self.kind = kind; self.app = app; self.title = title
        self.message = message; self.progress = progress; self.color = color
        self.statusColor = statusColor
    }
    public var urgency: Int {
        switch state {
        case .blocked: 5
        case .error: 4
        case .working: 3
        case .unknown: 2
        case .done: 1
        case .idle: 0
        }
    }
}

/// One drained read of a pane's program signals (`Terminal.takeProgramSignals`).
/// The `blocked`, `notification` and `attention` edges are consumed by the read.
public struct ProgramSignalSnapshot: Sendable {
    public var statuses: [String: ProgramStatus]
    public var blockedEpisode: Int
    public var tabMetadata: ProgramStatus?
    public var progress: ProgramProgress?
    /// Outer optional: an edge occurred. Inner optional: no specific kind.
    public var blocked: ProgramStatus.Kind??
    /// Applied before `notification`, which is never one of these closes.
    public var closedNotificationIDs: [String]
    public var notification: DesktopNotification?
    public var attention: ProgramAttention?
    public var pointerShape: String?
    public var hasShellIntegration: Bool
    public var isCommandRunning: Bool
    public var lastExitStatus: Int?
}

public struct ProgramProgress: Sendable, Equatable {
    public enum State: Int, Sendable { case normal = 1, error, indeterminate, paused }
    public var state: State
    public var value: Int?
    public init(state: State, value: Int?) { self.state = state; self.value = value }
}

/// Shared bounds for all program-supplied chrome. Lengths are UTF-8 bytes.
public enum ProgramText {
    public static func validID(_ id: String) -> Bool {
        (1...32).contains(id.utf8.count) && id.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || [43, 45, 46, 95].contains($0)
        }
    }
    public static func clean(_ text: String, limit: Int) -> String {
        var result = ""
        var bytes = 0
        for scalar in text.unicodeScalars {
            let value = scalar.value
            guard value >= 0x20, !(0x7F...0x9F).contains(value),
                  !ConcealingScalars.contains(value) else { continue }
            let count = scalar.utf8.count
            guard bytes + count <= limit else { break }
            result.unicodeScalars.append(scalar)
            bytes += count
        }
        return result
    }
    static func decoded(_ text: String, limit: Int) -> String? {
        guard text.utf8.count <= ((limit + 2) / 3) * 4,
              let data = Data(base64Encoded: text), data.count <= limit,
              let decoded = String(data: data, encoding: .utf8) else { return nil }
        return clean(decoded, limit: limit)
    }
}
