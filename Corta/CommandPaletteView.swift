import SwiftUI

/// M7.12 — the command palette's content, in SwiftUI.
/// `CommandPaletteModel` owns the state; `CommandPaletteController` only
/// hosts this view in an `NSHostingView` inside its `NSGlassEffectView`
/// panel and forwards `show(_:)`.
///
/// The search field keeps focus the whole time the palette is open — arrow
/// keys, Return and Escape are all read off it directly (`.onKeyPress`/
/// `.onExitCommand`) rather than through a table view's own selection, which
/// is what let the old AppKit version's local key-event monitor go away
/// entirely: a plain `NSTextField` never consumed vertical arrow keys either,
/// so intercepting them at the field is the same behavior SwiftUI gives for
/// free.
struct CommandPaletteView: View {
    @Bindable var model: CommandPaletteModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(L10n.text("commandPalette.placeholder"), text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($searchFocused)
                .onKeyPress(.upArrow) {
                    model.moveSelection(by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    model.moveSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.return) {
                    model.runSelected()
                    return .handled
                }
                .onExitCommand { model.dismiss() }
                .onChange(of: model.query) { _, _ in model.selectFirstIfNeeded() }
            Divider()
            if model.rows.isEmpty {
                Text(L10n.text("commandPalette.empty"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 28)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.rows) { row in
                                CommandPaletteRowView(
                                    row: row, isSelected: row.command == model.selectedCommand
                                )
                                .id(row.id)
                                .onTapGesture {
                                    guard let command = row.command else { return }
                                    model.select(command)
                                    model.runSelected()
                                }
                            }
                        }
                    }
                    .onChange(of: model.selectedCommand) { _, newValue in
                        guard let newValue else { return }
                        proxy.scrollTo(CommandPaletteModel.Row.command(newValue).id, anchor: .center)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 520, height: 360)
        .onAppear { searchFocused = true }
    }
}

private struct CommandPaletteRowView: View {
    let row: CommandPaletteModel.Row
    let isSelected: Bool

    var body: some View {
        switch row {
        case .header(let title):
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
                .padding(.bottom, 2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
        case .command(let command):
            let shortcut =
                ConfigurationStore.shared.configuration.keybindings[command]?.displayText ?? ""
            HStack {
                Text(command.title).font(.system(size: 13))
                Spacer()
                // The system font, not a monospaced one: these are the same
                // ⌘⇧D / ← / ⇞ glyphs the menu bar draws, and the menu bar
                // draws them in the system face.
                Text(shortcut).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .background(
                isSelected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
            // One element with one name, so VoiceOver announces "Split Pane
            // Right, Command Shift D" instead of two adjacent labels.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(shortcut.isEmpty ? command.title : "\(command.title), \(shortcut)")
        }
    }
}
