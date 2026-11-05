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

import SwiftUI

/// Settings share a sidebar, page header and grouped content surfaces. Every
/// control still writes through SettingsModel, including external config reloads.
struct SettingsView: View {
    @State var shortcutSearch = ""
    @State var themeEditor: ThemeEditorModel?
    @Bindable var model: SettingsModel
    let navigation: SettingsNavigation

    enum Category: String, CaseIterable, Identifiable {
        case general, appearance, themes, terminal, keyboardMouse, shortcuts
        case connections, privacy
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: L10n.text("settings.tab.general")
            case .appearance: L10n.text("settings.tab.appearance")
            case .themes: L10n.text("settings.tab.themes")
            case .terminal: L10n.text("settings.tab.terminal")
            case .keyboardMouse: L10n.text("settings.tab.keyboardMouse")
            case .shortcuts: L10n.text("settings.tab.shortcuts")
            case .connections: L10n.text("ui.category.connections")
            case .privacy: L10n.text("settings.tab.privacy")
            }
        }

        /// The sidebar tile behind the symbol, in System Settings' palette.
        var tileColor: Color {
            switch self {
            case .general: .gray
            case .appearance: .blue
            case .themes: .purple
            case .terminal: Color(white: 0.25)
            case .keyboardMouse: .blue
            case .shortcuts: .orange
            case .connections: .green
            case .privacy: .blue
            }
        }

        /// SF Symbols, so the sidebar follows the user's icon weight.
        var symbol: String {
            switch self {
            case .general: "gearshape.fill"
            case .appearance: "macwindow"
            case .themes: "paintpalette.fill"
            case .terminal: "terminal.fill"
            case .keyboardMouse: "keyboard.fill"
            case .shortcuts: "command"
            case .connections: "network"
            case .privacy: "hand.raised.fill"
            }
        }
    }

    var body: some View {
        let category = navigation.selection
        // A new identity per category, so each one opens at its top: a kept
        // page kept its scroll position too.
        page(category)
            .id(category)
            .safeAreaInset(edge: .top, spacing: 0) { saveBanner }
            .buttonBorderShape(.capsule)
            .frame(minWidth: 480, minHeight: 400)
            .sheet(item: $themeEditor) { editor in
                ThemeEditorView(editor: editor, previewFont: model.previewFont)
            }
            .onChange(of: navigation.themeEditorRequest) { _, _ in
                let dark = model.previewIsDark
                let source = Theme.named(model.configuration.themeName(dark: dark), in: model.configuration) ?? .corta
                let editor = ThemeEditorModel(source: source, editing: false)
                editor.isDark = dark
                editor.selectsForDark = dark
                themeEditor = editor
            }
            .sheet(
                isPresented: Binding(
                    get: { navigation.showHostDetails }, set: { navigation.showHostDetails = $0 })
            ) {
                VStack {
                    SystemStatusDetails(metrics: SystemMetricsStore.shared.snapshot, showMetrics: false)
                    Button(L10n.text("common.close")) { navigation.showHostDetails = false }
                        .keyboardShortcut(.cancelAction)
                }.padding(.bottom, 16)
            }
    }

    @ViewBuilder
    func page(_ category: Category) -> some View {
        switch category {
        case .general: generalPage
        case .appearance: appearancePage
        case .themes: themesPage
        case .terminal: terminalPage
        case .keyboardMouse: keyboardMousePage
        case .shortcuts: shortcutsPage
        case .connections: PresetSettingsView(model: model)
        case .privacy: privacyPage
        }
    }

    @ViewBuilder
    private var saveBanner: some View {
        if model.saveStatus.kind == .failed || model.saveStatus.kind == .adjusted {
            StatusRowView(
                status: model.saveStatus,
                action: Self.action(if: model.saveStatus.kind == .failed) { model.retryWrite() }
            )
            .padding(.horizontal, 24).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }
}

// MARK: - Appearance

extension SettingsView {

    // MARK: - Terminal

