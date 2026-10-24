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
        print("Native notification settings: authorization=\(settings.authorizationStatus.rawValue) alert=\(settings.alertSetting.rawValue) badge=\(settings.badgeSetting.rawValue)")
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

    @Test func programClickRoutesWithoutCommandTextOrID() {
        let target = AppDelegate.notificationTarget(paneID: "pane", sessionGeneration: 5,
            commandID: nil, panes: [.init(paneID: "pane", sessionGeneration: 5, commandIDs: [])])
        #expect(target?.paneIndex == 0)
        #expect(target?.commandID == nil)
    }
}
