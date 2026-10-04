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
/// The sidebar's selection, shared by the sidebar, the page and the window
/// controller (which names the window after it).
@MainActor @Observable
final class SettingsNavigation {
    var selection: SettingsView.Category = .general
}

/// The category list. AppKit hosts it as the split view's sidebar item, which
/// is what gives it the floating Liquid Glass sidebar; SwiftUI's own
/// `NavigationSplitView` inside a hosting controller drew a flush, opaque one.
struct SettingsSidebar: View {
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        List(
            SettingsView.Category.allCases,
            selection: Binding(
                get: { navigation.selection },
                set: { if let category = $0 { navigation.selection = category } })
        ) { category in
            SettingsSidebarRow(category: category).tag(category)
        }
        .listStyle(.sidebar)
    }
}

/// A sidebar row the way System Settings draws one: the symbol white on a
/// coloured rounded tile, then the name. Explicit colours rather than a
/// `Label`'s accent tint — the tinted icons disappeared and came back for a
/// few frames each time the window opened and became key.
private struct SettingsSidebarRow: View {
    let category: SettingsView.Category

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: category.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(category.tileColor.gradient, in: .rect(cornerRadius: 6))
                .accessibilityHidden(true)
            Text(category.title)
        }
    }
}

struct SettingsView: View {
    @Bindable var model: SettingsModel
    let navigation: SettingsNavigation

    enum Category: String, CaseIterable, Identifiable {
        case general, appearance, terminal, keyboardMouse, shortcuts, quickTerminal
        case connections, privacy
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
            .task { await model.loadFonts() }
    }

