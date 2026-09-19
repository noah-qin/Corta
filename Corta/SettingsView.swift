import SwiftUI

/// M6.1 — the settings page, in SwiftUI.
///
/// **Shape.** A native `TabView`, the way macOS's own preference windows are
/// built when they are not hand-rolling a toolbar. `Form`/`LabeledContent`
/// give correct label-control accessibility pairing and localization-aware
/// wrapping *natively* — the `measuredLabelColumnWidth`/two-line-wrap
/// machinery the AppKit page needed existed only because `NSStackView` and
/// explicit constraints have no such thing built in.
///
/// **Form style.** Grouped, the System Settings look. A row is as tall as
/// its control plus the style's own inset — the text-field rows used to be
/// 11pt taller than that because an empty `TextField` title still laid out
/// as a blank second line (`numberField`).
///
/// Every control writes through `SettingsModel`'s setters, which write the
/// config file and re-read it. Nothing here holds state of its own — the
/// model re-populates from the store on `ConfigurationStore.didChange`, so
/// an edit made in `$EDITOR` while this window is open moves the controls,
/// and the two directions cannot disagree. The one exception is the
/// open-file command's draft (`OpenFileCommandField`), which is validated
/// on commit rather than per keystroke.
struct SettingsView: View {
    @Bindable var model: SettingsModel
    @State private var selectedTab = Tab.appearance

    private enum Tab: String, CaseIterable, Identifiable {
        case appearance, terminal, general
        var id: String { rawValue }

        var title: String {
            switch self {
            case .appearance: L10n.text("settings.tab.appearance")
            case .terminal: L10n.text("settings.tab.terminal")
            case .general: L10n.text("settings.tab.general")
            }
        }

        /// SF Symbols, so the tab bar matches every other preference window
        /// on the system and follows the user's icon weight.
        var symbol: String {
            switch self {
            case .appearance: "paintpalette"
            case .terminal: "terminal"
            case .general: "gearshape"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                tab(.appearance) { appearanceTab }
                tab(.terminal) { terminalTab }
                tab(.general) { generalTab }
            }
            StatusRowView(
                status: model.saveStatus,
                action: Self.action(if: model.saveStatus.kind == .failed) { model.retryWrite() }
            )
            .padding(EdgeInsets(top: 10, leading: 16, bottom: 0, trailing: 16))
            Divider().padding(.top, 10)
            footer
        }
        .frame(minWidth: 460, minHeight: 360)
    }

    /// One tab's page. `isSelected` is what `SettingsPage` watches to put
    /// the page back at its top.
    private func tab<Content: View>(_ tab: Tab, @ViewBuilder content: () -> Content) -> some View {
        SettingsPage(isSelected: selectedTab == tab, content: content)
            .tabItem { Label(tab.title, systemImage: tab.symbol) }
            .tag(tab)
    }

    // MARK: - Appearance

    private var appearanceTab: some View {
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

            LabeledContent(L10n.text("settings.label.font")) {
                Text(model.fontFamilyDisplay).help(L10n.text("settings.font.tooltip"))
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
                FontPreviewSwiftUIView(theme: model.previewTheme, font: model.previewFont)
            }
        }
    }

    // MARK: - Terminal

    private var terminalTab: some View {
        Form {
            Section(L10n.text("settings.section.output")) {
                LabeledContent(L10n.text("settings.label.scrollback")) {
                    numberField(bind(model.scrollbackLines, model.setScrollbackLines), width: 92)
                }
                .help(L10n.text("settings.help.scrollback"))
                Picker(L10n.text("settings.label.bell"), selection: $model.bell) {
                    ForEach(SettingsModel.bellModes, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: model.bell) { _, value in model.setBell(value) }
            }
            Section(L10n.text("settings.section.input")) {
                Toggle(
                    L10n.text("settings.label.optionAsMeta"),
                    isOn: bind(model.optionAsMeta, model.setOptionAsMeta)
                )
                .help(L10n.text("settings.help.optionAsMeta"))
                Toggle(
                    L10n.text("settings.label.copyOnSelect"),
                    isOn: bind(model.copyOnSelect, model.setCopyOnSelect))
                Picker(
                    L10n.text("settings.label.openLinksWith"), selection: $model.linkActivation
                ) {
                    Text(L10n.text("settings.linkActivation.commandClick"))
                        .tag(Configuration.LinkActivation.command)
                    Text(L10n.text("settings.linkActivation.click"))
                        .tag(Configuration.LinkActivation.click)
                }
                .onChange(of: model.linkActivation) { _, value in model.setLinkActivation(value) }
                Toggle(
                    L10n.text("settings.label.allowClipboardCopy"),
                    isOn: bind(model.allowClipboardWrite, model.setAllowClipboardWrite)
                )
                .help(L10n.text("settings.help.allowClipboardCopy"))
                Toggle(
                    L10n.text("command.secureKeyboardEntry"),
                    isOn: bind(model.secureKeyboardEntry, model.setSecureKeyboardEntry)
                )
                .help(L10n.text("settings.help.secureKeyboardEntry"))
            }
            Section(L10n.text("settings.section.shell")) {
                LabeledContent(L10n.text("settings.label.openFileCommand")) {
                    OpenFileCommandField(model: model)
                }
                .help(L10n.text("settings.help.openFileCommand"))
                LabeledContent(L10n.text("settings.label.shellIntegration")) {
                    StatusRowView(
                        status: model.shellIntegrationStatus, action: model.toggleShellIntegration)
                }
                .help(L10n.text("settings.help.shellIntegration"))
            }
        }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            windowSection
            quickTerminalSection
            Section(L10n.text("settings.section.closing")) {
                Toggle(
                    L10n.text("settings.label.confirmClose"),
                    isOn: bind(model.confirmClose, model.setConfirmClose)
                )
                .help(L10n.text("settings.help.confirmClose"))
            }
            notificationsSection
            historySection
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

    private var quickTerminalSection: some View {
        Section(L10n.text("settings.section.quickTerminal")) {
            Toggle(
                L10n.text("settings.label.quickTerminalHotkey"),
                isOn: bind(model.quickTerminal, model.setQuickTerminal)
            )
            .help(L10n.text("settings.help.quickTerminal"))
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

/// One tab's page.
///
/// The tab view keeps every page alive, and a page's scroll position lived
/// on with it — scroll the Terminal tab down, visit General, come back, and
/// the Terminal tab was still scrolled. A page is put back at its top
/// whenever its selection changes, so it is at the top both when it is
/// left and when it is returned to.
private struct SettingsPage<Content: View>: View {
    let isSelected: Bool
    let content: Content
    /// Bumped on every selection change; a new identity is a new list,
    /// and a new list starts at its top. `scrollTo` on the first section
    /// stopped short of that by the form's own top padding.
    @State private var generation = 0

    init(isSelected: Bool, @ViewBuilder content: () -> Content) {
        self.isSelected = isSelected
        self.content = content()
    }

    var body: some View {
        content
            .formStyle(.grouped)
            .id(generation)
            .onChange(of: isSelected) { _, _ in generation += 1 }
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
