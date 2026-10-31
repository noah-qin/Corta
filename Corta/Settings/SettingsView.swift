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

/// The settings page, in SwiftUI.
///
/// **Shape.** A sidebar of categories beside one grouped form, the way
/// System Settings is built on macOS 26: the sidebar is the Liquid Glass
/// layer, the form is content. Three tabs had grown to eight sections under
/// General alone; a sidebar holds as many categories as the settings need
/// without a tab bar outgrowing the window. `Form`/`LabeledContent` give
/// correct label-control accessibility pairing and localization-aware
/// wrapping natively.
///
/// **Form style.** Grouped, the System Settings look. A row is as tall as
/// its control plus the style's own inset; an empty `TextField` title
/// still lays out as a blank second line, 11pt taller, which is why
/// `numberField` hides it.
///
/// Every control writes through `SettingsModel`'s setters, which write the
/// config file and re-read it. Nothing here holds state of its own — the
/// model re-populates from the store on `ConfigurationStore.didChange`, so
/// an edit made in `$EDITOR` while this window is open moves the controls,
/// and the two directions cannot disagree. The one exception is the
/// open-file command's draft (`OpenFileCommandField`), which is validated
/// on commit rather than per keystroke.
struct SettingsView: View {
    @State private var themeEditor: ThemeEditorModel?
    @Bindable var model: SettingsModel
    let navigation: SettingsNavigation

