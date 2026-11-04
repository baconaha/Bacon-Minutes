import CoreFoundation
import Foundation

/// The UI language: the user's pick in Settings, or the first supported system language.
enum LanguagePreference {
    private static let key = "ui.language"

    /// nil means "follow the system".
    static var choice: AppLanguage? {
        UserDefaults.standard.string(forKey: key).flatMap(AppLanguage.init(rawValue:))
    }

    /// The system's preferred language, ignoring this app's own `AppleLanguages` override.
    static var systemLanguage: AppLanguage {
        let global = CFPreferencesCopyAppValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication) as? [String]
        return AppLanguage.best(for: global ?? Locale.preferredLanguages)
    }

    static func applyAtLaunch() {
        Localizer.shared.language = choice ?? systemLanguage
    }

    /// Switches the app's own text immediately. Text drawn by macOS (standard menu items,
    /// open and save panels) follows on the next launch through `AppleLanguages`.
    static func set(_ newChoice: AppLanguage?) {
        let defaults = UserDefaults.standard
        if let newChoice {
            defaults.set(newChoice.rawValue, forKey: key)
            defaults.set([newChoice.rawValue], forKey: "AppleLanguages")
        } else {
            defaults.removeObject(forKey: key)
            defaults.removeObject(forKey: "AppleLanguages")
        }
        Localizer.shared.language = newChoice ?? systemLanguage
    }
}
