import XCTest
@testable import TranscriberCore

final class AppLanguageTests: XCTestCase {
    func testDefaultsToSystemAndPersistsExplicitChoices() throws {
        let suite = "TranscriberLanguageTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AppLanguage.load(from: defaults), .system)
        for language in AppLanguage.allCases {
            language.save(to: defaults)
            XCTAssertEqual(AppLanguage.load(from: defaults), language)
        }
        defaults.set("unknown", forKey: AppLanguage.storageKey)
        XCTAssertEqual(AppLanguage.load(from: defaults), .system)
    }

    func testSystemLanguageUsesPrimaryMacOSLanguage() {
        for code in ["ru", "ru-RU", "ru_KZ", "RU-ru"] {
            XCTAssertEqual(AppLanguage.system.resolvedCode(preferredLanguages: [code, "en"]), "ru")
        }
        for code in ["en", "en-GB", "de-DE", "fr"] {
            XCTAssertEqual(AppLanguage.system.resolvedCode(preferredLanguages: [code, "ru"]), "en")
        }
        XCTAssertEqual(AppLanguage.system.resolvedCode(preferredLanguages: []), "en")
        XCTAssertEqual(AppLanguage.russian.resolvedCode(preferredLanguages: ["en"]), "ru")
        XCTAssertEqual(AppLanguage.english.resolvedCode(preferredLanguages: ["ru"]), "en")
    }

    func testTranslationsAndFormattedMessages() {
        XCTAssertEqual(L10n.text("Settings", language: .russian), "Настройки")
        XCTAssertEqual(L10n.text("Settings", language: .english), "Settings")
        XCTAssertEqual(L10n.text("Settings", language: .system, preferredLanguages: ["ru-RU"]), "Настройки")
        XCTAssertEqual(L10n.text("Settings", language: .system, preferredLanguages: ["de-DE"]), "Settings")
        XCTAssertEqual(L10n.text("Done. Timestamped segments: %d.", language: .russian, arguments: [3]),
                       "Готово. Сегментов с таймкодами: 3.")
        XCTAssertEqual(L10n.text("Saved: %@, %@", language: .english, arguments: ["audio.txt", "audio.json"]),
                       "Saved: audio.txt, audio.json")
        XCTAssertEqual(L10n.text("Unknown message", language: .russian), "Unknown message")
    }

    func testCatalogsHaveMatchingKeysAndFormatPlaceholders() throws {
        func catalog(_ code: String) throws -> [String: String] {
            let url = try XCTUnwrap(L10n.localizedBundle(code: code).url(forResource: "Localizable", withExtension: "strings"))
            let data = try Data(contentsOf: url)
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        }
        let english = try catalog("en"), russian = try catalog("ru")
        XCTAssertFalse(english.isEmpty)
        XCTAssertEqual(Set(english.keys), Set(russian.keys))
        let pattern = try NSRegularExpression(pattern: "%[@d]")
        func placeholders(_ text: String) -> [String] {
            let range = NSRange(text.startIndex..., in: text)
            return pattern.matches(in: text, range: range).map { (text as NSString).substring(with: $0.range) }
        }
        for (key, value) in english {
            XCTAssertEqual(value, key)
            XCTAssertFalse(try XCTUnwrap(russian[key]).isEmpty)
            XCTAssertEqual(placeholders(value), placeholders(russian[key]!), key)
        }
    }

    func testExistingErrorsFollowLanguageChangesWithoutChangingConnection() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppLanguage.storageKey)
        defer {
            if let previous { defaults.set(previous, forKey: AppLanguage.storageKey) }
            else { defaults.removeObject(forKey: AppLanguage.storageKey) }
        }
        let settings = ConnectionSettings.load()
        let error = TranscriptionError.invalidSettings("The timeout must be between 1 and 1440 minutes.")
        AppLanguage.english.save()
        XCTAssertEqual(error.localizedDescription, "Could not save the settings. The timeout must be between 1 and 1440 minutes.")
        AppLanguage.russian.save()
        XCTAssertEqual(error.localizedDescription, "Не удалось сохранить настройки. Время ожидания должно быть от 1 до 1440 минут.")
        XCTAssertEqual(ConnectionSettings.load(), settings)
    }
}
