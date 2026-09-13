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
/// Every control writes through `SettingsModel`'s setters, which write the
/// config file and re-read it. Nothing here holds state of its own — the
/// model re-populates from the store on `ConfigurationStore.didChange`, so
/// an edit made in `$EDITOR` while this window is open moves the controls,
/// and the two directions cannot disagree.
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
                appearanceTab.tabItem { Label(Tab.appearance.title, systemImage: Tab.appearance.symbol) }
                    .tag(Tab.appearance)
                terminalTab.tabItem { Label(Tab.terminal.title, systemImage: Tab.terminal.symbol) }
                    .tag(Tab.terminal)
                generalTab.tabItem { Label(Tab.general.title, systemImage: Tab.general.symbol) }
                    .tag(Tab.general)
            }
            StatusRowView(status: model.saveStatus, action: Self.action(if: model.saveStatus.kind == .failed) { model.retryWrite() })
                .padding(EdgeInsets(top: 10, leading: 16, bottom: 0, trailing: 16))
            Divider().padding(.top, 10)
            footer
        }
        .frame(minWidth: 460, minHeight: 360)
        .onAppear { model.windowWillShow() }
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
            LabeledContent(L10n.text("settings.label.fontStatus")) {
                StatusRowView(
                    status: model.fontStatus,
                    action: Self.action(if: model.fontStatus.kind == .failed) { model.retryFontResolution() })
            }
            LabeledContent(L10n.text("settings.label.size")) {
                Stepper(value: Binding(get: { model.fontSize }, set: { model.setFontSize($0) }), in: 8...64) {
                    Text(model.fontSize, format: .number)
                }
            }
            LabeledContent(L10n.text("settings.label.preview")) {
                FontPreviewSwiftUIView(theme: model.previewTheme, font: model.previewFont)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Terminal

    private var terminalTab: some View {
        Form {
            LabeledContent(L10n.text("settings.label.scrollback")) {
                TextField(
                    "", value: Binding(get: { model.scrollbackLines }, set: { model.setScrollbackLines($0) }),
                    format: .number)
                    .frame(width: 92)
                    .multilineTextAlignment(.trailing)
            }
            .help(L10n.text("settings.help.scrollback"))

            Picker(L10n.text("settings.label.bell"), selection: $model.bell) {
                ForEach(SettingsModel.bellModes, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .onChange(of: model.bell) { _, value in model.setBell(value) }

            Toggle(
                L10n.text("settings.label.optionAsMeta"),
                isOn: Binding(get: { model.optionAsMeta }, set: { model.setOptionAsMeta($0) })
            )
            .help(L10n.text("settings.help.optionAsMeta"))

            Toggle(
                L10n.text("settings.label.copyOnSelect"),
                isOn: Binding(get: { model.copyOnSelect }, set: { model.setCopyOnSelect($0) }))

            Picker(L10n.text("settings.label.openLinksWith"), selection: $model.linkActivation) {
                Text(L10n.text("settings.linkActivation.commandClick")).tag(Configuration.LinkActivation.command)
                Text(L10n.text("settings.linkActivation.click")).tag(Configuration.LinkActivation.click)
            }
            .onChange(of: model.linkActivation) { _, value in model.setLinkActivation(value) }

            Toggle(
                L10n.text("settings.label.allowClipboardCopy"),
                isOn: Binding(get: { model.allowClipboardWrite }, set: { model.setAllowClipboardWrite($0) })
            )
            .help(L10n.text("settings.help.allowClipboardCopy"))

            LabeledContent(L10n.text("settings.label.openFileCommand")) {
                TextField(
                    "", text: Binding(get: { model.openFileCommand }, set: { model.setOpenFileCommand($0) }))
            }
            .help(L10n.text("settings.help.openFileCommand"))

            LabeledContent(L10n.text("settings.label.shellIntegration")) {
                StatusRowView(status: model.shellIntegrationStatus, action: model.toggleShellIntegration)
            }
            .help(L10n.text("settings.help.shellIntegration"))
        }
        .formStyle(.grouped)
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section(L10n.text("settings.section.window")) {
                LabeledContent(L10n.text("settings.label.newWindow")) {
                    HStack(spacing: 6) {
                        TextField(
                            "", value: Binding(get: { model.columns }, set: { model.setColumns($0) }),
                            format: .number)
                            .frame(width: 54)
                            .multilineTextAlignment(.trailing)
                        Text("×").foregroundStyle(.secondary)
                        TextField(
                            "", value: Binding(get: { model.rows }, set: { model.setRows($0) }), format: .number
                        )
                        .frame(width: 54)
                        .multilineTextAlignment(.trailing)
                    }
                }
                .help(L10n.text("settings.help.newWindow"))
                Toggle(
                    L10n.text("settings.label.restoreWindows"),
                    isOn: Binding(get: { model.restoreWindows }, set: { model.setRestoreWindows($0) }))
            }
            Section(L10n.text("settings.section.closing")) {
                Toggle(
                    L10n.text("settings.label.confirmClose"),
                    isOn: Binding(get: { model.confirmClose }, set: { model.setConfirmClose($0) })
                )
                .help(L10n.text("settings.help.confirmClose"))
            }
            Section(L10n.text("settings.section.notifications")) {
                Toggle(
                    L10n.text("settings.label.notifyOnLongTasks"),
                    isOn: Binding(get: { model.notifyOnLongTask }, set: { model.setNotifyOnLongTask($0) })
                )
                .help(L10n.text("settings.help.notifyOnLongTasks"))
                if model.notificationPermissionNotice.kind != .none {
                    StatusRowView(
                        status: model.notificationPermissionNotice,
                        action: model.openSystemNotificationSettings)
                }
                LabeledContent(L10n.text("settings.label.longerThan")) {
                    HStack(spacing: 6) {
                        TextField(
                            "",
                            value: Binding(
                                get: { model.notificationThreshold },
                                set: { model.setNotificationThreshold($0) }), format: .number
                        )
                        .frame(width: 54)
                        .multilineTextAlignment(.trailing)
                        Text(L10n.text("settings.label.seconds")).foregroundStyle(.secondary)
                    }
                }
                .disabled(!model.notifyOnLongTask)
            }
            Section(L10n.text("settings.section.history")) {
                Toggle(
                    L10n.text("settings.label.directoryHistory"),
                    isOn: Binding(get: { model.directoryHistory }, set: { model.setDirectoryHistory($0) })
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
        .formStyle(.grouped)
    }

    /// `condition ? closure : nil`, spelled so the compiler doesn't have to
    /// unify a bound-method reference and `nil` inside a ternary.
    private static func action(if condition: Bool, _ closure: @escaping () -> Void) -> (() -> Void)? {
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
