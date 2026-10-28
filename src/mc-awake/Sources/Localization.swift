import Foundation

enum AppLanguage: String, CaseIterable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"
}

struct AppLocalization {
    static let languageKey = "McAwakeLanguage"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var language: AppLanguage {
        get {
            defaults.string(forKey: Self.languageKey).flatMap(AppLanguage.init(rawValue:)) ?? .simplifiedChinese
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Self.languageKey)
        }
    }

    func text(_ chinese: String, _ english: String) -> String {
        language == .simplifiedChinese ? chinese : english
    }
}
