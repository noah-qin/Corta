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
import Testing

@testable import CortaSFTP

/// The checked-in SFTP fuzz corpus (`corta-fuzz --target sftp`), replayed on
/// every test pass with the harness's own rule: a frame from a hostile server
/// either fails as a typed error or decodes to a message that survives being
/// encoded again. A crash a long run finds is fixed by adding its input to
/// `Tests/Fuzz/sftp`, which puts it here from then on.
@Suite("SFTP fuzz corpus")
struct SFTPFuzzCorpusTests {
    private static let corpusDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // CortaSFTPTests
        .deletingLastPathComponent()  // Tests
        .appendingPathComponent("Fuzz/sftp")

    @Test("every corpus frame decodes to a typed error or a stable message")
    func corpusReplays() throws {
        let names = try FileManager.default
            .contentsOfDirectory(atPath: Self.corpusDirectory.path)
            .filter { $0.hasSuffix(".bin") }
            .sorted()
        #expect(names.count >= 10, "expected to find the SFTP corpus")
        var decoded = 0
        for name in names {
            let bytes = Array(
                FileManager.default.contents(
                    atPath: Self.corpusDirectory.appendingPathComponent(name).path) ?? Data())
            _ = SFTPVolumeInfo(extendedReplyBody: bytes)
            guard let message = try? SFTPCodec.decodeFrame(bytes) else { continue }
            decoded += 1
            let frame = SFTPCodec.encodeFrame(message)
            #expect(
                try SFTPCodec.decodeFrame(Array(frame.dropFirst(4))) == message,
                "\(name) did not survive re-encoding")
        }
        // The corpus holds well-formed frames as well as lying ones.
        #expect(decoded >= 5)
    }

    @Test("lying counts and lengths in the corpus fail as typed errors")
    func lyingFramesAreRefused() {
        for name in ["name-count-lies.bin", "attrs-extended-lies.bin", "string-too-long.bin", "unknown-type.bin"] {
            let bytes = Array(
                FileManager.default.contents(
                    atPath: Self.corpusDirectory.appendingPathComponent(name).path) ?? Data())
            #expect(!bytes.isEmpty, "\(name) is missing")
            #expect(throws: SFTPCodecError.self, "\(name) decoded") {
                _ = try SFTPCodec.decodeFrame(bytes)
            }
        }
    }
}
