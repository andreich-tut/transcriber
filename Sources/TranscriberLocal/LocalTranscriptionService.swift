import Foundation
import AVFoundation
import TranscriberCore
import whisper

public struct LocalTranscriptionService: Sendable {
    private let settings: TranscriptionSettings
    private let store: LocalModelStore
    public init(settings: TranscriptionSettings, store: LocalModelStore = LocalModelStore()) throws {
        self.settings = try settings.validated(); self.store = store
    }

    public func transcribe(file: URL, prepared: @escaping @Sendable () async -> Void = {}) async throws -> Transcript {
        guard store.isDownloaded(settings.localModel) else { throw LocalModelError.notDownloaded }
        let control = InferenceControl(timeout: TimeInterval(settings.localTimeoutMinutes * 60))
        let worker = Task.detached(priority: .userInitiated) {
            let samples = try await Self.decode(file, control: control)
            try control.check()
            await prepared()
            return try Self.recognize(samples, model: store.url(for: settings.localModel),
                                      modelName: settings.localModel.rawValue, language: settings.localLanguage, control: control)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: {
            control.cancel(); worker.cancel()
        })
    }

    private static func decode(_ file: URL, control: InferenceControl) async throws -> [Float] {
        let asset = AVURLAsset(url: file)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw LocalModelError.decoding }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(output) else { throw LocalModelError.decoding }
        reader.add(output)
        guard reader.startReading() else { throw LocalModelError.decoding }
        defer { reader.cancelReading() }
        var samples = [Float]()
        while let buffer = output.copyNextSampleBuffer() {
            try control.check()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { throw LocalModelError.decoding }
            let length = CMBlockBufferGetDataLength(block)
            if length == 0 { continue }
            guard length % MemoryLayout<Float>.size == 0 else { throw LocalModelError.decoding }
            let count = length / MemoryLayout<Float>.size
            guard samples.count + count <= Int(Int32.max) else { throw LocalModelError.decoding }
            let start = samples.count
            samples.append(contentsOf: repeatElement(0, count: count))
            let status = samples.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                          destination: bytes.baseAddress!.advanced(by: start * MemoryLayout<Float>.size))
            }
            guard status == kCMBlockBufferNoErr else { throw LocalModelError.decoding }
        }
        guard reader.status == .completed, !samples.isEmpty else { throw LocalModelError.decoding }
        return samples
    }

    private static func recognize(_ samples: [Float], model: URL, modelName: String,
                                  language: String, control: InferenceControl) throws -> Transcript {
        let languageCode = language.isEmpty ? "auto" : language
        guard languageCode == "auto" || languageCode.withCString({ whisper_lang_id($0) }) >= 0 else {
            throw LocalModelError.unsupportedLanguage
        }
        guard let context = model.path.withCString({ whisper_init_from_file_with_params($0, whisper_context_default_params()) }) else {
            throw LocalModelError.initialization
        }
        defer { whisper_free(context) }
        try control.check()
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        params.print_realtime = false; params.print_progress = false
        params.print_timestamps = false; params.print_special = false
        params.translate = false; params.no_timestamps = false
        params.abort_callback_user_data = Unmanaged.passUnretained(control).toOpaque()
        params.abort_callback = { pointer in
            guard let pointer else { return false }
            return Unmanaged<InferenceControl>.fromOpaque(pointer).takeUnretainedValue().shouldStop
        }
        params.encoder_begin_callback_user_data = params.abort_callback_user_data
        params.encoder_begin_callback = { _, _, pointer in
            guard let pointer else { return true }
            return !Unmanaged<InferenceControl>.fromOpaque(pointer).takeUnretainedValue().shouldStop
        }
        let status = languageCode.withCString { code in
            params.language = code
            return samples.withUnsafeBufferPointer { buffer in
                whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
            }
        }
        try control.check()
        guard status == 0 else { throw LocalModelError.inference }
        var segments = [[String: Any]](), texts = [String]()
        for index in 0..<whisper_full_n_segments(context) {
            let text = String(cString: whisper_full_get_segment_text(context, index)).trimmingCharacters(in: .whitespacesAndNewlines)
            texts.append(text)
            segments.append(["start": Double(whisper_full_get_segment_t0(context, index)) / 100,
                             "end": Double(whisper_full_get_segment_t1(context, index)) / 100, "text": text])
        }
        let detectedLanguage = String(cString: whisper_lang_str(whisper_full_lang_id(context)))
        let data = try JSONSerialization.data(withJSONObject: [
            "text": texts.joined(separator: " "), "segments": segments,
            "language": detectedLanguage, "model": modelName,
            "duration": Double(samples.count) / 16000, "source": "local"
        ])
        return try Transcript.parse(data)
    }
}

private final class InferenceControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let deadline: Date
    init(timeout: TimeInterval) { deadline = Date().addingTimeInterval(timeout) }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var shouldStop: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled || Date() >= deadline
    }
    func check() throws {
        lock.lock(); let isCancelled = cancelled; lock.unlock()
        if isCancelled || Task.isCancelled { throw CancellationError() }
        if Date() >= deadline { throw LocalModelError.timeout }
    }
}
