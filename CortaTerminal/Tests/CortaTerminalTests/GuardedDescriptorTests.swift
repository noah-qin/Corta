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


import CortaPOSIX
import Darwin
import Testing

/// What `GuardedDescriptor` promises about the number itself: kept while a
/// call is in flight, given back to the kernel once the last one leaves.
struct GuardedDescriptorTests {
    private static func isOpen(_ number: Int32) -> Bool { fcntl(number, F_GETFD) != -1 }

    private static func pipeEnds() throws -> (Int32, Int32) {
        var ends: [Int32] = [0, 0]
        try #require(pipe(&ends) == 0)
        return (ends[0], ends[1])
    }

    @Test func aCloseWithNothingInFlightReleasesTheNumber() throws {
        let (read, write) = try Self.pipeEnds()
        defer { close(write) }
        let guarded = GuardedDescriptor(read)
        #expect(guarded.close())
        #expect(!Self.isOpen(read))
        #expect(!guarded.close(), "only the first close closes")
    }

    @Test func aCloseDuringACallReleasesTheNumberWhenTheCallLeaves() throws {
        let (read, write) = try Self.pipeEnds()
        defer { close(write) }
        let guarded = GuardedDescriptor(read)
        #expect(guarded.enter())
        #expect(guarded.close())
        #expect(Self.isOpen(read), "the number must outlive the call still using it")
        #expect(!guarded.enter(), "a closed descriptor admits no new call")
        guarded.leave()
        #expect(!Self.isOpen(read), "the last call out must close the number")
    }
}
