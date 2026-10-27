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
import CortaTerminal
import Testing
import UserNotifications
@testable import Corta

@MainActor
@Suite(.serialized)
struct ProgramNotificationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CORTA_REQUIRE_NOTIFICATIONS"] == "1"))
    func nativeAuthorizationPrecondition() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        #expect(settings.authorizationStatus == .authorized)
        #expect(settings.badgeSetting == .enabled)
        print(
            "Native notification settings: authorization=\(settings.authorizationStatus.rawValue) "
                + "alert=\(settings.alertSetting.rawValue) badge=\(settings.badgeSetting.rawValue)"
        )
    }

    @Test func floodCoalescesAndCancels() throws {
        let original = ConfigurationStore.shared.configuration
        var configuration = original
        configuration.notifyFromPrograms = true
        ConfigurationStore.shared.update { $0 = configuration }
        defer { ConfigurationStore.shared.update { $0 = original } }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: .titled, backing: .buffered, defer: false)
        let notifier = TaskNotifier()
        window.isReleasedWhenClosed = false
        defer { notifier.cancel(); window.close() }
        var delivered: [DesktopNotification] = []
        notifier.programDelivery = { delivered.append($0) }
        for index in 0..<1000 {
            var notice = DesktopNotification()
            notice.body = String(index)
            notifier.noteProgramNotification(notice, visible: false, focused: false, in: window)
        }
        let pending = try #require(notifier.programTimer)
        pending.perform()
        pending.cancel()
        #expect(delivered.count == 1)
        #expect(delivered.first?.body == "999")
        for _ in 0..<1000 {
            notifier.noteProgramNotification(DesktopNotification(), visible: false, focused: false, in: window)
        }
        #expect(delivered.count == 1)
        #expect(notifier.programTimer != nil)
        notifier.cancel()
        #expect(notifier.programPending == nil)
        #expect(notifier.programTimer == nil)
    }

    @Test func delayedExplicitNoticeCannotRealertTheSameBlockedEpisode() throws {
        let original = ConfigurationStore.shared.configuration
        ConfigurationStore.shared.update { $0.notifyFromPrograms = true }
        defer { ConfigurationStore.shared.update { $0 = original } }
        let window = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let notifier = TaskNotifier()
        defer { notifier.cancel(); window.close() }
        var now = 0.0
        var delivered: [DesktopNotification] = []
        notifier.programNow = { now }
        notifier.programDelivery = { delivered.append($0) }
        notifier.setProgramBlocked(true)
        notifier.noteProgramAttention(kind: .permission, in: window)
        let first = try #require(notifier.programTimer)
        first.perform(); first.cancel()
        now = 8
        var explicit = DesktopNotification(); explicit.body = "Claude needs your permission"
        notifier.noteProgramNotification(explicit, visible: false, focused: false, in: window)
        #expect(delivered.count == 1)
        #expect(notifier.programTimer == nil)
        notifier.setProgramBlocked(false)
        notifier.noteProgramNotification(explicit, visible: false, focused: false, in: window)
        let next = try #require(notifier.programTimer)
        next.perform(); next.cancel()
        #expect(delivered.count == 2)
        #expect(delivered.last?.body == explicit.body)
    }

    @Test func occasionsAndProgramOptOut() throws {
        let original = ConfigurationStore.shared.configuration
        defer { ConfigurationStore.shared.update { $0 = original } }
        var configuration = original
        configuration.notifyFromPrograms = true
        ConfigurationStore.shared.update { $0 = configuration }
        let window = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        let notifier = TaskNotifier()
        window.isReleasedWhenClosed = false
        defer { notifier.cancel(); window.close() }
        var notice = DesktopNotification()
        notice.body = "text"
        notifier.noteProgramNotification(notice, visible: true, focused: true, in: window)
        #expect(notifier.programPending == nil)
        notice.occasion = .unfocused
        notifier.noteProgramNotification(notice, visible: true, focused: true, in: window)
        #expect(notifier.programPending == nil)
        notice.occasion = .always
        notifier.noteProgramNotification(notice, visible: true, focused: true, in: window)
        #expect(notifier.programPending?.body == "text")
        notifier.cancel()
        configuration.notifyFromPrograms = false
        ConfigurationStore.shared.update { $0 = configuration }
        notifier.noteProgramNotification(notice, visible: false, focused: false, in: window)
        notifier.noteProgramAttention(kind: .permission, in: window)
        #expect(notifier.programPending == nil)
    }

    @Test func sustainedFloodDeliversAtMostOncePerFiveSeconds() throws {
        let original = ConfigurationStore.shared.configuration
        ConfigurationStore.shared.update { $0.notifyFromPrograms = true }
        defer { ConfigurationStore.shared.update { $0 = original } }
        let window = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let notifier = TaskNotifier()
        defer { notifier.cancel(); window.close() }
        var now = 0.0
        var times: [Double] = []
        notifier.programNow = { now }
        notifier.programDelivery = { _ in times.append(now) }
        for index in 0...2000 {
            now = Double(index) / 100
            notifier.noteProgramNotification(DesktopNotification(), visible: false, focused: false, in: window)
            if TaskNotifier.programDelay(now: now, lastPosted: notifier.programLastPosted) == 0,
               let pending = notifier.programTimer {
                pending.perform()
                pending.cancel()
            }
        }
        #expect(times == [0, 5, 10, 15, 20])
        #expect(zip(times, times.dropFirst()).allSatisfy { $1 - $0 >= 5 })
    }

    @Test func resolvedWaitCancelsAttentionButPreservesIndependentMessage() throws {
        let original = ConfigurationStore.shared.configuration
        ConfigurationStore.shared.update { $0.notifyFromPrograms = true }
        defer { ConfigurationStore.shared.update { $0 = original } }
        let window = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let notifier = TaskNotifier()
        defer { notifier.cancel(); window.close() }
        var delivered: [DesktopNotification] = []
        notifier.programDelivery = { delivered.append($0) }
        notifier.setProgramBlocked(true)
        notifier.noteProgramAttention(kind: .permission, in: window)
        let stale = try #require(notifier.programTimer)
        notifier.setProgramBlocked(false)
        #expect(notifier.programPending == nil)
        #expect(notifier.programTimer == nil)
        stale.perform()
        #expect(delivered.isEmpty)
        notifier.setProgramBlocked(true)
        notifier.noteProgramAttention(kind: .permission, in: window)
        var message = DesktopNotification(); message.body = "Independent message"
        notifier.noteProgramNotification(message, visible: false, focused: false, in: window)
        notifier.setProgramBlocked(false)
        let current = try #require(notifier.programTimer)
        current.perform(); current.cancel()
        #expect(delivered.map(\.body) == ["Independent message"])
    }

    @Test func bellAndKindUpdatesCannotReplaceTextOrRealertWaiting() throws {
        let original = ConfigurationStore.shared.configuration
        ConfigurationStore.shared.update { $0.notifyFromPrograms = true }
        defer { ConfigurationStore.shared.update { $0 = original } }
        let window = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let notifier = TaskNotifier()
        defer { notifier.cancel(); window.close() }
        var delivered: [DesktopNotification] = []
        notifier.programDelivery = { delivered.append($0) }
        notifier.setProgramBlocked(true)
        notifier.noteProgramAttention(kind: .permission, in: window)
        var explicit = DesktopNotification(); explicit.body = "Specific permission"
        notifier.noteProgramNotification(explicit, visible: false, focused: false, in: window)
        notifier.noteProgramAttention(kind: nil, in: window)
        #expect(notifier.programPending?.body == explicit.body)
        let pending = try #require(notifier.programTimer)
        pending.perform(); pending.cancel()
        notifier.noteProgramAttention(kind: nil, in: window)
        notifier.noteProgramAttention(kind: .question, in: window)
        #expect(delivered.count == 1)
        #expect(notifier.programTimer == nil)
    }

    @Test func deliveryRechecksVisibilityAndCanRetryAfterSuppression() throws {
        let original = ConfigurationStore.shared.configuration
        ConfigurationStore.shared.update { $0.notifyFromPrograms = true }
        defer { ConfigurationStore.shared.update { $0 = original } }
        let window = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let notifier = TaskNotifier()
        defer { notifier.cancel(); window.close() }
        var allowed = true
        notifier.programCanDeliver = { _ in allowed }
        var delivered = 0
        notifier.programDelivery = { _ in delivered += 1 }
        notifier.setProgramBlocked(true)
        notifier.noteProgramAttention(kind: .permission, in: window)
        let pending = try #require(notifier.programTimer)
        allowed = false
        pending.perform(); pending.cancel()
        #expect(delivered == 0)
        #expect(!notifier.programBlockedNoticeDelivered)
        allowed = true
        notifier.noteProgramAttention(kind: .permission, in: window)
        let retry = try #require(notifier.programTimer)
        retry.perform(); retry.cancel()
        #expect(delivered == 1)
    }
}

