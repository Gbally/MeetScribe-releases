// Translations. English text is the key; mac/Localization/<lang>.json holds each language and is
// compiled into <lang>.lproj/Localizable.strings at build time (scripts/i18n.py). Missing
// translations fall back to English. The UI follows the Mac's language unless one is forced in
// Settings → General (applied at the next launch, the standard macOS way).

import Foundation

enum AppLanguage {
    /// Supported languages (code, name in that language). Add one: create its JSON file and list it here.
    static let supported: [(code: String, name: String)] = [
        ("en", "English"), ("fr", "Français"), ("es", "Español"), ("pt", "Português"),
        ("ja", "日本語"), ("zh-Hans", "中文（简体）"),
    ]

    private static let key = "appLanguage" // "" = follow the Mac

    static var forced: String {
        get { UserDefaults.standard.string(forKey: key) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: key); apply() }
    }

    /// Pins (or releases) this app's language for the next launch.
    static func apply() {
        let d = UserDefaults.standard
        if forced.isEmpty {
            d.removeObject(forKey: "AppleLanguages")
            d.removeObject(forKey: "AppleLocale")
        } else {
            d.set([forced], forKey: "AppleLanguages")
            // Dates and weekday names follow the language too; keep the Mac's region.
            let region = Locale(identifier: Locale.preferredLanguages.first ?? "en").region?.identifier
                ?? (Locale.current.region?.identifier ?? "US")
            d.set("\(forced.replacingOccurrences(of: "-", with: "_"))_\(region)", forKey: "AppleLocale")
        }
    }

    /// The language the UI is actually in.
    static var current: String { Bundle.main.preferredLocalizations.first ?? "en" }
}

private let englishTable: Bundle? = Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:))

/// Translates `key` (English text). With arguments, the key is a format: tr("%@ to-dos", "3").
func tr(_ key: String, _ args: CVarArg...) -> String {
    var text = Bundle.main.localizedString(forKey: key, value: "\u{1}", table: nil)
    if text == "\u{1}" { text = englishTable?.localizedString(forKey: key, value: key, table: nil) ?? key }
    return args.isEmpty ? text : String(format: text, locale: Locale.current, arguments: args)
}

/// Marks a text for translation where it's defined; translate it with tr() where it's shown.
func i18n(_ key: String) -> String { key }

/// An engine status line `@@step {"key": "...%@...", "args": [...]}` in the UI language.
func localizedStep(_ line: String) -> String? {
    guard line.hasPrefix("@@step "), let data = line.dropFirst(7).data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let key = obj["key"] as? String else { return nil }
    let args = (obj["args"] as? [String] ?? []).map { $0 as CVarArg }
    return args.isEmpty ? tr(key) : String(format: tr(key), locale: Locale.current, arguments: args)
}
