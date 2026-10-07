import XCTest
@testable import TranscriberCore

final class TranscriptionSettingsTests: XCTestCase {
    func testFreshInstallHasPredeterminedLocalModel() {
        XCTAssertEqual(TranscriptionSettings.defaults.mode, .local)
        XCTAssertEqual(TranscriptionSettings.defaults.localModel, .base)
        XCTAssertEqual(ServerModelPreset.selected(for: "nemotron-3.5"), .nemotron)
        XCTAssertEqual(ServerModelPreset.selected(for: "whisper-1"), .whisper)
        XCTAssertEqual(ServerModelPreset.selected(for: "my-server-model"), .custom)
        XCTAssertEqual(ServerModelPreset.selected(for: "nemotron-3.5", in: .api), .custom)
    }

    func testModesKeepIndependentAddressesAndModelsAcrossRestarts() throws {
        let suite = "TranscriptionSettingsTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = TranscriptionSettings.defaults
        settings.mode = .server
        settings.connection = ConnectionSettings(baseURL: "http://localhost:9000/v1", model: "custom-server")
        settings.mode = .api
        XCTAssertEqual(settings.connection.baseURL, "https://api.openai.com/v1")
        settings.connection = ConnectionSettings(baseURL: "https://example.test/v1", model: "custom-api", language: "en")
        settings.mode = .local; settings.localModel = .small; settings.localLanguage = ""
        try settings.save(to: defaults)
        var loaded = TranscriptionSettings.load(from: defaults)
        XCTAssertEqual(loaded, settings)
        loaded.mode = .server
        XCTAssertEqual(loaded.connection.baseURL, "http://localhost:9000/v1")
        XCTAssertEqual(loaded.connection.model, "custom-server")
        loaded.mode = .api
        XCTAssertEqual(loaded.connection.baseURL, "https://example.test/v1")
        XCTAssertEqual(loaded.connection.model, "custom-api")
        let stored = try XCTUnwrap(defaults.data(forKey: TranscriptionSettings.storageKey))
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("apiKey"))
    }

    func testMigratesExistingServerSettings() throws {
        let suite = "TranscriptionMigrationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = ConnectionSettings(baseURL: "https://example.test/v1", model: "legacy-model", language: "en")
        try legacy.save(to: defaults)
        let migrated = TranscriptionSettings.load(from: defaults)
        XCTAssertEqual(migrated.mode, .server)
        XCTAssertEqual(migrated.server, legacy)
        var changed = migrated; changed.mode = .local
        try changed.save(to: defaults)
        XCTAssertEqual(TranscriptionSettings.load(from: defaults).mode, .local)
    }

    func testLocalModeDoesNotRequireAServerURL() throws {
        var settings = TranscriptionSettings.defaults
        settings.server.baseURL = ""; settings.api.baseURL = ""
        XCTAssertNoThrow(try settings.validated())
        settings.localLanguage = "русский"
        XCTAssertThrowsError(try settings.validated())
        settings.localLanguage = "ru"; settings.localTimeoutMinutes = 0
        XCTAssertThrowsError(try settings.validated())
        settings.mode = .server
        XCTAssertThrowsError(try settings.validated())
    }

    func testRejectsDamagedAndTruncatedDownloads() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let digest = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        try Data("hello".utf8).write(to: file)
        XCTAssertNoThrow(try LocalModelStore.verify(file: file, byteCount: 5, sha256: digest))
        XCTAssertThrowsError(try LocalModelStore.verify(file: file, byteCount: 6, sha256: digest))
        try Data("jello".utf8).write(to: file)
        XCTAssertThrowsError(try LocalModelStore.verify(file: file, byteCount: 5, sha256: digest))
    }
}
