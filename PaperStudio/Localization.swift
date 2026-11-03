// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en", spanish = "es", french = "fr"
    var id: String { rawValue }
    var title: String {
        switch self { case .english: return "English"; case .spanish: return "Español"; case .french: return "Français" }
    }
    static var preferred: AppLanguage {
        let code = Locale.preferredLanguages.first?.prefix(2) ?? "en"
        return AppLanguage(rawValue: String(code)) ?? .english
    }
    static var current: AppLanguage {
        UserDefaults.standard.string(forKey: "appLanguage").flatMap(AppLanguage.init(rawValue:)) ?? .preferred
    }
}

enum L10n {
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: tr(key), locale: Locale(identifier: AppLanguage.current.rawValue), arguments: arguments)
    }
    static func tr(_ key: String, language: AppLanguage = .current) -> String {
        guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"), let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }
}
