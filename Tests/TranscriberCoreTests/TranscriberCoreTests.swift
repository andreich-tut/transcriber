import XCTest
@testable import TranscriberCore

final class TranscriberCoreTests: XCTestCase {
    private static var server: Process!
    private static var serverOutput: Pipe!
    private static var port: Int!
    private var directory: URL!
    private var audio: URL!
    private let sample = Data(#"{"text":"Привет, мир.","language":"ru","duration":1.5,"segments":[{"id":0,"start":0,"end":1.5,"text":"Привет, мир.","avg_logprob":-0.12}]}"#.utf8)

    override class func setUp() {
        super.setUp()
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("mock_transcription_server.py")
        server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [script.path]
        serverOutput = Pipe(); server.standardOutput = serverOutput
        do {
            try server.run()
            var line = Data()
            while let byte = try serverOutput.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
                if byte == Data([10]) { break }; line.append(byte)
            }
            port = Int(String(decoding: line, as: UTF8.self))
        } catch { XCTFail("Local mock server could not start: \(error)") }
    }
    override class func tearDown() {
        if server?.isRunning == true { server.terminate(); server.waitUntilExit() }
        super.tearDown()
    }
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        audio = directory.appendingPathComponent("пример.wav")
        try Data("fixture-audio-bytes".utf8).write(to: audio)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func service(_ path: String, timeout: TimeInterval = 7200) -> TranscriptionService {
        TranscriptionService(endpoint: URL(string: "http://127.0.0.1:\(Self.port!)/\(path)")!, timeout: timeout)
    }
    func testMultipartUploadAndMetadata() async throws {
        let transcript = try await service("ok").transcribe(file: audio)
        XCTAssertEqual(transcript.text, "Привет, мир.")
        XCTAssertEqual(transcript.segments.first?.end, 1.5)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: transcript.json) as? [String: Any])
        XCTAssertEqual(json["language"] as? String, "ru")
        XCTAssertEqual(json["duration"] as? Double, 1.5)
        XCTAssertEqual((json["segments"] as? [[String: Any]])?.first?["avg_logprob"] as? Double, -0.12)
    }
    func testTextOnlyProxyResponse() async throws {
        let transcript = try await service("text-only").transcribe(file: audio)
        XCTAssertEqual(transcript.text, "Привет, мир.")
        XCTAssertTrue(transcript.segments.isEmpty)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: transcript.json) as? [String: Any])
        XCTAssertEqual(json["text"] as? String, "Привет, мир.")
        XCTAssertNil(json["segments"])
        let output = try TranscriptExporter.save(transcript, source: audio, directory: directory)
        XCTAssertEqual(try String(contentsOf: output.text), "Привет, мир.\n")
        XCTAssertEqual(try Data(contentsOf: output.json), transcript.json)
    }
    func testConfiguredEndpointModelFormatAutoLanguageAndAuthorization() async throws {
        let settings = ConnectionSettings(baseURL: "http://127.0.0.1:\(Self.port!)/configured/v1", model: "whisper-1",
                                          language: "", responseFormat: .verboseJSON, timeoutMinutes: 1)
        let transcript = try await TranscriptionService(settings: settings, apiKey: "fixture-test-key").transcribe(file: audio)
        XCTAssertEqual(transcript.text, "Привет, мир.")
    }
    func testHTTPError() async throws {
        do { _ = try await service("http-error").transcribe(file: audio); XCTFail("Expected HTTP error") }
        catch TranscriptionError.server(let status, let message) { XCTAssertEqual(status, 503); XCTAssertTrue(message.contains("Model unavailable")) }
    }
    func testInvalidServerResponse() async throws {
        do { _ = try await service("invalid").transcribe(file: audio); XCTFail("Expected malformed response") }
        catch TranscriptionError.invalidResponse { }
    }
    func testTimeout() async throws {
        do { _ = try await service("slow", timeout: 0.15).transcribe(file: audio); XCTFail("Expected timeout") }
        catch TranscriptionError.timeout { }
    }
    func testCancellation() async throws {
        let file = audio!
        let service = service("slow")
        let task = Task { try await service.transcribe(file: file) }
        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }
    func testEmptyFileRejected() throws {
        try Data().write(to: audio)
        XCTAssertThrowsError(try MultipartBody.build(file: audio))
    }
    func testModelDownloadRejectsErrorsAndIncompleteWeights() async throws {
        let store = LocalModelStore(directory: directory.appendingPathComponent("models"))
        for path in ["model-error", "incomplete-model"] {
            do {
                try await store.download(.tiny, from: URL(string: "http://127.0.0.1:\(Self.port!)/\(path)")!) { _ in }
                XCTFail("Expected an invalid download")
            } catch LocalModelError.invalidDownload { }
            XCTAssertFalse(store.isDownloaded(.tiny))
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: .tiny).path))
        }
    }
    func testModelDownloadCancellationDoesNotInstallPartialWeights() async throws {
        let store = LocalModelStore(directory: directory.appendingPathComponent("models"))
        let source = URL(string: "http://127.0.0.1:\(Self.port!)/slow-model")!
        let progress = expectation(description: "Download started")
        progress.assertForOverFulfill = false
        let task = Task {
            try await store.download(.tiny, from: source) { value in if value > 0 { progress.fulfill() } }
        }
        await fulfillment(of: [progress], timeout: 5)
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: .tiny).path))
    }
    func testMalformedTimestampsRejected() {
        for json in [#"{"text":"x","segments":[{"start":2,"end":1,"text":"x"}]}"#,
                     #"{"text":"x","segments":[{"start":-1,"end":1,"text":"x"}]}"#] {
            XCTAssertThrowsError(try Transcript.parse(Data(json.utf8)))
        }
    }
    func testSilenceAccepted() throws {
        let transcript = try Transcript.parse(Data(#"{"text":"","segments":[]}"#.utf8))
        XCTAssertTrue(transcript.text.isEmpty)
    }
    func testExportDoesNotOverwriteEitherFile() throws {
        let transcript = try Transcript.parse(sample)
        let existingJSON = directory.appendingPathComponent("пример.json")
        try Data("keep-json".utf8).write(to: existingJSON)
        let first = try TranscriptExporter.save(transcript, source: audio, directory: directory)
        let second = try TranscriptExporter.save(transcript, source: audio, directory: directory)
        XCTAssertEqual(first.text.lastPathComponent, "пример-1.txt")
        XCTAssertEqual(second.json.lastPathComponent, "пример-2.json")
        XCTAssertEqual(try String(contentsOf: existingJSON), "keep-json")
        XCTAssertEqual(try String(contentsOf: first.text), "Привет, мир.\n")
        XCTAssertEqual(try Data(contentsOf: first.json), transcript.json)
        XCTAssertEqual(try Data(contentsOf: second.json), transcript.json)
    }
    func testExportPreservesExistingText() throws {
        let existing = directory.appendingPathComponent("пример.txt")
        try Data("keep-text".utf8).write(to: existing)
        let output = try TranscriptExporter.save(try Transcript.parse(sample), source: audio, directory: directory)
        XCTAssertEqual(output.text.lastPathComponent, "пример-1.txt")
        XCTAssertEqual(try String(contentsOf: existing), "keep-text")
    }
    func testExportFailureLeavesNoPartialText() throws {
        let transcript = try Transcript.parse(sample)
        let nonexistent = directory.appendingPathComponent("missing")
        XCTAssertThrowsError(try TranscriptExporter.save(transcript, source: audio, directory: nonexistent))
        XCTAssertFalse(FileManager.default.fileExists(atPath: nonexistent.appendingPathComponent("пример.txt").path))
    }
}
