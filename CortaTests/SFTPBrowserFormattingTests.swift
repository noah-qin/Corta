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
import CortaSFTP
import Foundation
import Testing
@testable import Corta

struct SFTPBrowserFormattingTests {
    @Test("mode bits render as ls spells them")
    func permissionStrings() {
        #expect(SFTPBrowserModel.permissionString(0o100644) == "-rw-r--r--")
        #expect(SFTPBrowserModel.permissionString(0o040755) == "drwxr-xr-x")
        #expect(SFTPBrowserModel.permissionString(0o120777) == "lrwxrwxrwx")
        #expect(SFTPBrowserModel.permissionString(0o104755) == "-rwsr-xr-x")
        #expect(SFTPBrowserModel.permissionString(0o104644) == "-rwSr--r--")
        #expect(SFTPBrowserModel.permissionString(0o042775) == "drwxrwsr-x")
        #expect(SFTPBrowserModel.permissionString(0o042644) == "drw-r-Sr--")
        #expect(SFTPBrowserModel.permissionString(0o041777) == "drwxrwxrwt")
    }

    @Test("kinds come from the permission bits, unknown defaults to file")
    func kinds() {
        #expect(SFTPBrowserModel.kind(ofPermissions: nil) == .file)
        #expect(SFTPBrowserModel.kind(ofPermissions: 0o040755) == .directory)
        #expect(SFTPBrowserModel.kind(ofPermissions: 0o120777) == .symlink)
        #expect(SFTPBrowserModel.kind(ofPermissions: 0o100644) == .file)
        #expect(SFTPBrowserModel.kind(ofPermissions: 0o060600) == .other)
    }

    @Test("a server's name shows what could disguise it, and lands locally without it")
    func concealedNames() {
        let name = "invoice\u{202E}fdp.sh"
        #expect(SFTPBrowserModel.displayName(name) == "invoice\u{FFFD}fdp.sh")
        #expect(SFTPBrowserModel.localFileName(name) == "invoice_fdp.sh")
        #expect(SFTPBrowserModel.localFileName("a\nb\u{200B}c\u{7F}") == "a_b_c_")
        #expect(SFTPBrowserModel.displayName("项目说明.txt") == "项目说明.txt")
        #expect(SFTPBrowserModel.localFileName("README.md") == "README.md")
    }

    @Test("path helpers are absolute-path arithmetic only")
    func paths() {
        #expect(SFTPBrowserModel.joinPath("/", "a") == "/a")
        #expect(SFTPBrowserModel.joinPath("/srv", "a") == "/srv/a")
        #expect(SFTPBrowserModel.parentPath(of: "/srv/app") == "/srv")
        #expect(SFTPBrowserModel.parentPath(of: "/srv") == "/")
        #expect(SFTPBrowserModel.parentPath(of: "/") == "/")
        #expect(SFTPBrowserModel.normalized(path: "/srv/") == "/srv")
        #expect(SFTPBrowserModel.normalized(path: "/") == "/")
    }

    @Test("keep-both candidates count up from 2 and keep the extension")
    func keepBothNames() {
        #expect(
            SFTPBrowserModel.keepBothCandidate("/tmp/report.pdf", attempt: 1)
                == "/tmp/report 2.pdf")
        #expect(
            SFTPBrowserModel.keepBothCandidate("/tmp/report.pdf", attempt: 2)
                == "/tmp/report 3.pdf")
        #expect(SFTPBrowserModel.keepBothCandidate("/tmp/README", attempt: 1) == "/tmp/README 2")
    }

    @Test("every typed error category gets its own wording")
    func errorWording() {
        let host = "build-box"
        let cases: [(SFTPError, String)] = [
            (
                .server(SFTPStatus(code: .permissionDenied, message: Array("denied".utf8))),
                L10n.format("sftp.error.permissionDenied", host, "denied")
            ),
            (
                .server(SFTPStatus(code: .failure, message: Array("nope".utf8))),
                L10n.format("sftp.error.server", host, Int(SFTPStatus.Code.failure.rawValue), "nope")
            ),
            (
                .transport(.authenticationFailed(diagnostics: "Permission denied\n")),
                L10n.format("sftp.error.authentication", host, "Permission denied")
            ),
            (
                .transport(.hostUnreachable(diagnostics: "timed out")),
                L10n.format("sftp.error.unreachable", host, "timed out")
            ),
            (
                .transport(.subprocessFailed(exitCode: 255, diagnostics: "boom")),
                L10n.format("sftp.error.subprocess", host, 255, "boom")
            ),
            (.transport(.spawnFailed(code: 2)), L10n.format("sftp.error.spawn", 2)),
            (.transport(.executablePathNotAbsolute), L10n.text("sftp.error.spawnPath")),
            (.transport(.ioFailed(code: 5)), L10n.format("sftp.error.channel", host, 5)),
            (
                .transport(.connectionLost), L10n.format("sftp.error.connectionLost", host)
            ),
            (.protocolViolation("bad"), L10n.format("sftp.error.protocol", host, "bad")),
            (.cancelled, L10n.text("sftp.transfer.cancelled")),
            (.destinationConflict(path: "/x"), L10n.format("sftp.error.conflict", "/x")),
            (
                .localIOFailed(operation: "open", code: 13),
                L10n.format("sftp.error.localIO", "open", 13)
            ),
            (.sourceChanged(path: "/s"), L10n.format("sftp.error.sourceChanged", "/s")),
            (
                .replaceIncomplete(destination: "/d", previousCopy: "/d.old", newCopy: "/d.new"),
                L10n.format("sftp.error.replaceIncomplete", "/d", "/d.old", "/d.new")
            ),
        ]
        for (error, expected) in cases {
            #expect(SFTPBrowserModel.errorMessage(error, host: host) == expected, "\(error)")
        }
        // The categories read differently, not one generic "error".
        let messages = Set(cases.map { SFTPBrowserModel.errorMessage($0.0, host: host) })
        #expect(messages.count == cases.count)
    }
}
