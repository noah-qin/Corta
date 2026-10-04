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

import XCTest

final class SystemStatusAndThemeEditorUITests: XCTestCase {
    @MainActor func testStatusBarIsOptionalSelectableAndHasLocalHostDetails() throws {
        continueAfterFailure = false
        let stage = try makeStage()
        defer { try? FileManager.default.removeItem(at: stage) }
        let app = makeApp(stage)
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["system-status-bar"].exists)
        openSettings(app)
        let settings = app.windows["Corta.Settings"]
        settings.outlines.firstMatch.staticTexts["Terminal"].click()
        let enable = settings.switches["status-bar-enable"]
        XCTAssertTrue(enable.waitForExistence(timeout: 3))
        enable.click()
        settings.switches["status-item-network"].click()
        settings.buttons[XCUIIdentifierCloseWindow].click()
        let bar = app.buttons["system-status-bar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        let ready = NSPredicate { _, _ in
            let text = bar.value as? String ?? ""
            return text.contains("CPU ") && !text.contains("CPU —")
        }
        let readyExpectation = XCTNSPredicateExpectation(predicate: ready, object: bar)
        XCTAssertEqual(XCTWaiter.wait(for: [readyExpectation], timeout: 8), .completed)
        let text = bar.value as? String ?? ""
        XCTAssertTrue(text.contains("Local"))
        XCTAssertTrue(text.contains("Thermal state"))
        XCTAssertFalse(text.contains("Network"))
        attach(app.windows.firstMatch.screenshot(), name: "system-status-bar")
        bar.click()
        XCTAssertTrue(app.staticTexts["Local host details"].waitForExistence(timeout: 3))
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        // A split must preserve the terminal tree when the bar is a sibling.
        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(bar.exists)
        app.typeKey("+", modifierFlags: .command)
        XCTAssertTrue(bar.exists)
        openSettings(app)
        settings.outlines.firstMatch.staticTexts["Terminal"].click()
        settings.switches["status-bar-enable"].click()
        settings.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertFalse(bar.exists)
        let config = try String(contentsOf: stage.appendingPathComponent("config"), encoding: .utf8)
        XCTAssertTrue(config.contains("status-bar = false"))
        XCTAssertFalse(config.contains("status-items = cpu,load,memory,network"))
    }

    @MainActor func testGraphicalThemeEditorSavesColorsAndCancelPreservesConfig() throws {
        continueAfterFailure = false
        let previous = LatinInputSource.select()
        defer { LatinInputSource.restore(previous) }
        let stage = try makeStage()
        defer { try? FileManager.default.removeItem(at: stage) }
        let app = makeApp(stage)
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        openSettings(app)
        let settings = app.windows["Corta.Settings"]
        settings.outlines.firstMatch.staticTexts["Appearance"].click()
        settings.buttons["theme-create"].click()
        let name = app.textFields["theme-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        replace(name, text: "Midnight")
        let background = app.textFields["theme-hex-1"]
        replace(background, text: "#101018")
        attach(settings.screenshot(), name: "theme-editor")
        app.buttons["theme-save"].click()
        XCTAssertTrue(settings.buttons["theme-edit"].waitForExistence(timeout: 3))
        let config = try String(contentsOf: stage.appendingPathComponent("config"), encoding: .utf8)
        XCTAssertTrue(config.contains(".name = Midnight"))
        XCTAssertTrue(config.contains(".dark.background = #101018"))
        settings.buttons["theme-edit"].click()
        replace(app.textFields["theme-hex-1"], text: "not-a-color")
        XCTAssertFalse(app.buttons["theme-save"].isEnabled)
        app.buttons["Cancel"].click()
        XCTAssertEqual(try String(contentsOf: stage.appendingPathComponent("config"), encoding: .utf8), config)
        attach(settings.screenshot(), name: "settings-theme-editor")
        settings.buttons[XCUIIdentifierCloseWindow].click()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        openSettings(app)
        settings.outlines.firstMatch.staticTexts["Appearance"].click()
        XCTAssertTrue(settings.buttons["theme-edit"].waitForExistence(timeout: 3))
    }

    @MainActor func testMenuEntrypointsAndImmediateAppearancePreview() throws {
        continueAfterFailure = false
        let stage = try makeStage()
        defer { try? FileManager.default.removeItem(at: stage) }
        let app = makeApp(stage)
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let viewMenu = app.menuBars.firstMatch.menuBarItems["View"]
        viewMenu.click()
        viewMenu.menuItems["Theme editor…"].click()
        XCTAssertTrue(app.textFields["theme-name"].waitForExistence(timeout: 3))
        app.buttons["Cancel"].click()
        let settings = app.windows["Corta.Settings"]
        XCTAssertTrue(settings.staticTexts["supported-font"].exists)
        let mode = settings.popUpButtons["appearance-mode"]
        let preview = settings.descendants(matching: .any).matching(identifier: "appearance-preview").firstMatch
        mode.click()
        mode.menuItems["Dark"].click()
        XCTAssertEqual(preview.value as? String, "dark")
        mode.click()
        mode.menuItems["Light"].click()
        XCTAssertEqual(preview.value as? String, "light")
        attach(settings.screenshot(), name: "feedback-appearance")
        settings.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertFalse(app.buttons["system-status-bar"].exists)
        viewMenu.click()
        viewMenu.menuItems["Local host details…"].click()
        XCTAssertTrue(app.staticTexts["Local host details"].waitForExistence(timeout: 3))
        let chip = app.descendants(matching: .any).matching(identifier: "status.chip").firstMatch
        XCTAssertTrue(chip.exists)
        XCTAssertTrue((chip.label + " " + String(describing: chip.value)).contains("Apple"))
        app.buttons["Close"].click()
        XCTAssertTrue(settings.buttons["host-details"].exists)
    }

    @MainActor func testCompactStatusAndFeatureEntrancesInAllLanguages() throws {
        continueAfterFailure = false
        // Expected visible translations also catch untranslated compiled bundles.
        let translations: [(String, [String])] = [
            ("en", ["View", "Theme editor", "Local host details", "Cancel", "Local", "Load", "Memory", "Network", "Disk free", "Thermal state"]),
            ("zh-Hans", ["显示", "主题编辑器", "本机详情", "取消", "本机", "负载", "内存", "网络", "磁盘可用", "热状态"]),
            ("zh-Hant", ["檢視", "主題編輯器", "本機詳情", "取消", "本機", "負載", "記憶體", "網路", "磁碟可用", "熱狀態"]),
            ("ja", ["表示", "テーマエディタ", "ローカルホストの詳細", "キャンセル", "ローカル", "負荷", "メモリ", "ネットワーク", "ディスク空き容量", "熱状態"]),
            ("ko", ["보기", "테마 편집기", "로컬 호스트 정보", "취소", "로컬", "부하", "메모리", "네트워크", "디스크 여유 공간", "열 상태"]),
            ("de", ["Darstellung", "Themeneditor", "Lokale Hostdetails", "Abbrechen", "Lokal", "Last", "Speicher", "Netzwerk", "Freier Speicher", "Wärmezustand"]),
            ("fr", ["Présentation", "Éditeur de thème", "Détails de l’hôte local", "Annuler", "Local", "Charge", "Mémoire", "Réseau", "Disque libre", "État thermique"]),
            ("es", ["Visualización", "Editor de temas", "Detalles del equipo local", "Cancelar", "Local", "Carga", "Memoria", "Red", "Disco libre", "Estado térmico"]),
            ("pt-BR", ["Visualização", "Editor de temas", "Detalhes do host local", "Cancelar", "Local", "Carga", "Memória", "Rede", "Disco livre", "Estado térmico"]),
        ]
        for (language, labels) in translations {
            let stage = try makeStage()
            defer { try? FileManager.default.removeItem(at: stage) }
            try "appearance = light\nstatus-bar = true\nrestore-windows = false\ninput-source-indicator = off\n".write(
                to: stage.appendingPathComponent("config"), atomically: true, encoding: .utf8)
            let app = makeApp(stage)
            app.launchArguments = ["-AppleLanguages", "(\(language))"]
            app.launch()
            defer { app.terminate() }
            let bar = app.buttons["system-status-bar"]
            XCTAssertTrue(bar.waitForExistence(timeout: 10))
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                !(bar.value as? String ?? "CPU —").contains("CPU —")
            }, object: bar)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
            let value = bar.value as? String ?? ""
            for label in labels.dropFirst(4) {
                XCTAssertTrue(value.contains(label), value)
            }
            attach(app.windows.firstMatch.screenshot(), name: "compact-status-\(language)")
            let menu = app.menuBars.firstMatch.menuBarItems[labels[0]]
            menu.click()
            menu.menuItems[labels[1] + "…"].click()
            XCTAssertTrue(app.textFields["theme-name"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.staticTexts[labels[1]].exists)
            app.buttons[labels[3]].click()
            app.windows["Corta.Settings"].buttons[XCUIIdentifierCloseWindow].click()
            menu.click()
            menu.menuItems[labels[2] + "…"].click()
            XCTAssertTrue(app.staticTexts[labels[2]].waitForExistence(timeout: 3))
        }
    }

    @MainActor private func replace(_ field: XCUIElement, text: String) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }
    @MainActor private func openSettings(_ app: XCUIApplication) {
        let menu = app.menuBars.firstMatch.menuBarItems.element(boundBy: 1)
        menu.click()
        menu.menuItems["Settings…"].click()
        XCTAssertTrue(app.windows["Corta.Settings"].waitForExistence(timeout: 5))
    }
    private func makeStage() throws -> URL {
        let stage = URL(fileURLWithPath: "/private/tmp/corta-ui-stages", isDirectory: true).appendingPathComponent("corta-system-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try "appearance = light\nrestore-windows = false\ninput-source-indicator = off\n".write(
            to: stage.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "PROMPT='demo ❯ '\n".write(to: stage.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        return stage
    }
    @MainActor private func makeApp(_ stage: URL) -> XCUIApplication {
        // Multiple development checkouts share a bundle identifier. Launch the
        // app beside this test runner instead of Launch Services’ cached copy.
        let products = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let app = XCUIApplication(url: products.appendingPathComponent("CortaDev.app"))
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launchEnvironment["CORTA_STAGE_DIR"] = stage.path
        app.launchEnvironment["SHELL"] = "/bin/zsh"
        app.launchEnvironment["ZDOTDIR"] = stage.path
        return app
    }
    private func attach(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
