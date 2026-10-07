import Foundation

public enum TranscriptionMode: String, Codable, CaseIterable, Sendable {
    case local, server, api

    public var title: String {
        switch self {
        case .local: return L10n.text("On this Mac")
        case .server: return L10n.text("Server")
        case .api: return L10n.text("External API")
        }
    }
}

public enum ServerModelPreset: String, CaseIterable, Sendable {
    case nemotron = "nemotron-3.5", whisper = "whisper-1", custom

    public var title: String {
        switch self {
        case .nemotron: return "Nemotron 3.5"
        case .whisper: return "Whisper"
        case .custom: return L10n.text("Custom model")
        }
    }

    public static func available(in mode: TranscriptionMode) -> [Self] {
        mode == .api ? [.whisper, .custom] : allCases
    }
    public static func selected(for model: String, in mode: TranscriptionMode = .server) -> Self {
        available(in: mode).first { $0 != .custom && $0.rawValue == model } ?? .custom
    }
}

public struct TranscriptionSettings: Codable, Equatable, Sendable {
    public var mode: TranscriptionMode = .local
    public var localModel: LocalModel = .base
    public var localLanguage = "ru"
    public var localTimeoutMinutes = 120
    public var server = ConnectionSettings.defaults
    public var api = ConnectionSettings(baseURL: "https://api.openai.com/v1", model: "whisper-1")

    public static let defaults = TranscriptionSettings()
    public init() {}

    public var connection: ConnectionSettings {
        get { mode == .api ? api : server }
        set { if mode == .api { api = newValue } else { server = newValue } }
    }

    public var modelTitle: String { mode == .local ? localModel.title : connection.model }
    public var timeoutMinutes: Int { mode == .local ? localTimeoutMinutes : connection.timeoutMinutes }

    public func validated() throws -> Self {
        var value = self
        if mode == .local {
            value.localLanguage = localLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.localLanguage.isEmpty || value.localLanguage.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "-") }) else {
                throw TranscriptionError.invalidSettings("Use a language code such as ru or en. Leave blank for automatic detection.")
            }
            guard (1...1440).contains(localTimeoutMinutes) else {
                throw TranscriptionError.invalidSettings("The timeout must be between 1 and 1440 minutes.")
            }
        } else { value.connection = try connection.validated() }
        return value
    }

    public static let storageKey = "transcription.settings.v2"
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        if let data = defaults.data(forKey: storageKey),
           let value = try? JSONDecoder().decode(Self.self, from: data),
           let validated = try? value.validated() { return validated }
        if defaults.data(forKey: "transcription.connection.v1") != nil {
            var value = Self.defaults
            value.mode = .server
            value.server = ConnectionSettings.load(from: defaults)
            return value
        }
        return .defaults
    }

    public func save(to defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(validated()), forKey: Self.storageKey)
    }
}
