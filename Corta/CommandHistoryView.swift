import SwiftUI

/// B10 — the SwiftUI half of the app's first SwiftUI surface;
/// `CommandHistoryModel` is the other half, and `CommandHistoryController`
/// only hosts this view in an `NSHostingController` and forwards `show(for:)`.
struct CommandHistoryView: View {
    @Bindable var model: CommandHistoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            filterRow
            if let message = model.noPaneMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                Text(L10n.format("commandHistory.count", model.rows.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                resultsList
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 240)
    }

    private var filterRow: some View {
        HStack(spacing: 12) {
            Toggle(L10n.text("commandHistory.thisDirectory"), isOn: $model.directoryOnly)
            Toggle(L10n.text("commandHistory.thisProject"), isOn: $model.projectOnly)
            Picker("", selection: $model.exitFilter) {
                ForEach(CommandHistoryModel.ExitFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .labelsHidden()
            .frame(width: 140)
            Spacer()
            Button(L10n.text("commandHistory.clear")) { model.clearHistory() }
        }
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(model.rows) { row in
                    CommandHistoryRowView(row: row, model: model)
                }
            }
        }
    }
}

private struct CommandHistoryRowView: View {
    let row: CommandHistoryModel.Row
    let model: CommandHistoryModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: row.statusSymbolName)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(row.timestamp)
                .font(.system(size: 12))
            Text(row.directoryText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(row.directoryTooltip ?? "")
            Spacer()
            Button(L10n.text("commandHistory.find")) { model.find(id: row.id) }
            Button(L10n.text("commandHistory.fill")) { model.fill(id: row.id) }
                .disabled(!row.canFillOrRun)
            Button(L10n.text("commandHistory.run")) { model.run(id: row.id) }
                .disabled(!row.canFillOrRun)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }
}
