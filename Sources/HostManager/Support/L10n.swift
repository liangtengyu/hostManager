import Foundation

/// UI text comes from the bundle's `Localizable.strings`, so the app follows the system
/// language (Chinese and English ship). A key that is missing shows up as the key itself.
enum L10n {
    static func t(_ key: String) -> String {
        NSLocalizedString(key, tableName: nil, bundle: .main, value: key, comment: "")
    }

    static func f(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), locale: Locale.current, arguments: arguments)
    }
}
