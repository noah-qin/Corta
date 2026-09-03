import Foundation

enum L10n {
    nonisolated static func text(_ key: String, comment: String = "") -> String {
        NSLocalizedString(key, comment: comment)
    }

    nonisolated static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), arguments: arguments)
    }
}
