import Foundation
import Observation

/// UI languages. The Chinese text in the code is the lookup key; every other language has a
/// `<code>.lproj/Localizable.strings` table in the app bundle.
enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case zhHans = "zh-Hans"
    case en, ja, ko, es, vi, fr, pt, ru

    var id: String { rawValue }

    /// The language's name in that language, as shown in the picker.
    var nativeName: String {
        switch self {
        case .zhHans: return "简体中文"
        case .en: return "English"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .es: return "Español"
        case .vi: return "Tiếng Việt"
        case .fr: return "Français"
        case .pt: return "Português"
        case .ru: return "Русский"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }

    /// Separator for short lists such as keywords.
    var listSeparator: String {
        switch self {
        case .zhHans, .ja: return "、"
        default: return ", "
        }
    }

    /// First supported language in a preference list (e.g. `Locale.preferredLanguages`), else English.
    static func best(for identifiers: [String]) -> AppLanguage {
        for raw in identifiers {
            let id = raw.lowercased().replacingOccurrences(of: "_", with: "-")
            if id == "zh" || id.hasPrefix("zh-") { return .zhHans }
            for lang in allCases where lang != .zhHans {
                if id == lang.rawValue || id.hasPrefix(lang.rawValue + "-") { return lang }
            }
        }
        return .en
    }
}

/// Holds the current UI language. Views that read text through `L` re-render when it changes.
@Observable
final class Localizer {
    static let shared = Localizer()

    /// Chinese until the app applies the saved or system choice at launch.
    var language: AppLanguage = .zhHans

    @ObservationIgnored private var tables: [AppLanguage: [String: String]] = [:]
    private let lock = NSLock()

    /// A key may end in `@@context` to tell apart identical Chinese text used in different
    /// places ("播放" the button vs "播放@@settings" the section); the suffix is never shown.
    func string(_ key: String, in language: AppLanguage) -> String {
        if language != .zhHans {
            lock.lock()
            if tables[language] == nil { tables[language] = Self.loadTable(language) }
            let found = tables[language]?[key]
            lock.unlock()
            if let found { return found }
        }
        guard let mark = key.range(of: "@@") else { return key }
        return String(key[..<mark.lowerBound])
    }

    private static func loadTable(_ language: AppLanguage) -> [String: String] {
        guard let url = Bundle.main.url(forResource: "Localizable", withExtension: "strings",
                                        subdirectory: nil, localization: language.rawValue),
              let dict = NSDictionary(contentsOf: url) as? [String: String] else { return [:] }
        return dict
    }

    /// Replaces `{0}`, `{1}` … with the arguments.
    static func fill(_ template: String, _ args: [Any]) -> String {
        guard !args.isEmpty else { return template }
        var out = template
        for (i, arg) in args.enumerated() {
            out = out.replacingOccurrences(of: "{\(i)}", with: "\(arg)")
        }
        return out
    }
}

/// UI text in the current language. `key` is the Chinese text; `{0}`, `{1}` … take `args`.
func L(_ key: String, _ args: Any...) -> String {
    let loc = Localizer.shared
    return Localizer.fill(loc.string(key, in: loc.language), args)
}

/// UI text in a given language.
func L(_ key: String, in language: AppLanguage, _ args: Any...) -> String {
    Localizer.fill(Localizer.shared.string(key, in: language), args)
}
