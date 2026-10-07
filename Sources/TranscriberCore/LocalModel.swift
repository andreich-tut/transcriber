import Foundation
import CryptoKit

public enum LocalModel: String, Codable, CaseIterable, Sendable {
    case tiny, base, small, largeTurbo = "large-v3-turbo"

    public var title: String {
        switch self {
        case .tiny: return "Whisper Tiny"
        case .base: return "Whisper Base"
        case .small: return "Whisper Small"
        case .largeTurbo: return "Whisper Large v3 Turbo"
        }
    }
    public var byteCount: Int64 {
        switch self {
        case .tiny: return 77_691_713
        case .base: return 147_951_465
        case .small: return 487_601_967
        case .largeTurbo: return 1_624_555_275
        }
    }
    public var sha256: String {
        switch self {
        case .tiny: return "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21"
        case .base: return "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"
        case .small: return "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"
        case .largeTurbo: return "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
        }
    }
    public var filename: String { "ggml-\(rawValue).bin" }
    public var downloadURL: URL {
        // Pin weights and verify their published LFS checksum before installation.
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/\(filename)")!
    }
    public var sizeLabel: String { ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file) }
}

public enum LocalModelError: LocalizedError {
    case notDownloaded, invalidDownload, initialization, decoding, unsupportedLanguage, inference, timeout

    public var errorDescription: String? {
        switch self {
        case .notDownloaded: return L10n.text("Download the selected model in Settings before transcribing on this Mac.")
        case .invalidDownload: return L10n.text("The model download is incomplete or damaged. Please download it again.")
        case .initialization: return L10n.text("Could not load the local model. Try a smaller model or download it again.")
        case .decoding: return L10n.text("Could not decode the audio on this Mac. Try a WAV, MP3, or M4A file.")
        case .unsupportedLanguage: return L10n.text("The local model does not support this language code. Use ru, en, or leave it blank.")
        case .inference: return L10n.text("Local transcription failed. Try a smaller model.")
        case .timeout: return L10n.text("Local transcription exceeded the timeout. Try a smaller model or increase the timeout in Settings.")
        }
    }
}

public struct LocalModelStore: Sendable {
    public let directory: URL
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcriber/Models", isDirectory: true)
    }
    public func url(for model: LocalModel) -> URL { directory.appendingPathComponent(model.filename) }
    public func isDownloaded(_ model: LocalModel) -> Bool {
        guard let values = try? url(for: model).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
        return values.isRegularFile == true && Int64(values.fileSize ?? 0) == model.byteCount
    }
    public func remove(_ model: LocalModel) throws { try FileManager.default.removeItem(at: url(for: model)) }

    public func download(_ model: LocalModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await download(model, from: model.downloadURL, progress: progress)
    }

    func download(_ model: LocalModel, from source: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        if isDownloaded(model) { progress(1); return }
        let temporary = try await ModelDownload(expectedSize: model.byteCount, progress: progress).download(from: source)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let worker = Task.detached {
            try Self.verify(file: temporary, byteCount: model.byteCount, sha256: model.sha256)
        }
        try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Move only a complete, verified file into the model catalog.
        let destination = url(for: model)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else { try FileManager.default.moveItem(at: temporary, to: destination) }
        progress(1)
    }

    static func verify(file: URL, byteCount: Int64, sha256: String) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == byteCount else { throw LocalModelError.invalidDownload }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else { break }
            hash.update(data: data)
        }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == sha256 else { throw LocalModelError.invalidDownload }
    }
}

private final class ModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expectedSize: Int64
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var cancelled = false
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var continuation: CheckedContinuation<URL, Error>?
    // Delegate callbacks run on URLSession's serial delegate queue.
    private var stagedFile: URL?
    private var fileError: Error?

    init(expectedSize: Int64, progress: @escaping @Sendable (Double) -> Void) {
        self.expectedSize = expectedSize; self.progress = progress
    }
    func download(from source: URL) async throws -> URL {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 60
                config.timeoutIntervalForResource = 24 * 60 * 60
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                let task = session.downloadTask(with: source)
                lock.lock()
                self.continuation = continuation; self.session = session; self.task = task
                let shouldCancel = cancelled
                lock.unlock()
                task.resume()
                if shouldCancel { task.cancel() }
            }
        }, onCancel: { self.cancel() })
    }
    private func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel()
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(min(0.99, Double(totalBytesWritten) / Double(expectedSize)))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let http = downloadTask.response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            fileError = LocalModelError.invalidDownload; return
        }
        // URLSession removes its temporary file as soon as this callback returns.
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".model-download")
        do { try FileManager.default.moveItem(at: location, to: staged); stagedFile = staged }
        catch { fileError = error }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = continuation, isCancelled = cancelled
        self.continuation = nil; self.task = nil; self.session = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        if isCancelled || error != nil || fileError != nil {
            if let stagedFile { try? FileManager.default.removeItem(at: stagedFile) }
            continuation?.resume(throwing: isCancelled ? CancellationError() : (error ?? fileError!))
        } else if let stagedFile { continuation?.resume(returning: stagedFile) }
        else { continuation?.resume(throwing: LocalModelError.invalidDownload) }
    }
}