    @ViewBuilder
    private func page(_ category: Category) -> some View {
        switch category {
        case .general: generalPage
        case .appearance: appearancePage
        case .terminal: terminalPage
        case .keyboardMouse: keyboardMousePage
        case .shortcuts: shortcutsPage
        case .quickTerminal: Form { quickTerminalSection }
        case .connections: PresetSettingsView(model: model)
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

    // MARK: - Appearance

    private var appearancePage: some View {
        Form {
            if model.listedThemes.count >= 2 {
                Picker(L10n.text("settings.label.theme"), selection: $model.theme) {
                    ForEach(model.listedThemes, id: \.name) { theme in
                        Text(theme.displayName).tag(theme.name)
                    }
                }
                .onChange(of: model.theme) { _, value in model.setTheme(value) }
            }
            Picker(L10n.text("settings.label.lightOrDark"), selection: $model.appearance) {
                ForEach(Configuration.Appearance.allCases, id: \.self) { appearance in
                    Text(
                        appearance == .auto
                            ? L10n.text("settings.appearance.followSystem")
                            : L10n.text("settings.appearance.\(appearance.rawValue)")
                    ).tag(appearance)
                }
            }
            .onChange(of: model.appearance) { _, value in model.setAppearance(value) }

            Picker(L10n.text("settings.label.font"), selection: bind(model.fontFamily, model.setFontFamily)) {
                Text(L10n.text("settings.font.systemMonospaced")).tag(Configuration.systemFontFamily)
                if model.fontFamily != Configuration.systemFontFamily && !model.availableFonts.contains(model.fontFamily) {
                    Text(model.fontFamily).tag(model.fontFamily)
                }
                ForEach(model.availableFonts, id: \.self) { Text($0).tag($0) }
            }
            .help(L10n.text("settings.help.font"))
            // Only when there is something to say: a resolved font used to
            // leave an empty row here.
            if model.fontStatus.kind != .none {
                LabeledContent(L10n.text("settings.label.fontStatus")) {
                    StatusRowView(
                        status: model.fontStatus,
                        action: Self.action(if: model.fontStatus.kind == .failed) {
                            model.retryFontResolution()
                        })
                }
            }
            LabeledContent(L10n.text("settings.label.size")) {
                Stepper(value: bind(model.fontSize, model.setFontSize), in: 8...64) {
                    Text(model.fontSize, format: .number)
                }
            }
            LabeledContent(L10n.text("settings.label.preview")) {
                FontPreviewSwiftUIView(theme: model.previewTheme, font: model.previewFont, isDark: AppearanceController.shared.isDark)
            }
        }
    }

    // MARK: - Terminal

    private var terminalPage: some View {
        Form {
            Section(L10n.text("settings.section.output")) {
                LabeledContent(L10n.text("settings.label.scrollback")) {
                    numberField(bind(model.scrollbackLines, model.setScrollbackLines), width: 92)
                }
                .help(L10n.text("settings.help.scrollback"))
                LabeledContent(L10n.text("ui.history.commands")) {
                    numberField(bind(model.commandHistoryLimit, model.setCommandHistoryLimit), width: 92)
                }
                .help(L10n.text("ui.history.newSessions"))
                Picker(L10n.text("settings.label.bell"), selection: $model.bell) {
                    ForEach(SettingsModel.bellModes, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: model.bell) { _, value in model.setBell(value) }
            }
            Section(L10n.text("ui.section.search")) {
                Toggle(L10n.text("ui.search.case"), isOn: bind(model.searchCaseSensitive, model.setSearchCaseSensitive))
                Toggle(L10n.text("ui.search.regex"), isOn: bind(model.searchRegex, model.setSearchRegex))
            }
            Section(L10n.text("settings.section.shell")) {
                Toggle(L10n.text("settings.label.directoryCompletion"), isOn: bind(model.directoryCompletion, model.setDirectoryCompletion))
                    .help(L10n.text("settings.help.directoryCompletion"))
                Toggle(L10n.text("settings.label.commandStatusMarks"), isOn: bind(model.commandStatusMarks, model.setCommandStatusMarks))
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
            Section(L10n.text("settings.section.keyboard")) {
                Toggle(
                    L10n.text("settings.label.optionAsMeta"),
                    isOn: bind(model.optionAsMeta, model.setOptionAsMeta)
                )
                .help(L10n.text("settings.help.optionAsMeta"))
            }
            Section(L10n.text("settings.section.mouse")) {
                Picker(
                    L10n.text("settings.label.openLinksWith"), selection: $model.linkActivation
                ) {
                    Text(L10n.text("settings.linkActivation.commandClick"))
                        .tag(Configuration.LinkActivation.command)
                    Text(L10n.text("settings.linkActivation.click"))
                        .tag(Configuration.LinkActivation.click)
                }
                .onChange(of: model.linkActivation) { _, value in model.setLinkActivation(value) }
                Picker(L10n.text("ui.mouse.override"), selection: bind(model.mouseOverrideModifier, model.setMouseOverrideModifier)) {
                    ForEach(Configuration.MouseOverrideModifier.allCases, id: \.self) { value in
                        Text(verbatim: value == .option ? "⌥ Option" : value == .shift ? "⇧ Shift" : "⌃ Control").tag(value)
                    }
                }
                Toggle(
                    L10n.text("settings.label.copyOnSelect"),
                    isOn: bind(model.copyOnSelect, model.setCopyOnSelect))
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
                    isOn: bind(model.allowClipboardWrite, model.setAllowClipboardWrite)
                )
                .help(L10n.text("settings.help.allowClipboardCopy"))
            }
            Section(L10n.text("settings.section.keyboard")) {
                Toggle(
                    L10n.text("command.secureKeyboardEntry"),
                    isOn: bind(model.secureKeyboardEntry, model.setSecureKeyboardEntry)
                )
                .help(L10n.text("settings.help.secureKeyboardEntry"))
            }
            historySection
        }
    }

    // MARK: - General

    private var generalPage: some View {
        Form {
            windowSection
            Section(L10n.text("settings.section.closing")) {
                Toggle(
                    L10n.text("settings.label.confirmClose"),
                    isOn: bind(model.confirmClose, model.setConfirmClose)
                )
                .help(L10n.text("settings.help.confirmClose"))
            }
            notificationsSection
            if UpdateController.isAvailable {
                Section(L10n.text("ui.section.updates")) {
                    Toggle(L10n.text("ui.update.auto"), isOn: bind(model.updateAutoCheck, model.setUpdateAutoCheck))
                    Toggle(L10n.text("ui.update.applications"), isOn: bind(model.suggestApplicationsFolder, model.setSuggestApplicationsFolder))
                }
            }
        }
    }

    // MARK: - Shortcuts

    /// Every command's key, in the menu order; written as `bind.` keys.
    private var shortcutsPage: some View {
        Form {
            Section(L10n.text("settings.section.commands")) {
                ForEach(TerminalCommand.allCases, id: \.self) { command in
                    LabeledContent(command.title) {
                        HStack(spacing: 6) {
                            ShortcutRecorder(value: model.keybindings[command], onChange: { model.setShortcut($0, for: command) })
                            // Only where there is something to restore; the
                            // slot stays, so the recorders line up.
                            let isDefault = model.keybindings[command] == command.defaultShortcut
                            Button {
                                model.resetShortcut(command)
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                            }
                            .buttonStyle(.borderless)
                            .help(L10n.text("ui.shortcut.reset"))
                            .accessibilityLabel(L10n.text("ui.shortcut.reset"))
                            .opacity(isDefault ? 0 : 1)
                            .disabled(isDefault)
                            .accessibilityHidden(isDefault)
                        }
                    }
                }
            }
        }
    }

    private var windowSection: some View {
        Section(L10n.text("settings.section.window")) {
            LabeledContent(L10n.text("settings.label.newWindow")) {
                HStack(spacing: 6) {
                    numberField(bind(model.columns, model.setColumns), width: 54)
                    Text(verbatim: "×").foregroundStyle(.secondary)
                    numberField(bind(model.rows, model.setRows), width: 54)
                }
            }
            .help(L10n.text("settings.help.newWindow"))
            Toggle(
                L10n.text("settings.label.restoreWindows"),
                isOn: bind(model.restoreWindows, model.setRestoreWindows))
        }
    }

    /// Untitled: it is the whole page, and the page already says its name.
    private var quickTerminalSection: some View {
        Section {
            Toggle(
                L10n.text("settings.label.quickTerminalHotkey"),
                isOn: bind(model.quickTerminal, model.setQuickTerminal)
            )
            .help(L10n.text("settings.help.quickTerminal"))
            LabeledContent(L10n.text("ui.shortcut.global")) {
                ShortcutRecorder(value: model.quickTerminalKey, onChange: model.setQuickTerminalKey)
            }
            // The switch already says "off"; the row is for which key, or
            // why none.
            if model.quickTerminalStatus.kind != .none {
                StatusRowView(status: model.quickTerminalStatus)
            }
            Picker(
                L10n.text("settings.label.quickTerminalPosition"),
                selection: $model.quickTerminalPosition
            ) {
                ForEach(Configuration.QuickTerminalPosition.allCases, id: \.self) { position in
                    Text(L10n.text("settings.quickTerminalPosition.\(position.rawValue)"))
                        .tag(position)
                }
            }
            .onChange(of: model.quickTerminalPosition) { _, value in
                model.setQuickTerminalPosition(value)
            }
            Picker(
                L10n.text("settings.label.quickTerminalScreen"),
                selection: $model.quickTerminalScreen
            ) {
                ForEach(Configuration.QuickTerminalScreen.allCases, id: \.self) { screen in
                    Text(L10n.text("settings.quickTerminalScreen.\(screen.rawValue)")).tag(screen)
                }
            }
            .onChange(of: model.quickTerminalScreen) { _, value in
                model.setQuickTerminalScreen(value)
            }
        }
    }

    private var notificationsSection: some View {
        Section(L10n.text("settings.section.notifications")) {
            Toggle(
                L10n.text("settings.label.notifyOnLongTasks"),
                isOn: bind(model.notifyOnLongTask, model.setNotifyOnLongTask)
            )
            .help(L10n.text("settings.help.notifyOnLongTasks"))
            if model.notificationPermissionNotice.kind != .none {
                StatusRowView(
                    status: model.notificationPermissionNotice,
                    action: model.openSystemNotificationSettings)
            }
            LabeledContent(L10n.text("settings.label.longerThan")) {
                HStack(spacing: 6) {
                    numberField(
                        bind(model.notificationThreshold, model.setNotificationThreshold),
                        width: 54)
                    Text(L10n.text("settings.label.seconds")).foregroundStyle(.secondary)
                }
            }
            .disabled(!model.notifyOnLongTask)
        }
    }

    private var historySection: some View {
        Section(L10n.text("settings.section.history")) {
            Toggle(
                L10n.text("settings.label.directoryHistory"),
                isOn: bind(model.directoryHistory, model.setDirectoryHistory)
            )
            .help(L10n.text("settings.help.directoryHistory"))
            LabeledContent(L10n.text("settings.label.directoryHistoryClear")) {
                StatusRowView(
                    status: model.directoryHistoryStatus,
                    action: Self.action(if: model.directoryHistoryStatus.actionTitle != nil) {
                        model.clearDirectoryHistory()
                    })
            }
            // The hosts the connect dialogs offer under Recent.
            LabeledContent(L10n.text("settings.label.recentHosts")) {
                StatusRowView(
                    status: model.recentHostsStatus,
                    action: Self.action(if: model.recentHostsStatus.actionTitle != nil) {
                        model.clearRecentHosts()
                    })
            }
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
    private func bind<Value>(_ value: Value, _ set: @escaping (Value) -> Void) -> Binding<Value> {
        Binding(get: { value }, set: { set($0) })
    }

    /// A right-aligned numeric field. `TextField(value:format:)` writes its
    /// binding on commit (Return or focus loss), not per keystroke, so a
    /// half-typed number never reaches the store.
    ///
    /// `labelsHidden`, because the field's empty title is still a label: the
    /// grouped form laid it out as a second, blank line under the field,
    /// which made every field row 11pt taller than a toggle row and sat the
    /// "×" and "seconds" beside it 5pt below the field's own baseline.
    private func numberField(_ value: Binding<Int>, width: CGFloat) -> some View {
        TextField("", value: value, format: .number)
            .labelsHidden()
            .frame(width: width)
            .multilineTextAlignment(.trailing)
    }

    private func numberField(_ value: Binding<Double>, width: CGFloat) -> some View {
        TextField("", value: value, format: .number)
            .labelsHidden()
            .frame(width: width)
            .multilineTextAlignment(.trailing)
    }

    /// `condition ? closure : nil`, spelled so the compiler doesn't have to
    /// unify a bound-method reference and `nil` inside a ternary.
    private static func action(if condition: Bool, _ closure: @escaping () -> Void)
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

/// The open-file command, validated when the edit is *finished*.
///
/// A text binding writes per keystroke, and the model validates and trims
/// every write: an unclosed `{` was refused and the field snapped back, so
/// `{file}` could not be typed one character at a time, and a trailing
/// space was trimmed away before the next word could follow it — only a
/// paste of the whole command ever got through. The draft lives here until
/// Return or focus loss commits it. An edit that arrives from the config
/// file replaces a draft the user has not touched; a draft they have is
/// theirs until they commit it.
private struct OpenFileCommandField: View {
    let model: SettingsModel
    @State private var draft: String
    /// What the file said when the draft last agreed with it; a draft that
    /// differs is the user's unfinished edit.
    @State private var synced: String
    @FocusState private var isEditing: Bool

    init(model: SettingsModel) {
        self.model = model
        _draft = State(initialValue: model.openFileCommand)
        _synced = State(initialValue: model.openFileCommand)
    }

    var body: some View {
        TextField("", text: $draft)
            .labelsHidden()
            .focused($isEditing)
            .onSubmit(commit)
            .onChange(of: isEditing) { _, editing in
                if !editing { commit() }
            }
            .onChange(of: model.openFileCommand) { _, value in
                if draft == synced { draft = value }
                synced = value
            }
            // The page can go away without resigning focus first.
            .onDisappear(perform: commit)
    }

    private func commit() {
        guard draft != synced else { return }
        model.setOpenFileCommand(draft)
        // A refused or trimmed value reads back as what the file holds.
        synced = model.openFileCommand
        draft = synced
    }
}
