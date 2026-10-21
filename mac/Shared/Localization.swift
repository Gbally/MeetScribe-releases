// Translations. English text is the key; mac/Localization/<lang>.json holds each language and is
// compiled into <lang>.lproj/Localizable.strings at build time (scripts/i18n.py). Missing
// translations fall back to English.
//
// The UI follows the Mac's language unless one is forced in Settings → General. The app picks the
// translation table itself (rather than the one macOS chose at launch), so switching language
// takes effect immediately; only texts drawn by macOS itself (standard menus, file panels) wait
// for the next launch.

import Foundation

enum AppLanguage {
    /// Supported languages (code, name in that language). Add one: create its JSON file and list it here.
    static let supported: [(code: String, name: String)] = [
        ("en", "English"), ("fr", "Français"), ("es", "Español"), ("pt", "Português"),
        ("ja", "日本語"), ("zh-Hans", "中文（简体）"),
    ]

    private static let key = "appLanguage" // "" = follow the Mac

    /// The forced language ("" = follow the Mac). Setting it switches the UI right away.
    static var forced: String {
        get { UserDefaults.standard.string(forKey: key) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            pinForNextLaunch()
            reload()
        }
    }

    /// The language the UI is in: the forced one, else the best match for the Mac's languages.
    private(set) static var current: String = resolve()

    /// Formats dates, weekdays and months in the UI language (keeping the Mac's region).
    private(set) static var locale: Locale = makeLocale()

    private static var table: Bundle? = bundle(for: current)
    private static let english: Bundle? = bundle(for: "en")

    private static func resolve() -> String {
        if !forced.isEmpty { return forced }
        let codes = supported.map(\.code)
        return Bundle.preferredLocalizations(from: codes, forPreferences: Locale.preferredLanguages).first ?? "en"
    }

    private static func makeLocale() -> Locale {
        let region = Locale.current.region?.identifier ?? "US"
        return Locale(identifier: "\(current.replacingOccurrences(of: "-", with: "_"))_\(region)")
    }

    private static func bundle(for code: String) -> Bundle? {
        Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:))
    }

    private static func reload() {
        current = resolve()
        locale = makeLocale()
        table = bundle(for: current)
    }

    /// macOS's own texts (standard menus, file panels) follow the app language from the next launch.
    private static func pinForNextLaunch() {
        let d = UserDefaults.standard
        if forced.isEmpty {
            d.removeObject(forKey: "AppleLanguages")
        } else {
            d.set([forced], forKey: "AppleLanguages")
        }
        d.removeObject(forKey: "AppleLocale") // dates use AppLanguage.locale
    }

    fileprivate static func lookup(_ key: String) -> String {
        if let t = table?.localizedString(forKey: key, value: "\u{1}", table: nil), t != "\u{1}" { return t }
        return english?.localizedString(forKey: key, value: key, table: nil) ?? key
    }
}

/// Translates `key` (English text). With arguments, the key is a format: tr("%@ to-dos", "3").
func tr(_ key: String, _ args: CVarArg...) -> String {
    let text = AppLanguage.lookup(key)
    return args.isEmpty ? text : String(format: text, locale: AppLanguage.locale, arguments: args)
}

/// Marks a text for translation where it's defined; translate it with tr() where it's shown.
func i18n(_ key: String) -> String { key }

/// An engine status line `@@step {"key": "...%@...", "args": [...]}` in the UI language.
func localizedStep(_ line: String) -> String? {
    guard line.hasPrefix("@@step "), let data = line.dropFirst(7).data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let key = obj["key"] as? String else { return nil }
    let args = (obj["args"] as? [String] ?? []).map { $0 as CVarArg }
    return args.isEmpty ? tr(key) : String(format: tr(key), locale: AppLanguage.locale, arguments: args)
}

extension Date {
    /// Like formatted(date:time:), but in the UI language.
    func local(date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> String {
        formatted(Date.FormatStyle(date: date, time: time, locale: AppLanguage.locale))
    }
}
