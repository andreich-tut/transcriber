import Foundation

public struct ConnectionSettings: Codable, Equatable, Sendable {
    public enum ResponseFormat: String, Codable, CaseIterable, Sendable {
        case json
        case verboseJSON = "verbose_json"
    }

    public var baseURL: String
    public var model: String
    public var language: String
    public var responseFormat: ResponseFormat
    public var timeoutMinutes: Int

    public static let defaults = ConnectionSettings(
        baseURL: "http://127.0.0.1:18000/v1", model: "nemotron-3.5", language: "ru",
        responseFormat: .json, timeoutMinutes: 120
    )

    public init(baseURL: String, model: String, language: String = "ru",
                responseFormat: ResponseFormat = .json, timeoutMinutes: Int = 120) {
        self.baseURL = baseURL; self.model = model; self.language = language
        self.responseFormat = responseFormat; self.timeoutMinutes = timeoutMinutes
    }

    public func validated() throws -> ConnectionSettings {
        var value = self
        value.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        value.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        value.language = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: value.baseURL),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw TranscriptionError.invalidSettings("Enter a full base URL with http:// or https://, without credentials or query parameters.")
        }
        components.scheme = scheme
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard !components.path.hasSuffix("/audio/transcriptions"), let url = components.url else {
            throw TranscriptionError.invalidSettings("Enter a base URL such as http://127.0.0.1:18000/v1. The app adds /audio/transcriptions automatically.")
        }
        value.baseURL = url.absoluteString
        guard !value.model.isEmpty, value.model.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw TranscriptionError.invalidSettings("Enter a model name without line breaks.")
        }
        guard value.language.isEmpty || value.language.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "-") }) else {
            throw TranscriptionError.invalidSettings("Use a language code such as ru or en. Leave blank for automatic detection.")
        }
        guard (1...1440).contains(timeoutMinutes) else {
            throw TranscriptionError.invalidSettings("The timeout must be between 1 and 1440 minutes.")
        }
        return value
    }

    public func transcriptionEndpoint() throws -> URL {
        let settings = try validated()
        return URL(string: settings.baseURL)!.appendingPathComponent("audio/transcriptions")
    }

    private static let storageKey = "transcription.connection.v1"
    public static func load(from defaults: UserDefaults = .standard) -> ConnectionSettings {
        guard let data = defaults.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              let validated = try? value.validated() else { return .defaults }
        return validated
    }

    public func save(to defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(validated()), forKey: Self.storageKey)
    }
}
