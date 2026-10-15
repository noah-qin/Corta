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

import CortaSFTP
import Foundation

extension SFTPBrowserModel {
    // MARK: - Pure helpers (the testable half)

    /// The row's kind from ATTRS's mode bits. No bits at all is displayed
    /// as a plain file — the common case for servers that omit ATTRS
    /// permissions — rather than as a spurious "other".
    nonisolated static func kind(ofPermissions permissions: UInt32?) -> Kind {
        guard let permissions else { return .file }
        switch permissions & 0o170000 {
        case 0o040000: return .directory
        case 0o120000: return .symlink
        case 0o100000: return .file
        default: return .other
        }
    }

    /// `drwxr-xr-x` — the `ls -l` rendering of a mode word, set-ID and
    /// sticky bits included.
    nonisolated static func permissionString(_ mode: UInt32) -> String {
        let type: Character =
            switch mode & 0o170000 {
            case 0o040000: "d"
            case 0o120000: "l"
            case 0o060000: "b"
            case 0o020000: "c"
            case 0o010000: "p"
            case 0o140000: "s"
            default: "-"
            }
        var result = String(type)
        // (read, write, execute, set-ID/sticky, its letter) per triple.
        let triples: [(r: UInt32, w: UInt32, x: UInt32, special: UInt32, letter: Character)] = [
            (0o400, 0o200, 0o100, 0o4000, "s"),  // owner, setuid
            (0o040, 0o020, 0o010, 0o2000, "s"),  // group, setgid
            (0o004, 0o002, 0o001, 0o1000, "t"),  // other, sticky
        ]
        for triple in triples {
            result.append(mode & triple.r != 0 ? "r" : "-")
            result.append(mode & triple.w != 0 ? "w" : "-")
            let execute = mode & triple.x != 0
            if mode & triple.special != 0 {
                result.append(
                    execute ? triple.letter : Character(triple.letter.uppercased()))
            } else {
                result.append(execute ? "x" : "-")
            }
        }
        return result
    }

    /// Remote path joining — "/" is the only separator, and the root is
    /// the only directory that already ends in one.
    nonisolated static func joinPath(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/\(name)" : "\(directory)/\(name)"
    }

    nonisolated static func parentPath(of path: String) -> String {
        let trimmed = normalized(path: path)
        guard let slash = trimmed.lastIndex(of: "/"), slash != trimmed.startIndex else {
            return "/"
        }
        return String(trimmed[trimmed.startIndex..<slash])
    }

    /// Strips a trailing slash, so `/usr/` and `/usr` are the same
    /// current-path display; the root survives.
    nonisolated static func normalized(path: String) -> String {
        var end = path.endIndex
        while end > path.startIndex {
            let previous = path.index(before: end)
            guard previous > path.startIndex, path[previous] == "/" else { break }
            end = previous
        }
        return String(path[..<end])
    }

    /// One keep-both candidate: `report.pdf` → `report 2.pdf` at attempt 1,
    /// `report 3.pdf` at 2; an extensionless name appends at the end.
    nonisolated static func keepBothCandidate(_ path: String, attempt: Int) -> String {
        let nsPath = path as NSString
        let directory = nsPath.deletingLastPathComponent
        let name = nsPath.lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        let `extension` = (name as NSString).pathExtension
        let base = `extension`.isEmpty ? name : stem
        let candidate = "\(base) \(attempt + 1)"
        let renamed = `extension`.isEmpty ? candidate : "\(candidate).\(`extension`)"
        return directory.isEmpty ? renamed : "\(directory)/\(renamed)"
    }

    /// "4.2 MB, modified 12 Sep 2026 …", or the unknown wording when the
    /// server did not say. MainActor, like the formatter it reads.
    static func describe(size: UInt64?, modified: Date?) -> String {
        let sizeText =
            size.map {
                formattedByteCount($0)
            } ?? L10n.text("sftp.size.unknown")
        guard let modified else { return sizeText }
        return L10n.format(
            "sftp.conflict.sizeAndTime", sizeText,
            Self.modificationFormatter.string(from: modified))
    }

