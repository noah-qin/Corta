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

import CoreText
import Foundation
import Metal
import Testing

@testable import Corta
@testable import CortaTerminal

/// The render loop's cadence, without a pane: a real session (`/bin/cat`,
/// which echoes what it is sent) and a real renderer, with the pane's
/// stages replaced by counters. What a frame shows is the pane's business;
/// these hold when one is owed.
@MainActor
@Suite(
    .serialized, .metalSerialized,
    .enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
struct PaneFrameLoopTests {
    /// A loop attached to a fresh `cat`, with every stage counted.
    @MainActor
    private final class Rig {
        let loop = PaneFrameLoop()
        let session: TerminalSession
        var batches = 0
        var contentRequests: [Bool] = []
        var displayRequests = 0

        init() throws {
            let device = try #require(MTLCreateSystemDefaultDevice())
            let font = CTFontCreateWithName("Menlo" as CFString, 12, nil)
            let renderer = try TerminalRenderer(device: device, font: font, scale: 1)
            session = try TerminalSession(
                executable: "/bin/cat", arguments: [], environment: ChildEnvironment.default(),
                size: TerminalSize(rows: 10, columns: 40), workingDirectory: "/")
            loop.onOutputBatch = { [unowned self] in batches += 1 }
            loop.onNeedsDisplay = { [unowned self] in displayRequests += 1 }
            loop.content = { [unowned self] hasOutput in
                contentRequests.append(hasOutput)
                return PaneFrameLoop.Content(
                    grid: session.snapshot(), scrollOffset: 0, cursorVisible: true,
                    selection: nil)
            }
            loop.attach(session: session, renderer: renderer)
            session.start()
        }

        deinit { session.stop() }

        /// Runs frames until `condition` holds, as the display link would.
        func frames(until condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(5 * Double(testTimeoutScale))
            while Date() < deadline {
                _ = loop.prepareFrame()
                if condition() { return true }
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            return condition()
        }
    }

    @Test("an idle loop owes one forced frame and then nothing")
    func idleLoopPauses() throws {
        let rig = try Rig()
        // A new attachment draws once: nothing has been drawn yet.
        #expect(rig.loop.prepareFrame())
        #expect(rig.contentRequests == [false])
        // Nothing new: no frame, and the pane is not even asked.
        #expect(!rig.loop.prepareFrame())
        #expect(rig.contentRequests == [false])
        #expect(rig.batches == 0)
    }

    @Test("output runs the batch stage before the diff, at most once a frame")
    func outputRunsTheBatchStage() throws {
        let rig = try Rig()
        _ = rig.loop.prepareFrame()
        rig.session.write(Array("hello\n".utf8))
        var batchesPerFrame: [Int] = []
        let delivered = rig.frames {
            let before = batchesPerFrame.reduce(0, +)
            batchesPerFrame.append(rig.batches - before)
            return rig.session.snapshot().logicalLines().contains { $0.text.contains("hello") }
                && rig.batches > 0
        }
        #expect(delivered)
        #expect(batchesPerFrame.allSatisfy { $0 <= 1 })
        // Every frame that ran the stage asked for content with output.
        #expect(rig.contentRequests.contains(true))
    }

    @Test("`?2026` withholds frames until it is released, then owes one")
    func synchronizedOutputWithholds() throws {
        let rig = try Rig()
        _ = rig.loop.prepareFrame()
        rig.session.write(Array("\u{1B}[?2026h\n".utf8))
        #expect(rig.frames { rig.session.isSynchronizedOutputEnabled })
        let requests = rig.contentRequests.count
        // While it holds, no frame reaches the diff.
        rig.loop.invalidate()
        #expect(!rig.loop.prepareFrame())
        #expect(rig.contentRequests.count == requests)

        rig.session.write(Array("\u{1B}[?2026l\n".utf8))
        var drew = false
        #expect(rig.frames {
            drew = drew || rig.contentRequests.count > requests
            return !rig.session.isSynchronizedOutputEnabled && drew
        })
    }

    @Test("invalidate forces a frame and asks the view for one")
    func invalidateForcesAFrame() throws {
        let rig = try Rig()
        _ = rig.loop.prepareFrame()
        #expect(!rig.loop.prepareFrame())
        let displays = rig.displayRequests
        rig.loop.invalidate()
        #expect(rig.displayRequests == displays + 1)
        #expect(rig.loop.prepareFrame())
    }

    @Test("a replaced session's output neither wakes nor feeds the loop")
    func replacedSessionIsIgnored() throws {
        let rig = try Rig()
        let first = rig.loop.generation
        let device = try #require(MTLCreateSystemDefaultDevice())
        let replacement = try TerminalSession(
            executable: "/bin/cat", arguments: [], environment: ChildEnvironment.default(),
            size: TerminalSize(rows: 10, columns: 40), workingDirectory: "/")
        defer { replacement.stop() }
        let renderer = try TerminalRenderer(
            device: device, font: CTFontCreateWithName("Menlo" as CFString, 12, nil), scale: 1)
        let second = rig.loop.attach(session: replacement, renderer: renderer)
        replacement.start()
        #expect(!rig.loop.isCurrent(first))
        #expect(rig.loop.isCurrent(second))
        _ = rig.loop.prepareFrame()

        // The old session talks; the loop is no longer listening.
        rig.session.write(Array("stale\n".utf8))
        let deadline = Date().addingTimeInterval(5 * Double(testTimeoutScale))
        while Date() < deadline,
            !rig.session.snapshot().logicalLines().contains(where: { $0.text.contains("stale") })
        {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        #expect(!rig.loop.prepareFrame())
        #expect(rig.batches == 0)
    }

    @Test("the content rect is top-anchored when it fits, bottom-anchored when not")
    func contentRectAnchoring() {
        let fits = PaneFrameLoop.contentRect(
            in: CGSize(width: 800, height: 600), scale: 2, gridHeight: 400, topInset: 30)
        #expect(fits.minY == 60)
        let overflows = PaneFrameLoop.contentRect(
            in: CGSize(width: 800, height: 600), scale: 2, gridHeight: 590, topInset: 30)
        #expect(overflows.maxY == 600 - TerminalLayout.insets.bottom * 2)
    }
}
