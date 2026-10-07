import XCTest
import TranscriberCore
import TranscriberLocal

final class LocalTranscriptionTests: XCTestCase {
    func testMissingModelReportsActionableError() async throws {
        let store = LocalModelStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let service = try LocalTranscriptionService(settings: .defaults, store: store)
        do {
            _ = try await service.transcribe(file: URL(fileURLWithPath: "/nonexistent.wav"))
            XCTFail("Expected a missing-model error")
        } catch LocalModelError.notDownloaded { }
    }

    // Opt-in: downloads verified public weights and recognizes a synthetic recording.
    func testLocalRecognitionAndCancellation() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["TRANSCRIBER_TEST_MODEL_DIR"],
              let audio = environment["TRANSCRIBER_TEST_AUDIO"] else {
            throw XCTSkip("Set TRANSCRIBER_TEST_MODEL_DIR and TRANSCRIBER_TEST_AUDIO for local integration")
        }
        let store = LocalModelStore(directory: URL(fileURLWithPath: directory))
        try await store.download(.tiny) { _ in }
        XCTAssertTrue(store.isDownloaded(.tiny))
        var settings = TranscriptionSettings.defaults
        settings.localModel = .tiny; settings.localLanguage = "en"
        let service = try LocalTranscriptionService(settings: settings, store: store)
        let transcript = try await service.transcribe(file: URL(fileURLWithPath: audio))
        XCTAssertTrue(transcript.text.lowercased().contains("local transcription"), transcript.text)
        XCTAssertFalse(transcript.segments.isEmpty)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: transcript.json) as? [String: Any])
        XCTAssertEqual(object["source"] as? String, "local")
        XCTAssertEqual(object["language"] as? String, "en")
        let ready = expectation(description: "Audio decoded")
        let task = Task {
            try await service.transcribe(file: URL(fileURLWithPath: audio)) { ready.fulfill() }
        }
        await fulfillment(of: [ready], timeout: 20)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }
}
