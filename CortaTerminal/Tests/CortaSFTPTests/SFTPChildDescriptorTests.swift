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
import Darwin
import Foundation
import Testing

/// What the process standing where `ssh` stands inherits (`SECURITY.md` §4.3):
/// its three pipes. `ssh` holds a session, and anything else it held open
/// (another transfer's pipe, a file mid-copy) would outlive that transfer.
@Suite("SFTP child descriptors")
struct SFTPChildDescriptorTests {
    @Test("the spawned child holds stdin, stdout and stderr and nothing else")
    func theChildHoldsOnlyItsStandardPipes() async throws {
        var ends: [Int32] = [0, 0]
        try #require(pipe(&ends) == 0)
        defer {
            close(ends[0])
            close(ends[1])
        }
        #expect(ends[1] <= 200, "the probe does not reach descriptor \(ends[1])")
        let script = """
            [ -e /dev/fd/1 ] && printf 'SEEN '
            exec 2>/dev/null; open=; n=3
            while [ $n -le 200 ]; do ( exec 222<&$n ) && open="$open $n"; n=$((n + 1)); done
            echo "OPEN:$open:END"
            """
        let channel = try SFTPSubprocessChannel.spawn(
            host: "probe", executable: "/bin/sh", arguments: ["-c", script], environment: [:])
        defer { channel.close() }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while !output.contains(Data("END".utf8)) {
            let count = try buffer.withUnsafeMutableBytes { try channel.read(into: $0) }
            if count <= 0 { break }
            output.append(contentsOf: buffer[0..<count])
        }
        #expect(String(decoding: output, as: UTF8.self).contains("SEEN OPEN::END"))
    }
}
