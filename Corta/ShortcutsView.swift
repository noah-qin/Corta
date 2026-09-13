import SwiftUI

/// Help > Keyboard Shortcuts (⌘/) — every command Corta has, grouped, with
/// the key that runs it.
///
/// It owns no data. The rows are `TerminalCommand.allCases` grouped by
/// `category` with the shortcuts read from `ConfigurationStore`, which means a
/// command added to that table appears here for free, and a key rebound in
/// the config file is shown rebound — a printed cheat sheet that disagrees
/// with the running app is worse than none. `ShortcutsWindowController` only
/// hosts this view in an `NSHostingController`.
struct ShortcutsView: View {
    @State private var bindings = ConfigurationStore.shared.configuration.keybindings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(CommandCategory.allCases, id: \.self) { category in
                    let commands = Self.commands(in: category)
                    if !commands.isEmpty {
                        Text(category.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                        ForEach(commands, id: \.self) { command in
                            ShortcutRowView(title: command.title, shortcut: bindings[command]?.displayText)
                        }
                    }
                }
                Text(L10n.text("shortcuts.footnote"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
            .padding(EdgeInsets(top: 20, leading: 24, bottom: 20, trailing: 24))
        }
        .frame(minWidth: 460, minHeight: 520)
        .onReceive(NotificationCenter.default.publisher(for: ConfigurationStore.didChange)) { _ in
            bindings = ConfigurationStore.shared.configuration.keybindings
        }
    }

    private static func commands(in category: CommandCategory) -> [TerminalCommand] {
        TerminalCommand.allCases
            .filter { $0.category == category }
            .sorted { $0.paletteRank < $1.paletteRank }
    }
}

private struct ShortcutRowView: View {
    let title: String
    let shortcut: String?

    var body: some View {
        LabeledContent(title) {
            Text(shortcut ?? "—")
                .foregroundStyle(shortcut == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
        }
        .font(.system(size: 13))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            shortcut.map { L10n.format("shortcuts.a11yRow", title, $0) }
                ?? L10n.format("shortcuts.a11yUnbound", title))
    }
}
