import XCTest
@testable import TranscriberCore

final class ConnectionSettingsTests: XCTestCase {
    func testNormalizesBaseURLAndAppendsEndpoint() throws {
        let settings = ConnectionSettings(baseURL: "  http://127.0.0.1:18000/v1/// \n", model: " whisper-1 ", language: " en ")
        let value = try settings.validated()
        XCTAssertEqual(value.baseURL, "http://127.0.0.1:18000/v1")
        XCTAssertEqual(value.model, "whisper-1")
        XCTAssertEqual(value.language, "en")
        XCTAssertEqual(try value.transcriptionEndpoint().absoluteString, "http://127.0.0.1:18000/v1/audio/transcriptions")
    }
    func testRejectsInvalidConnectionSettings() {
        for url in ["127.0.0.1:18000/v1", "ftp://localhost/v1", "http://", "http://user:secret@localhost/v1",
                    "http://localhost/v1?key=x", "http://localhost/v1#fragment", "http://localhost/v1/audio/transcriptions"] {
            XCTAssertThrowsError(try ConnectionSettings(baseURL: url, model: "whisper-1").validated(), url)
        }
        var settings = ConnectionSettings.defaults
        settings.model = " \n "
        XCTAssertThrowsError(try settings.validated())
        settings = .defaults; settings.language = "русский"
        XCTAssertThrowsError(try settings.validated())
        settings = .defaults; settings.timeoutMinutes = 0
        XCTAssertThrowsError(try settings.validated())
        XCTAssertThrowsError(try TranscriptionService(settings: .defaults, apiKey: "test\r\ninvalid"))
    }
    func testSavesAndLoadsSettingsWithoutSecretData() throws {
        let suite = "TranscriberTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ConnectionSettings.load(from: defaults), .defaults)
        let settings = ConnectionSettings(baseURL: "https://example.test/v1", model: "whisper-1", language: "",
                                          responseFormat: .verboseJSON, timeoutMinutes: 90)
        try settings.save(to: defaults)
        XCTAssertEqual(ConnectionSettings.load(from: defaults), settings)
        let data = try XCTUnwrap(defaults.data(forKey: "transcription.connection.v1"))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["baseURL", "model", "language", "responseFormat", "timeoutMinutes"])
        defaults.set(Data("invalid".utf8), forKey: "transcription.connection.v1")
        XCTAssertEqual(ConnectionSettings.load(from: defaults), .defaults)
    }
}