    enum Category: String, CaseIterable, Identifiable {
        case general, appearance, terminal, keyboardMouse, shortcuts, quickTerminal
        case connections, space, privacy
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: L10n.text("settings.tab.general")
            case .appearance: L10n.text("settings.tab.appearance")
            case .terminal: L10n.text("settings.tab.terminal")
            case .keyboardMouse: L10n.text("settings.tab.keyboardMouse")
            case .shortcuts: L10n.text("settings.tab.shortcuts")
            case .quickTerminal: L10n.text("settings.section.quickTerminal")
            case .connections: L10n.text("ui.category.connections")
            case .space: L10n.text("settings.section.space")
            case .privacy: L10n.text("settings.tab.privacy")
            }
        }

        /// The sidebar tile behind the symbol, in System Settings' palette.
        var tileColor: Color {
            switch self {
            case .general: .gray
            case .appearance: .indigo
            case .terminal: Color(white: 0.25)
            case .keyboardMouse: .blue
            case .shortcuts: .orange
            case .quickTerminal: .teal
            case .connections: .green
            case .space: .indigo
            case .privacy: .blue
            }
        }

        /// SF Symbols, so the sidebar follows the user's icon weight.
        var symbol: String {
            switch self {
            case .general: "gearshape.fill"
            case .appearance: "paintpalette.fill"
            case .terminal: "terminal.fill"
            case .keyboardMouse: "keyboard.fill"
            case .shortcuts: "command"
            case .quickTerminal: "rectangle.topthird.inset.filled"
            case .connections: "network"
            case .space: "square.grid.2x2.fill"
            case .privacy: "hand.raised.fill"
            }
        }
    }

    var body: some View {
        let category = navigation.selection
        // A new identity per category, so each one opens at its top: a kept
        // page kept its scroll position too.
        page(category)
            .formStyle(.grouped)
            .id(category)
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .frame(minWidth: 460, minHeight: 400)
            .onChange(of: navigation.themeEditorRequest) { _, _ in
                themeEditor = ThemeEditorModel(source: model.previewTheme, editing: false)
            }
            .sheet(isPresented: Binding(
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
        case .terminal: terminalPage
        case .keyboardMouse: keyboardMousePage
        case .shortcuts: shortcutsPage
        case .quickTerminal: Form { quickTerminalSection }
        case .connections: PresetSettingsView(model: model)
        case .space: spacePage
        case .privacy: privacyPage
        }
    }

    /// Under every page: a failed write, said where it will be seen, and
    /// where the settings live.
    private var bottomBar: some View {
        VStack(spacing: 0) {
            if model.saveStatus.kind != .none {
                StatusRowView(
                    status: model.saveStatus,
                    action: Self.action(if: model.saveStatus.kind == .failed) { model.retryWrite() }
                )
                .padding(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
            Divider()
            footer
        }
        .background(.bar)
    }

}

// MARK: - Appearance

extension SettingsView {

    private var appearancePage: some View {
        Form {
            if model.listedThemes.count >= 2 {
                Picker(L10n.text("settings.label.theme"), selection: bind(\.theme)) {
                    ForEach(model.listedThemes, id: \.name) { theme in
                        Text(theme.displayName).tag(theme.name)
                    }
                }
                .accessibilityIdentifier("appearance-theme")
            }
            HStack {
                Button(L10n.text("theme.create")) {
                    themeEditor = ThemeEditorModel(source: model.previewTheme, editing: false)
                }.accessibilityIdentifier("theme-create")
                if ConfigurationStore.shared.configuration.customThemes.contains(where: { $0.name == model.theme }) {
                    Button(L10n.text("theme.edit")) {
                        themeEditor = ThemeEditorModel(source: model.previewTheme, editing: true)
                    }.accessibilityIdentifier("theme-edit")
                }
            }
            Picker(L10n.text("settings.label.lightOrDark"), selection: bind(\.appearance)) {
                ForEach(Configuration.Appearance.allCases, id: \.self) { appearance in
                    Text(
                        appearance == .auto
                            ? L10n.text("settings.appearance.followSystem")
                            : L10n.text("settings.appearance.\(appearance.rawValue)")
                    ).tag(appearance)
                }
            }
            .accessibilityIdentifier("appearance-mode")

            FontFamilyPicker(
                title: L10n.text("settings.label.font"), selection: bind(model.fontFamily, model.setFontFamily),
                defaultTag: Configuration.systemFontFamily,
                defaultLabel: L10n.text("settings.font.systemMonospaced"), entries: model.availableFonts)
            .accessibilityIdentifier("font-family")
            .help(L10n.text("settings.help.font"))
            .task { await model.loadFonts() }
            if !model.fontDetail.isEmpty {
                Text(model.fontDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("font-detail")
            }
            if model.fontStatus.kind != .none {
                LabeledContent(L10n.text("settings.label.fontStatus")) {
                    StatusRowView(
                        status: model.fontStatus,
                        action: Self.action(if: model.fontStatus.kind == .failed) {
                            model.retryFontResolution()
                        })
                }
            }
            FontFamilyPicker(
                title: L10n.text("settings.label.cjkFont"),
                selection: bind(model.cjkFontFamily, model.setCJKFontFamily),
                defaultTag: Configuration.automaticCJKFontFamily,
                defaultLabel: L10n.text("settings.font.cjkAutomatic"), entries: model.availableCJKFonts)
            .accessibilityIdentifier("font-family-cjk")
            .help(L10n.text("settings.help.cjkFont"))
            // Fallback off draws only the font: the CJK font would never be used.
            .disabled(!model.fontFallback)
            if !model.cjkFontNotice.isEmpty {
                Text(model.cjkFontNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("cjk-font-notice")
            }
            LabeledContent(L10n.text("settings.label.size")) {
                Stepper(value: bind(model.fontSize, model.setFontSize), in: Configuration.fontSizeRange) {
                    Text(model.fontSize, format: .number)
                }
            }
            Picker(L10n.text("settings.label.fontWeight"), selection: bind(\.fontWeight)) {
                ForEach(Configuration.FontWeight.allCases, id: \.self) { weight in
                    Text(L10n.text("settings.fontWeight.\(weight.rawValue)")).tag(weight)
                }
            }
            .accessibilityIdentifier("font-weight")
            .help(L10n.text("settings.help.fontWeight"))
            LabeledContent(L10n.text("settings.label.lineSpacing")) {
                Stepper(
                    value: bind(model.lineSpacing, model.setLineSpacing), in: Configuration.lineSpacingRange,
                    step: Configuration.lineSpacingStep
                ) {
                    Text(model.lineSpacing, format: .number.precision(.fractionLength(2)))
                }
            }
            .accessibilityIdentifier("line-spacing")
            Toggle(L10n.text("settings.label.fontFallback"), isOn: bind(\.fontFallback))
                .accessibilityIdentifier("font-fallback")
            Picker(L10n.text("settings.label.emojiRendering"), selection: bind(\.emojiRendering)) {
                ForEach(Configuration.EmojiRendering.allCases, id: \.self) { mode in
                    Text(L10n.text("settings.emojiRendering.\(mode.rawValue)")).tag(mode)
                }
            }
            .accessibilityIdentifier("emoji-rendering")
            Section(L10n.text("settings.section.cursor")) {
                Picker(L10n.text("settings.label.cursorShape"), selection: bind(\.cursorShape)) {
                    ForEach(Configuration.CursorShape.allCases, id: \.self) { shape in
                        Text(L10n.text("settings.cursor.\(shape.rawValue)")).tag(shape)
                    }
                }
                .accessibilityIdentifier("cursor-shape")
                Toggle(L10n.text("settings.label.cursorBlink"), isOn: bind(\.cursorBlink))
                    .accessibilityIdentifier("cursor-blink")
                    .help(L10n.text("settings.help.cursor"))
                LabeledContent(L10n.text("settings.label.preview")) {
                    FontPreviewSwiftUIView(
                        theme: model.previewTheme, font: model.previewFont, isDark: model.previewIsDark,
                        cursorStyle: model.cursorShape.style(blinking: model.cursorBlink))
                        .accessibilityIdentifier("appearance-preview")
                        .accessibilityValue(model.previewIsDark ? "dark" : "light")
                }
            }
        }
        .sheet(item: $themeEditor) { editor in
            ThemeEditorView(editor: editor, previewFont: model.previewFont)
        }
    }

    // MARK: - Terminal

    private var terminalPage: some View {
        Form {
            Section(L10n.text("status.settings")) {
                Button(L10n.text("status.details")) { navigation.showHostDetails = true }
                    .accessibilityIdentifier("host-details")
                Toggle(L10n.text("status.enable"), isOn: bind(\.statusBar))
                    .accessibilityIdentifier("status-bar-enable")
                ForEach(SystemMetrics.Item.allCases, id: \.self) { item in
                    Toggle(L10n.text("status.item.\(item.rawValue)"), isOn: Binding(
                        get: { model.statusItems.contains(item) },
                        set: { model.setStatusItem(item, enabled: $0) }))
                        .disabled(!model.statusBar)
                        .accessibilityIdentifier("status-item-\(item.rawValue)")
                }
                StatusNetworkInterfaceField(model: model).disabled(!model.statusBar)
                Text(L10n.text("status.settings.help")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.text("settings.section.output")) {
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
            Section(L10n.text("ui.section.search")) {
                Toggle(L10n.text("ui.search.case"), isOn: bind(\.searchCaseSensitive))
                Toggle(L10n.text("ui.search.regex"), isOn: bind(\.searchRegex))
            }
            Section(L10n.text("settings.section.shell")) {
                Toggle(L10n.text("settings.label.historySuggestions"), isOn: bind(\.historySuggestions))
                    .help(L10n.text("settings.help.historySuggestions"))
                Toggle(L10n.text("settings.label.directoryCompletion"), isOn: bind(\.directoryCompletion))
                    .help(L10n.text("settings.help.directoryCompletion"))
                Toggle(L10n.text("settings.label.commandStatusMarks"), isOn: bind(\.commandStatusMarks))
                LabeledContent(L10n.text("settings.label.openFileCommand")) {
                    OpenFileCommandField(model: model)
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
        Form {
            Section(L10n.text("inputSource.settings.title")) {
                Picker(L10n.text("inputSource.settings.display"), selection: bind(\.inputSourceIndicator)) {
                    ForEach(Configuration.InputSourceIndicatorMode.allCases, id: \.self) { mode in
                        Text(L10n.text("inputSource.mode.\(mode.rawValue)")).tag(mode)
                    }
                }
                .accessibilityIdentifier("input-source-indicator-mode")
                .help(L10n.text("inputSource.settings.help"))
                Picker(L10n.text("inputSource.settings.position"), selection: bind(\.inputSourceIndicatorPosition)) {
                    ForEach(Configuration.InputSourceIndicatorPosition.allCases, id: \.self) { position in
                        Text(L10n.text("inputSource.position.\(position.rawValue)")).tag(position)
                    }
                }
                .accessibilityIdentifier("input-source-indicator-position")
                InputSourceColorField(value: model.inputSourceDirectColor, direct: true, model: model)
                InputSourceColorField(value: model.inputSourceIMEColor, direct: false, model: model)
            }
            Section(L10n.text("settings.section.keyboard")) {
                Toggle(
                    L10n.text("settings.label.optionAsMeta"),
                    isOn: bind(\.optionAsMeta)
                )
                .help(L10n.text("settings.help.optionAsMeta"))
            }
            Section(L10n.text("settings.section.mouse")) {
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
                        Text(verbatim: value == .option ? "⌥ Option" : value == .shift ? "⇧ Shift" : "⌃ Control")
                            .tag(value)
                    }
                }
                Toggle(
                    L10n.text("settings.label.copyOnSelect"),
                    isOn: bind(\.copyOnSelect))
            }
        }
    }

    // MARK: - Privacy & Security

    /// What can reach beyond the terminal: the clipboard, other apps'
    /// view of the keyboard, and what Corta remembers on disk.
    private var privacyPage: some View {
        Form {
            Section(L10n.text("settings.section.clipboard")) {
                Toggle(
                    L10n.text("settings.label.allowClipboardCopy"),
                    isOn: bind(\.allowClipboardWrite)
                )
                .help(L10n.text("settings.help.allowClipboardCopy"))
            }
            Section(L10n.text("settings.section.keyboard")) {
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

    // MARK: - Footer

    /// One line under a hairline: where the settings live, and a way to get
    /// there.
    private var footer: some View {
        HStack(spacing: 8) {
            Text(model.pathLabel)
                .font(.system(size: NSFont.smallSystemFontSize))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(L10n.text("settings.footer.tooltip"))
                .accessibilityLabel(L10n.text("settings.footer.pathLabel"))
            Spacer()
            Button(L10n.text("settings.footer.reveal")) { model.revealConfigFile() }
                .buttonStyle(.accessoryBarAction)
                .controlSize(.small)
        }
        .padding(EdgeInsets(top: 8, leading: 16, bottom: 11, trailing: 16))
    }
}