    /// Preserve values outside the signed formatter's range without a trap
    /// or a misleading wrapped/clamped size.
    /// A running transfer's line: files for a folder, bytes of the total,
    /// speed, and time left — each part only once it is known, so a fresh
    /// transfer never shows a made-up rate.
    static func progressDetail(
        completed: UInt64, total: UInt64?, bytesPerSecond: Double?, remainingSeconds: Double?,
        files: (completed: Int, total: Int)? = nil
    ) -> String {
        var parts: [String] = []
        if let files {
            parts.append(L10n.format("sftp.transfer.files", files.completed, files.total))
        }
        if let total, total > 0 {
            parts.append(
                L10n.format(
                    "sftp.transfer.progressOf", formattedByteCount(min(completed, total)),
                    formattedByteCount(total)))
        } else {
            parts.append(formattedByteCount(completed))
        }
        if let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond >= 1 {
            parts.append(
                L10n.format("sftp.transfer.rate", formattedByteCount(UInt64(bytesPerSecond))))
        }
        if let remainingSeconds, remainingSeconds.isFinite, remainingSeconds >= 0,
            let text = remainingFormatter.string(from: max(1, remainingSeconds.rounded(.up)))
        {
            parts.append(L10n.format("sftp.transfer.remaining", text))
        }
        return parts.joined(separator: " · ")
    }

    private static let remainingFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.maximumUnitCount = 2
        return formatter
    }()

    static func formattedByteCount(_ bytes: UInt64) -> String {
        guard let signed = Int64(exactly: bytes) else { return "\(bytes) B" }
        return ByteCountFormatter.string(fromByteCount: signed, countStyle: .file)
    }

    private static let modificationFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// The typed error categories, each in its own words — an auth failure
    /// is not "the host is unreachable", and neither is a generic "error".
    nonisolated static func errorMessage(_ error: SFTPError, host key: String) -> String {
        let host = SSHTarget.displayName(forKey: key)
        switch error {
        case .server(let status):
            if status.code == .permissionDenied {
                return L10n.format("sftp.error.permissionDenied", host, status.messageString)
            }
            return L10n.format(
                "sftp.error.server", host, Int(status.code.rawValue), status.messageString)
        case .transport(let transport):
            switch transport {
            case .authenticationFailed(let diagnostics):
                return L10n.format(
                    "sftp.error.authentication", host, trimmedDiagnostics(diagnostics))
            case .hostUnreachable(let diagnostics):
                return L10n.format(
                    "sftp.error.unreachable", host, trimmedDiagnostics(diagnostics))
            case .hostKeyUnverified(let diagnostics):
                return L10n.format(
                    "sftp.error.hostKey", host, trimmedDiagnostics(diagnostics))
            case .subprocessFailed(let code, let diagnostics):
                return L10n.format(
                    "sftp.error.subprocess", host, code, trimmedDiagnostics(diagnostics))
            case .spawnFailed(let code):
                return L10n.format("sftp.error.spawn", code)
            case .executablePathNotAbsolute:
                return L10n.text("sftp.error.spawnPath")
            case .ioFailed(let code):
                return L10n.format("sftp.error.channel", host, code)
            case .closed, .connectionLost:
                return L10n.format("sftp.error.connectionLost", host)
            }
        case .protocolViolation(let detail):
            return L10n.format("sftp.error.protocol", host, detail)
        case .cancelled:
            return L10n.text("sftp.transfer.cancelled")
        case .destinationConflict(let path):
            return L10n.format("sftp.error.conflict", path)
        case .localIOFailed(let operation, let code):
            return L10n.format("sftp.error.localIO", operation, code)
        case .sourceChanged(let path):
            return L10n.format("sftp.error.sourceChanged", path)
        case .replaceIncomplete(let destination, let previousCopy, let newCopy):
            return L10n.format("sftp.error.replaceIncomplete", destination, previousCopy, newCopy)
        }
    }

    /// The ssh stderr tail, trimmed of its trailing newlines for display.
    nonisolated static func trimmedDiagnostics(_ diagnostics: String) -> String {
        diagnostics.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Narrowing for plain `catch` clauses: this toolchain binds a
    /// catch-all's `error` as `any Error` even when the do-block only
    /// throws `SFTPError` (and warns on the always-true typed catch
    /// instead). Anything that is not an `SFTPError` here is a bug in the
    /// client, reported as a violation rather than dropped — except a bare
    /// `CancellationError`, which means exactly one thing.
    nonisolated static func sftpError(_ error: any Error) -> SFTPError {
        if error is CancellationError { return .cancelled }
        return (error as? SFTPError) ?? .protocolViolation("\(error)")
    }
}
