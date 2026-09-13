import AppKit
import SwiftUI

/// The one line on the settings page that says what just happened —
/// SwiftUI replacement for `SettingsStatusView`, reused for the overall save
/// line, the font's resolution, shell integration, directory history, and
/// the notification-permission notice.
///
/// **Why it exists.** Every control on the settings page writes the config
/// file the moment it changes, which is the right behaviour and was also
/// completely silent: a saved change, a value quietly clamped, and a write
/// that failed outright all looked identical.
struct StatusRowView: View {
    let status: RowStatus
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(SystemAccessibility.increaseContrast ? AnyShapeStyle(.primary) : tint)
            }
            Text(status.message)
                .font(.system(size: NSFont.smallSystemFontSize))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(status.message)
            if let actionTitle = status.actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.accessoryBarAction)
                    .controlSize(.small)
            }
        }
        .frame(minHeight: 17, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.message.isEmpty ? "" : status.message)
        .onChange(of: status) { _, newValue in
            guard !newValue.message.isEmpty, NSWorkspace.shared.isVoiceOverEnabled else { return }
            NSAccessibility.post(
                element: NSApp as Any, notification: .announcementRequested,
                userInfo: [
                    .announcement: newValue.message,
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ])
        }
    }

    private var symbol: String? {
        switch status.kind {
        case .none: nil
        case .saved: "checkmark.circle.fill"
        case .adjusted: "info.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    /// Colour, used only to reinforce a symbol that already says the same
    /// thing. Not `systemGreen`/`systemRed`: the pair is the classic
    /// indistinguishable one, and neither hue adds anything the tick and the
    /// triangle have not already said.
    private var tint: AnyShapeStyle {
        switch status.kind {
        case .none, .saved: AnyShapeStyle(.secondary)
        case .adjusted: AnyShapeStyle(SwiftUI.Color.blue)
        case .failed: AnyShapeStyle(SwiftUI.Color.orange)
        }
    }
}