extension ProgramNotificationTests {
    private func settle(_ condition: () -> Bool) async -> Bool {
        let deadline = SuspendingClock.now + .seconds(3)
        while !condition(), SuspendingClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    @Test func lateSubmissionCannotEraseOrOvertakeItsReplacement() async throws {
        let original = ConfigurationStore.shared.configuration
        ConfigurationStore.shared.update { $0.notifyFromPrograms = true }
        defer { ConfigurationStore.shared.update { $0 = original } }
        let window = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let notifier = TaskNotifier()
        defer { notifier.cancel(); window.close() }
        notifier.programAuthorize = {}
        var release: CheckedContinuation<Void, Never>?
        defer { release?.resume() }
        var events: [String] = []
        notifier.programRemove = { events.append("remove") }
        notifier.programSubmit = { request in
            events.append("submit")
            #expect(request.content.userInfo["paneID"] as? String == notifier.paneID.uuidString)
            await withCheckedContinuation { release = $0 }
            events.append("finished")
        }
        notifier.setProgramBlocked(true)
        notifier.noteProgramAttention(kind: .permission, in: window)
        let timer = try #require(notifier.programTimer)
        timer.perform(); timer.cancel()
        #expect(await settle { release != nil })
        notifier.setProgramBlocked(false)
        var independent = DesktopNotification(); independent.body = "Replacement"
        notifier.noteProgramNotification(independent, visible: false, focused: false, in: window)
        #expect(notifier.programTimer == nil, "the replacement waits for the stale OS submission")
        release?.resume(); release = nil
        #expect(await settle { notifier.programSubmission == nil })
        #expect(events == ["submit", "remove", "finished", "remove"])
        #expect(!notifier.programBlockedNoticeDelivered)
        #expect(notifier.programPending?.body == "Replacement")
        #expect(notifier.programTimer != nil)
    }

    @Test func authorizationDelayRechecksVisibilityAndFailedSubmissionAllowsRetry() async throws {
        let original = ConfigurationStore.shared.configuration
        ConfigurationStore.shared.update { $0.notifyFromPrograms = true }
        defer { ConfigurationStore.shared.update { $0 = original } }
        let window = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let notifier = TaskNotifier()
        defer { notifier.cancel(); window.close() }
        var release: CheckedContinuation<Void, Never>?
        defer { release?.resume() }
        notifier.programAuthorize = { await withCheckedContinuation { release = $0 } }
        notifier.programRemove = {}
        var visible = false
        notifier.programCanDeliver = { _ in !visible }
        var attempts = 0
        notifier.programSubmit = { _ in attempts += 1; throw NSError(domain: "test", code: 1) }
        notifier.setProgramBlocked(true)
        notifier.noteProgramAttention(kind: .permission, in: window)
        let timer = try #require(notifier.programTimer)
        timer.perform(); timer.cancel()
        #expect(await settle { release != nil })
        visible = true
        release?.resume(); release = nil
        #expect(await settle { notifier.programSubmission == nil })
        #expect(attempts == 0)
        visible = false
        notifier.programAuthorize = {}
        notifier.noteProgramAttention(kind: .permission, in: window)
        let retry = try #require(notifier.programTimer)
        retry.perform(); retry.cancel()
        #expect(await settle { notifier.programSubmission == nil })
        #expect(attempts == 1)
        #expect(!notifier.programBlockedNoticeDelivered)
        notifier.noteProgramAttention(kind: .permission, in: window)
        #expect(notifier.programTimer != nil)
    }

    @Test func explicitNoticeQueuedDuringSubmissionCannotRealertAfterItSucceeds() async throws {
        let original = ConfigurationStore.shared.configuration
        ConfigurationStore.shared.update { $0.notifyFromPrograms = true }
        defer { ConfigurationStore.shared.update { $0 = original } }
        let window = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let notifier = TaskNotifier()
        defer { notifier.cancel(); window.close() }
        notifier.programAuthorize = {}
        notifier.programRemove = {}
        var release: CheckedContinuation<Void, Never>?
        defer { release?.resume() }
        var attempts = 0
        notifier.programSubmit = { _ in
            attempts += 1
            await withCheckedContinuation { release = $0 }
        }
        notifier.setProgramBlocked(true)
        notifier.noteProgramAttention(kind: .permission, in: window)
        let first = try #require(notifier.programTimer)
        first.perform(); first.cancel()
        #expect(await settle { release != nil })
        var explicit = DesktopNotification(); explicit.body = "Delayed permission"
        notifier.noteProgramNotification(explicit, visible: false, focused: false, in: window)
        release?.resume(); release = nil
        #expect(await settle { notifier.programSubmission == nil })
        #expect(notifier.programBlockedNoticeDelivered)
        let coalesced = try #require(notifier.programTimer)
        coalesced.perform(); coalesced.cancel()
        #expect(attempts == 1)
        #expect(notifier.programPending == nil)
    }

    @Test func newParserEpisodeCanNotifyEvenWhenIntermediateWorkingWasCoalesced() throws {
        let original = ConfigurationStore.shared.configuration
        ConfigurationStore.shared.update { $0.notifyFromPrograms = true }
        defer { ConfigurationStore.shared.update { $0 = original } }
        let window = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let notifier = TaskNotifier()
        defer { notifier.cancel(); window.close() }
        notifier.programRemove = {}
        var delivered = 0
        notifier.programDelivery = { _ in delivered += 1 }
        notifier.setProgramBlocked(true, episode: 1)
        notifier.noteProgramAttention(kind: .permission, in: window)
        let first = try #require(notifier.programTimer)
        first.perform(); first.cancel()
        notifier.setProgramBlocked(true, episode: 1)
        notifier.noteProgramAttention(kind: .question, in: window)
        #expect(notifier.programTimer == nil)
        notifier.setProgramBlocked(true, episode: 2)
        notifier.noteProgramAttention(kind: .permission, in: window)
        let second = try #require(notifier.programTimer)
        second.perform(); second.cancel()
        #expect(delivered == 2)
    }

    @Test func independentMessageCannotAnnounceALaterWaitingEpisode() throws {
        let original = ConfigurationStore.shared.configuration
        ConfigurationStore.shared.update { $0.notifyFromPrograms = true }
        defer { ConfigurationStore.shared.update { $0 = original } }
        let window = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let notifier = TaskNotifier()
        defer { notifier.cancel(); window.close() }
        notifier.programDelivery = { _ in }
        notifier.programRemove = {}
        var old = DesktopNotification(); old.body = "Earlier independent message"
        notifier.noteProgramNotification(old, visible: false, focused: false, in: window)
        notifier.setProgramBlocked(true, episode: 1)
        let pending = try #require(notifier.programTimer)
        pending.perform(); pending.cancel()
        #expect(!notifier.programBlockedNoticeDelivered)
        notifier.noteProgramAttention(kind: .permission, in: window)
        #expect(notifier.programTimer != nil)
    }

    @Test func kittyClosePreservesOtherPendingIDAndWaitingEpisode() throws {
        let original = ConfigurationStore.shared.configuration
        ConfigurationStore.shared.update { $0.notifyFromPrograms = true }
        defer { ConfigurationStore.shared.update { $0 = original } }
        let window = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let notifier = TaskNotifier()
        defer { notifier.cancel(); window.close() }
        notifier.programRemove = {}
        notifier.programDelivery = { _ in }
        var first = DesktopNotification(); first.id = "A"; first.body = "first"
        notifier.noteProgramNotification(first, visible: false, focused: false, in: window)
        let timer = try #require(notifier.programTimer)
        timer.perform(); timer.cancel()
        var second = DesktopNotification(); second.id = "B"; second.body = "second"
        notifier.noteProgramNotification(second, visible: false, focused: false, in: window)
        notifier.setProgramBlocked(true, episode: 7)
        var close = DesktopNotification(); close.id = "A"; close.close = true
        notifier.noteProgramNotification(close, visible: false, focused: false, in: window)
        #expect(notifier.programPending?.id == "B")
        #expect(notifier.programTimer != nil)
        #expect(notifier.programBlocked)
        #expect(notifier.programReportedEpisode == 7)
        close.id = "B"
        notifier.noteProgramNotification(close, visible: false, focused: false, in: window)
        #expect(notifier.programPending == nil)
        #expect(notifier.programTimer == nil)
        #expect(notifier.programBlocked)
    }

    @Test func programClickRoutesWithoutCommandTextOrID() {
        let target = AppDelegate.notificationTarget(paneID: "pane", sessionGeneration: 5,
            commandID: nil, panes: [.init(paneID: "pane", sessionGeneration: 5, commandIDs: [])])
        #expect(target?.paneIndex == 0)
        #expect(target?.commandID == nil)
    }
}
