import Foundation

public enum TranscriptionError: LocalizedError {
    case invalidFile(String), invalidSettings(String), invalidResponse(String), server(Int, String), connection, timeout
    case export(Error)
    public var errorDescription: String? {
        switch self {
        case .invalidFile(let reason): return L10n.text("Could not read the audio file. %@", L10n.text(reason))
        case .invalidSettings(let reason): return L10n.text("Could not save the settings. %@", L10n.text(reason))
        case .invalidResponse(let reason): return L10n.text("The server returned an invalid result. %@", L10n.text(reason))
        case .server(let status, let message):
            let detail = message.isEmpty ? L10n.text("The server response contains no text.") : message
            return L10n.text("Transcription server error (HTTP %d). %@", status, detail)
        case .connection: return L10n.text("Could not connect to the transcription server. Check the address in Settings and your SSH tunnel, if used.")
        case .timeout: return L10n.text("The server did not finish within the timeout. Check the server or increase the timeout in Settings.")
        case .export(let error): return L10n.text("Could not save TXT and JSON. %@", error.localizedDescription)
        }
    }
}

public struct Segment: Decodable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String
}

public struct Transcript: Sendable {
    public let text: String
    public let segments: [Segment]
    public let json: Data

    public static func parse(_ data: Data) throws -> Transcript {
        struct Response: Decodable { let text: String; let segments: [Segment]? }
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw TranscriptionError.invalidResponse("Expected a text field named text.") }
        let segments = response.segments ?? []
        guard segments.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start }) else {
            throw TranscriptionError.invalidResponse("Segment timestamps are invalid.")
        }
        // Preserve every server field, including language, duration and segment metadata.
        let object = try JSONSerialization.jsonObject(with: data)
        let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return Transcript(text: response.text, segments: segments, json: pretty)
    }
}

public struct MultipartBody {
    public let url: URL
    public let boundary: String
    public let size: Int64
    public func remove() { try? FileManager.default.removeItem(at: url) }

    public static func build(file: URL, model: String = "nemotron-3.5", language: String = "ru", responseFormat: String = "json") throws -> MultipartBody {
        try Task.checkCancellation()
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
            throw TranscriptionError.invalidFile("Choose a nonempty regular file.")
        }
        let boundary = "Transcriber-" + UUID().uuidString
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(boundary + ".multipart")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw TranscriptionError.invalidFile("Could not create a temporary request file.")
        }
        do {
            let output = try FileHandle(forWritingTo: url)
            defer { try? output.close() }
            func write(_ string: String) throws { try output.write(contentsOf: Data(string.utf8)) }
            var fields = [("model", model), ("response_format", responseFormat)]
            if !language.isEmpty { fields.append(("language", language)) }
            for (name, value) in fields {
                try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
            }
            // ASCII transport filename avoids header injection and encoding ambiguities.
            let ext = file.pathExtension.filter { $0.isASCII && $0.isLetter || $0.isNumber }.prefix(12)
            let filename = ext.isEmpty ? "audio" : "audio.\(ext)"
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n")
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            while true {
                try Task.checkCancellation()
                guard let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
                try output.write(contentsOf: chunk)
            }
            try write("\r\n--\(boundary)--\r\n")
            let size = try output.offset()
            return MultipartBody(url: url, boundary: boundary, size: Int64(size))
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}

public struct TranscriptionService {
    public static let baseURL = URL(string: "http://127.0.0.1:18000/v1")!
    public static let endpoint = baseURL.appendingPathComponent("audio/transcriptions")
    private let endpoint: URL
    private let timeout: TimeInterval
    private let model: String
    private let language: String
    private let responseFormat: String
    private let apiKey: String
    public init(endpoint: URL = Self.endpoint, timeout: TimeInterval = 7200,
                model: String = "nemotron-3.5", language: String = "ru",
                responseFormat: String = "json", apiKey: String = "") {
        self.endpoint = endpoint; self.timeout = timeout
        self.model = model; self.language = language; self.responseFormat = responseFormat; self.apiKey = apiKey
    }
    public init(settings: ConnectionSettings, apiKey: String = "") throws {
        let value = try settings.validated()
        guard apiKey.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw TranscriptionError.invalidSettings("The API key must not contain line breaks.")
        }
        self.init(endpoint: try value.transcriptionEndpoint(), timeout: TimeInterval(value.timeoutMinutes * 60),
                  model: value.model, language: value.language, responseFormat: value.responseFormat.rawValue, apiKey: apiKey)
    }

    public func transcribe(file: URL, prepared: @escaping @Sendable () async -> Void = {}) async throws -> Transcript {
        let worker = Task.detached(priority: .userInitiated) {
            try MultipartBody.build(file: file, model: model, language: language, responseFormat: responseFormat)
        }
        let body = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        defer { body.remove() }
        try Task.checkCancellation()
        await prepared()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("multipart/form-data; boundary=\(body.boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(String(body.size), forHTTPHeaderField: "Content-Length")
        if !apiKey.isEmpty { request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization") }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.upload(for: request, fromFile: body.url)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw TranscriptionError.invalidResponse("No HTTP status received.") }
            guard (200..<300).contains(http.statusCode) else {
                // Bound error output and avoid dumping the entire response or audio.
                let snippet = String(data: Data(data.prefix(1500)), encoding: .utf8) ?? ""
                throw TranscriptionError.server(http.statusCode, snippet)
            }
            return try Transcript.parse(data)
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw TranscriptionError.timeout
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet: throw TranscriptionError.connection
            default: throw error
            }
        }
    }
}

public struct ExportedFiles {
    public let text: URL
    public let json: URL
}

public enum TranscriptExporter {
    public static func save(_ transcript: Transcript, source: URL, directory: URL) throws -> ExportedFiles {
        let base = source.deletingPathExtension().lastPathComponent
        let stem = base.isEmpty ? "transcript" : base
        for index in 0..<10000 {
            let name = index == 0 ? stem : "\(stem)-\(index)"
            let txt = directory.appendingPathComponent(name + ".txt")
            let json = directory.appendingPathComponent(name + ".json")
            if FileManager.default.fileExists(atPath: txt.path) || FileManager.default.fileExists(atPath: json.path) { continue }
            var wroteText = false
            do {
                // Exclusive creation also protects against a collision after the existence check.
                try Data((transcript.text + "\n").utf8).write(to: txt, options: .withoutOverwriting)
                wroteText = true
                try transcript.json.write(to: json, options: .withoutOverwriting)
                return ExportedFiles(text: txt, json: json)
            } catch {
                if wroteText { try? FileManager.default.removeItem(at: txt) }
                let ns = error as NSError
                if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteFileExistsError { continue }
                throw error
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}
