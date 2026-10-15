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
import Foundation
import QuartzCore
import Testing

@testable import Corta

@Suite("Render ownership and energy policies")
struct RenderOwnershipTests {
    /// Runs `body` on a thread of its own and waits for it: the reader's and
    /// the GPU's completion threads are never main.
    private static func onAnotherThread(_ body: @escaping @Sendable () -> Void) {
        let done = DispatchSemaphore(value: 0)
        Thread {
            body()
            done.signal()
        }.start()
        done.wait()
    }
    @Test func cursorCallbacksCannotReviveAnObsoleteHandoff() {
        var state = CursorHandoff()
        let old = state.handOff()
        state.takeBack()
        let presented1 = state.presented(old)
        #expect(!presented1)
        #expect(state.phase == .awaitingMetal)
        let presented2 = state.presented(state.token)
        #expect(presented2)
        #expect(state.phase == .metal)
        let current = state.handOff()
        let presented3 = state.presented(current)
        #expect(presented3)
        #expect(state.phase == .layer)
        let presented4 = state.presented(current)
        #expect(!presented4)
        state.stop()
        let presented5 = state.presented(current)
        #expect(!presented5)
    }
    @Test func outputInvalidatesHandoffWithoutAMainActorHop() {
        let signal = CursorHandoffMailbox()
        signal.setSessionGeneration(3)
        let revision = signal.snapshot.outputRevision
        let token = signal.handOff(expectedOutputRevision: revision)!
        signal.noteOutput(generation: 2)
        #expect(signal.token == token)
        signal.noteOutput(generation: 3)
        #expect(signal.phase == .awaitingMetal)
        #expect(!signal.presented(token))
        let replacement = signal.token
        signal.takeBack()
        #expect(signal.token == replacement)
        #expect(signal.presented(replacement))
        #expect(signal.handOff(expectedOutputRevision: revision) == nil)
    }

    @Test @MainActor func readerRetiresLayerBeforePublishingTakeback() {
        let signal = CursorHandoffMailbox()
        signal.setSessionGeneration(3)
        let layer = CALayer()
        let presentation = CursorLayerPresentation(layer: layer)
        _ = signal.handOff(expectedOutputRevision: 0, presentation: presentation)
        #expect(presentation.startBlink(beginTime: CACurrentMediaTime()))
        signal.noteOutput(generation: 2)
        // An unattached test layer need not retain a committed animation;
        // stale output must leave its presentation eligible to start.
        #expect(presentation.startBlink(beginTime: CACurrentMediaTime()))
        Self.onAnotherThread { signal.noteOutput(generation: 3) }
        #expect(signal.phase == .awaitingMetal)
        #expect(layer.opacity == 0)
        #expect(layer.animationKeys() == nil)
        #expect(!presentation.startBlink(beginTime: CACurrentMediaTime()))
    }

    @Test func encodingAcceptanceCrossesTheOwnerBoundary() {
        let accepted = FrameAcceptanceMarker()
        let dropped = FrameAcceptanceMarker()
        #expect(!accepted.isAccepted)
        Self.onAnotherThread {
            accepted.finishEncoding(true)
            dropped.finishEncoding(false)
        }
        #expect(accepted.isAccepted)
        #expect(!dropped.isAccepted)
    }

    @Test func readerDemotionHasAGraceAndInputWins() {
        #expect(
            ReaderPriorityPolicy.priority(
                visible: true, selected: true,
                hiddenSince: 0, lastInput: nil, now: 10) == .interactive)
        #expect(
            ReaderPriorityPolicy.priority(
                visible: true, selected: false,
                hiddenSince: 0, lastInput: nil, now: 10) == .background)
        #expect(
            ReaderPriorityPolicy.priority(
                visible: false, selected: true,
                hiddenSince: 9, lastInput: nil, now: 10) == .interactive)
        #expect(
            ReaderPriorityPolicy.priority(
                visible: false, selected: true,
                hiddenSince: 0, lastInput: 9, now: 10) == .interactive)
        #expect(
            ReaderPriorityPolicy.priority(
                visible: false, selected: true,
                hiddenSince: 0, lastInput: 7, now: 10) == .background)
    }

    @Test func stallSeamIsBoundedAndAbsentFromRelease() {
        #expect(
            DiagnosticsEnvironment.mainStall(in: ["CORTA_MAIN_STALL": "8/33"], enabled: true)
                == .init(milliseconds: 8, periodMilliseconds: 33))
        #expect(
            DiagnosticsEnvironment.mainStall(in: ["CORTA_MAIN_STALL": "8/33"], enabled: false)
                == nil)
        for value in ["nan/33", "8/8", "1001/2000", "8", "-1/33"] {
            #expect(
                DiagnosticsEnvironment.mainStall(in: ["CORTA_MAIN_STALL": value], enabled: true)
                    == nil)
        }
    }
}