    private var terminalPage: some View {
        SettingsPage {
            SettingsSection(L10n.text("settings.section.output")) {
                LabeledContent(L10n.text("settings.label.scrollback")) {
                    numberField(bind(model.scrollbackLines, model.setScrollbackLines), width: 92)
                }
                .help(L10n.text("settings.help.scrollback"))
                LabeledContent(L10n.text("ui.history.commands")) {
                    numberField(bind(model.commandHistoryLimit, model.setCommandHistoryLimit), width: 92)
                }
                .help(L10n.text("ui.history.newSessions"))
                Picker(L10n.text("settings.label.ambiguousWidth"), selection: bind(\.ambiguousWidth)) {
                    ForEach(Configuration.AmbiguousWidth.allCases, id: \.self) { width in
                        Text(L10n.text("settings.ambiguousWidth.\(width.rawValue)")).tag(width)
                    }
                }
                .accessibilityIdentifier("ambiguous-width")
                .help(L10n.text("settings.help.ambiguousWidth"))
                Picker(L10n.text("settings.label.bell"), selection: bind(\.bell)) {
                    ForEach(SettingsModel.bellModes, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }
            SettingsSection(L10n.text("ui.section.search")) {
                Toggle(L10n.text("ui.search.case"), isOn: bind(\.searchCaseSensitive))
                Toggle(L10n.text("ui.search.regex"), isOn: bind(\.searchRegex))
            }
            SettingsSection(L10n.text("settings.section.shell")) {
                Toggle(L10n.text("settings.label.historySuggestions"), isOn: bind(\.historySuggestions))
                    .help(L10n.text("settings.help.historySuggestions"))
                Toggle(L10n.text("settings.label.directoryCompletion"), isOn: bind(\.directoryCompletion))
                    .help(L10n.text("settings.help.directoryCompletion"))
                Toggle(L10n.text("settings.label.commandStatusMarks"), isOn: bind(\.commandStatusMarks))
                LabeledContent(L10n.text("settings.label.openFileCommand")) {
                    OpenFileCommandField(model: model).frame(maxWidth: 240)
                }
                .help(L10n.text("settings.help.openFileCommand"))
                LabeledContent(L10n.text("settings.label.shellIntegration")) {
                    StatusRowView(
                        status: model.shellIntegrationStatus, action: model.toggleShellIntegration,
                        secondaryAction: model.removeShellIntegration)
                }
                .help(L10n.text("settings.help.shellIntegration"))
            }
        }
    }

    // MARK: - Keyboard & Mouse

    private var keyboardMousePage: some View {
        SettingsPage {
            SettingsSection(L10n.text("inputSource.settings.title")) {
                Picker(L10n.text("inputSource.settings.display"), selection: bind(\.inputSourceIndicator)) {
                    ForEach(Configuration.InputSourceIndicatorMode.allCases, id: \.self) { mode in
                        Text(L10n.text("inputSource.mode.\(mode.rawValue)")).tag(mode)
                    }
                }
                .accessibilityIdentifier("input-source-indicator-mode")
                .help(L10n.text("inputSource.settings.help"))
                Picker(
                    L10n.text("inputSource.settings.position"),
                    selection: bind(\.inputSourceIndicatorPosition)
                ) {
                    ForEach(Configuration.InputSourceIndicatorPosition.allCases, id: \.self) { position in
                        Text(L10n.text("inputSource.position.\(position.rawValue)")).tag(position)
                    }
                }
                .accessibilityIdentifier("input-source-indicator-position")
                InputSourceColorField(value: model.inputSourceDirectColor, direct: true, model: model)
                InputSourceColorField(value: model.inputSourceIMEColor, direct: false, model: model)
            }
            SettingsSection(L10n.text("settings.section.keyboard")) {
                Toggle(
                    L10n.text("settings.label.optionAsMeta"),
                    isOn: bind(\.optionAsMeta)
                )
                .help(L10n.text("settings.help.optionAsMeta"))
                Picker(L10n.text("settings.label.pasteWarning"), selection: bind(\.pasteWarning)) {
                    ForEach(Configuration.PasteWarning.allCases, id: \.self) { mode in
                        Text(L10n.text("settings.pasteWarning.\(mode.rawValue)")).tag(mode)
                    }
                }
                .accessibilityIdentifier("paste-warning")
                .help(L10n.text("settings.help.pasteWarning"))
            }
            SettingsSection(L10n.text("settings.section.mouse")) {
                Picker(
                    L10n.text("settings.label.openLinksWith"), selection: bind(\.linkActivation)
                ) {
                    Text(L10n.text("settings.linkActivation.commandClick"))
                        .tag(Configuration.LinkActivation.command)
                    Text(L10n.text("settings.linkActivation.click"))
                        .tag(Configuration.LinkActivation.click)
                }
                Picker(L10n.text("ui.mouse.override"), selection: bind(\.mouseOverrideModifier)) {
                    ForEach(Configuration.MouseOverrideModifier.allCases, id: \.self) { value in
                        Text(
                            verbatim: value == .option ? "⌥ Option" : value == .shift ? "⇧ Shift" : "⌃ Control"
                        )
                        .tag(value)
                    }
                }
                Toggle(
                    L10n.text("settings.label.copyOnSelect"),
                    isOn: bind(\.copyOnSelect))
                Toggle(L10n.text("settings.label.focusFollowsMouse"), isOn: bind(\.focusFollowsMouse))
                    .accessibilityIdentifier("focus-follows-mouse")
                    .help(L10n.text("settings.help.focusFollowsMouse"))
            }
        }
    }

    // MARK: - Privacy & Security

    /// What can reach beyond the terminal: the clipboard, other apps'
    /// view of the keyboard, and what Corta remembers on disk.
    private var privacyPage: some View {
        SettingsPage {
            SettingsSection(
                L10n.text("settings.section.clipboard"), summary: L10n.text("settings.help.allowClipboardCopy")
            ) {
                Toggle(
                    L10n.text("settings.label.allowClipboardCopy"),
                    isOn: bind(\.allowClipboardWrite)
                )
                .help(L10n.text("settings.help.allowClipboardCopy"))
            }
            SettingsSection(
                L10n.text("settings.section.keyboard"), summary: L10n.text("settings.help.secureKeyboardEntry")
            ) {
                Toggle(
                    L10n.text("command.secureKeyboardEntry"),
                    isOn: bind(\.secureKeyboardEntry)
                )
                .help(L10n.text("settings.help.secureKeyboardEntry"))
            }
            historySection
        }
    }

    // MARK: - General

    private var generalPage: some View {
        SettingsPage {
            windowSection
            SettingsSection(L10n.text("settings.section.closing")) {
                Toggle(
                    L10n.text("settings.label.confirmClose"),
                    isOn: bind(\.confirmClose)
                )
                .help(L10n.text("settings.help.confirmClose"))
            }
            SettingsSection(L10n.text("settings.section.panes")) {
                Toggle(L10n.text("settings.label.autoBalancePanes"), isOn: bind(\.autoBalancePanes))
                    .accessibilityIdentifier("auto-balance-panes")
                    .help(L10n.text("settings.help.autoBalancePanes"))
                Toggle(L10n.text("settings.label.bestFitSplit"), isOn: bind(\.bestFitSplit))
                    .accessibilityIdentifier("best-fit-split")
                    .help(L10n.text("settings.help.bestFitSplit"))
            }
            notificationsSection
            if UpdateController.isAvailable {
                SettingsSection(L10n.text("ui.section.updates")) {
                    Toggle(L10n.text("ui.update.auto"), isOn: bind(\.updateAutoCheck))
                    Toggle(L10n.text("ui.update.applications"), isOn: bind(\.suggestApplicationsFolder))
                }
            }
            configurationSection
        }
    }

    // MARK: - Helpers

    /// A binding that reads the model's current value and writes through
    /// one of its setters — the shape every control on this page has, so a
    /// clamped or refused value reflects back from the store rather than
    /// sticking in the control.
    ///
    /// The setter is wrapped rather than passed through: `Binding` wants a
    /// `@Sendable` closure, and a bound `SettingsModel` method is
    /// main-actor-isolated — handing it over directly is a warning today
    /// and an error once the isolation is checked strictly.
    func bind<Value>(_ value: Value, _ set: @escaping (Value) -> Void) -> Binding<Value> {
        Binding(get: { value }, set: { set($0) })
    }

    /// A control over one configuration field, written as given.
    func bind<Value>(_ path: WritableKeyPath<Configuration, Value>) -> Binding<Value> {
        Binding(get: { model.configuration[keyPath: path] }, set: { model.set(path, $0) })
    }

    /// A right-aligned numeric field. `TextField(value:format:)` writes its
    /// binding on commit (Return or focus loss), not per keystroke, so a
    /// half-typed number never reaches the store.
    ///
    /// `labelsHidden`, because the field's empty title is still a label: the
    /// grouped form laid it out as a second, blank line under the field,
    /// which made every field row 11pt taller than a toggle row and sat the
    /// "×" and "seconds" beside it 5pt below the field's own baseline.
    func numberField(_ value: Binding<Int>, width: CGFloat) -> some View {
        TextField("", value: value, format: .number)
            .labelsHidden()
            .frame(width: width)
            .multilineTextAlignment(.trailing)
    }

    func numberField(_ value: Binding<Double>, width: CGFloat) -> some View {
        TextField("", value: value, format: .number)
            .labelsHidden()
            .frame(width: width)
            .multilineTextAlignment(.trailing)
    }

    /// `condition ? closure : nil`, spelled so the compiler doesn't have to
    /// unify a bound-method reference and `nil` inside a ternary.
    static func action(if condition: Bool, _ closure: @escaping () -> Void)
        -> (() -> Void)?
    {
        condition ? closure : nil
    }

    var configurationSection: some View {
        SettingsSection(L10n.text("settings.config.title")) {
            HStack(spacing: 16) {
                Text(model.pathLabel).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(model.pathLabel)
                    .accessibilityLabel(L10n.text("settings.footer.pathLabel"))
                Spacer(minLength: 12)
                Button(L10n.text("settings.footer.reveal")) { model.revealConfigFile() }
            }
        }
    }
}
