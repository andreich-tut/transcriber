import Foundation

public enum AppLanguage: String, CaseIterable, Sendable {
    case system, russian = "ru", english = "en"

    public static let storageKey = "interface.language"

    public static func load(from defaults: UserDefaults = .standard) -> AppLanguage {
        defaults.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .system
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }

    public func resolvedCode(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        guard self == .system else { return rawValue }
        let primary = preferredLanguages.first?.replacingOccurrences(of: "_", with: "-")
            .split(separator: "-").first?.lowercased()
        return primary == "ru" ? "ru" : "en"
    }

    public var title: String {
        switch self {
        case .system: return L10n.text("System language")
        case .russian: return "Русский"
        case .english: return "English"
        }
    }
}

public enum L10n {
    public static func text(_ key: String, _ arguments: CVarArg...) -> String {
        text(key, language: .load(), arguments: arguments)
    }

    public static func text(_ key: String, language: AppLanguage,
                            preferredLanguages: [String] = Locale.preferredLanguages,
                            arguments: [CVarArg] = []) -> String {
        let code = language.resolvedCode(preferredLanguages: preferredLanguages)
        let bundle = localizedBundle(code: code)
        let format = bundle.localizedString(forKey: key, value: key, table: nil)
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale(identifier: code), arguments: arguments)
    }

    static func localizedBundle(code: String) -> Bundle {
        guard let path = Bundle.module.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return Bundle.module }
        return bundle
    }
}
