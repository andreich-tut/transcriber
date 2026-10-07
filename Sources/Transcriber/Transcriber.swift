import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TranscriberCore
import TranscriberLocal

@main
struct TranscriberApp: App {
    @StateObject private var model = TranscriberModel()
    @AppStorage("appearance.theme") private var theme = AppTheme.system
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system
    var body: some Scene {
        WindowGroup("Transcriber") {
            ContentView(model: model)
                .environment(\.locale, Locale(identifier: language.resolvedCode()))
                .onAppear { theme.apply() }
                .onChange(of: theme) { value in value.apply() }
        }
            .defaultSize(width: 860, height: 660)
            .commands {
                CommandGroup(replacing: .newItem) {}
                CommandGroup(replacing: .appSettings) {
                    Button(L10n.text("Settings…")) { model.showSettings = true }
                        .keyboardShortcut(",", modifiers: .command).disabled(model.busy)
                }
            }
    }
}

@MainActor
final class TranscriberModel: ObservableObject {
    @Published var file: URL?
    @Published var fileSize: String = ""
    @Published var result: Transcript?
    @Published var busy = false
    @Published private var statusKey = "Choose an audio file to transcribe."
    var status: String {
        if statusKey == "Done. Timestamped segments: %d." {
            return L10n.text(statusKey, result?.segments.count ?? 0)
        }
        return L10n.text(statusKey)
    }
    @Published var error: Error?
    @Published var started: Date?
    @Published var exported: ExportedFiles?
    @Published var confirmDiscard = false
    @Published var showSettings = false
    @Published private(set) var settings = TranscriptionSettings.load()
    private(set) var serverKey = ""
    private(set) var externalKey = ""
    @Published private(set) var downloadedModels = Set<LocalModel>()
    @Published private(set) var downloadingModel: LocalModel?
    @Published private(set) var downloadProgress = 0.0
    @Published private(set) var downloadStatusKey = ""
    @Published var downloadError: Error?
    let modelStore = LocalModelStore()
    private var downloadTask: Task<Void, Never>?
    var localModelReady: Bool { downloadedModels.contains(settings.localModel) }
    var canTranscribe: Bool { settings.mode != .local || localModelReady }
    @Published var completedIn: TimeInterval?

    init() {
        downloadedModels = Set(LocalModel.allCases.filter { modelStore.isDownloaded($0) })
        do {
            serverKey = try APIKeyStore.read()
            externalKey = try APIKeyStore.read(account: "external-api-key")
        }
        catch { self.error = error }
    }

    func updateSettings(_ draft: TranscriptionSettings, serverKey: String, externalKey: String) throws {
        let value = try draft.validated()
        let serverKey = serverKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let externalKey = externalKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard [serverKey, externalKey].allSatisfy({ $0.rangeOfCharacter(from: .controlCharacters) == nil }) else {
            throw TranscriptionError.invalidSettings("The API key must not contain line breaks.")
        }
        if value.mode != .local {
            _ = try TranscriptionService(settings: value.connection, apiKey: value.mode == .api ? externalKey : serverKey)
        }
        if serverKey != self.serverKey { try APIKeyStore.save(serverKey); self.serverKey = serverKey }
        if externalKey != self.externalKey { try APIKeyStore.save(externalKey, account: "external-api-key"); self.externalKey = externalKey }
        try value.save()
        settings = value
    }

    func download(_ model: LocalModel) {
        guard downloadingModel == nil, !downloadedModels.contains(model) else { return }
        downloadingModel = model; downloadProgress = 0; downloadError = nil
        downloadStatusKey = "Downloading model…"
        downloadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.downloadingModel = nil; self.downloadTask = nil }
            do {
                try await self.modelStore.download(model) { [weak self] progress in
                    Task { @MainActor in
                        guard self?.downloadingModel == model else { return }
                        self?.downloadProgress = progress
                        if progress >= 0.99 { self?.downloadStatusKey = "Verifying model…" }
                    }
                }
                self.downloadedModels.insert(model)
                self.downloadStatusKey = "Model downloaded. Ready for offline transcription."
            } catch is CancellationError {
                self.downloadStatusKey = "Model download cancelled. You can retry."
            } catch let error as URLError where error.code == .cancelled {
                self.downloadStatusKey = "Model download cancelled. You can retry."
            } catch { self.downloadError = error; self.downloadStatusKey = "Model download failed. You can retry." }
        }
    }
    func cancelDownload() { downloadTask?.cancel() }
    func removeModel(_ model: LocalModel) {
        guard !busy, downloadingModel != model else { return }
        do { try modelStore.remove(model); downloadedModels.remove(model); downloadError = nil; downloadStatusKey = "" }
        catch { downloadError = error }
    }
    private var task: Task<Void, Never>?
    private var pendingAction: (() -> Void)?

    func requestSelection() {
        guard !busy else { return }
        if result != nil && exported == nil {
            pendingAction = { [weak self] in self?.selectFile() }
            confirmDiscard = true
        } else { selectFile() }
    }
    func acceptDiscard() { let action = pendingAction; pendingAction = nil; action?() }
    func rejectDiscard() { pendingAction = nil }
    private func selectFile() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("Choose an audio file")
        panel.prompt = L10n.text("Choose")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // Containers such as MP4 may carry audio, so offer a broad file picker.
        panel.allowedContentTypes = [.audio, .movie, .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isReadableKey])
            guard values.isRegularFile == true, values.isReadable == true, (values.fileSize ?? 0) > 0 else {
                throw TranscriptionError.invalidFile("The file is empty or cannot be read.")
            }
            file = url
            fileSize = ByteCountFormatter.string(fromByteCount: Int64(values.fileSize ?? 0), countStyle: .file)
            result = nil; exported = nil; error = nil; completedIn = nil
            statusKey = "File selected. You can start transcription."
        } catch { self.error = error }
    }
    func start() {
        guard !busy, canTranscribe, let file, result == nil else { return }
        busy = true; error = nil; exported = nil; completedIn = nil; started = Date()
        let settings = settings, key = settings.mode == .api ? externalKey : serverKey
        statusKey = "Preparing audio file…"
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.started = nil; self.task = nil }
            do {
                let result: Transcript
                if settings.mode == .local {
                    let service = try LocalTranscriptionService(settings: settings, store: self.modelStore)
                    result = try await service.transcribe(file: file) { [weak self] in
                        await self?.setRecognizing()
                    }
                } else {
                    let service = try TranscriptionService(settings: settings.connection, apiKey: key)
                    result = try await service.transcribe(file: file) { [weak self] in
                        await self?.setUploading()
                    }
                }
                try Task.checkCancellation()
                self.completedIn = self.started.map { Date().timeIntervalSince($0) }
                self.result = result
                self.statusKey = result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Processing complete: no speech detected. You can save the result."
                    : (result.segments.isEmpty
                        ? "Done. Text received. The server did not provide timestamps."
                        : "Done. Timestamped segments: %d.")
            } catch is CancellationError {
                self.statusKey = "Processing cancelled. You can retry the request."
            } catch {
                self.error = error
                self.statusKey = "Transcription did not finish. You can retry the request."
            }
        }
    }
    private func setUploading() { statusKey = "Uploading and transcribing… Waiting for the server response." }
    private func setRecognizing() { statusKey = "Transcribing on this Mac…" }
    func cancel() { task?.cancel(); statusKey = "Cancelling request…" }
    func save() {
        guard let result, let file, !busy else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.text("Folder for TXT and JSON")
        panel.prompt = L10n.text("Save here")
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do {
            exported = try TranscriptExporter.save(result, source: file, directory: directory)
            error = nil
            statusKey = "TXT and JSON saved. Existing files were preserved; a number was added for duplicate names."
        } catch { self.error = TranscriptionError.export(error) }
    }
    func showExport() {
        if let exported { NSWorkspace.shared.activateFileViewerSelecting([exported.text, exported.json]) }
    }
}

struct ContentView: View {
    @ObservedObject var model: TranscriberModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Transcriber").font(.title2.bold())
                    Text(L10n.text("Audio to text • %@", model.settings.modelTitle)).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.showSettings = true } label: {
                    Label(L10n.text("Settings…"), systemImage: "gearshape")
                }.disabled(model.busy)
                Button(L10n.text("Choose audio file…"), action: model.requestSelection).disabled(model.busy)
            }
            GroupBox {
                HStack {
                    Image(systemName: "waveform").font(.title2).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.file?.lastPathComponent ?? L10n.text("No audio file selected")).font(.headline).lineLimit(2)
                        if let file = model.file {
                            Text("\(model.fileSize) • \(file.deletingLastPathComponent().path)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                        }
                    }
                    Spacer()
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            HStack {
                Button(L10n.text("Transcribe"), action: model.start)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.file == nil || model.busy || model.result != nil || !model.canTranscribe)
                if model.busy {
                    ProgressView().controlSize(.small)
                    Button(L10n.text("Cancel"), action: model.cancel)
                }
                Spacer()
                Button(L10n.text("Save TXT and JSON…"), action: model.save).disabled(model.result == nil || model.busy)
            }
            VStack(alignment: .leading, spacing: 5) {
                if model.settings.mode == .local && !model.localModelReady {
                    Text(L10n.text("Download the selected model in Settings before transcribing on this Mac."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text(model.status).font(.callout).accessibilityIdentifier("processing-status")
                if let started = model.started {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(L10n.text("Elapsed: %@. Maximum wait: %d min.", elapsed(context.date.timeIntervalSince(started)), model.settings.timeoutMinutes))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let duration = model.completedIn {
                Text(L10n.text("Processing time: %@.", elapsed(duration))).font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error.localizedDescription).textSelection(.enabled).font(.callout)
                    Spacer()
                    Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help(L10n.text("Dismiss error"))
                }.padding(10).background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let result = model.result {
                        Text(result.text.isEmpty ? L10n.text("No speech detected.") : result.text)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        if !result.segments.isEmpty {
                            Divider()
                            Text(L10n.text("Timestamps")).font(.headline)
                            ForEach(Array(result.segments.enumerated()), id: \.offset) { _, segment in
                                HStack(alignment: .top, spacing: 12) {
                                    Text("\(timestamp(segment.start)) – \(timestamp(segment.end))")
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 165, alignment: .leading)
                                    Text(segment.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    } else {
                        Text(L10n.text("The transcription will appear here."))
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(14)
            }.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
            if let exported = model.exported {
                HStack {
                    Text(L10n.text("Saved: %@, %@", exported.text.lastPathComponent, exported.json.lastPathComponent))
                        .font(.caption).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    Button(L10n.text("Show in Finder"), action: model.showExport)
                }
            }
            Text(model.settings.mode == .local ? L10n.text("On this Mac • Audio stays on your device") : "\(model.settings.mode.title) • \(model.settings.connection.baseURL)")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }.padding(22).frame(minWidth: 720, minHeight: 540)
            .sheet(isPresented: $model.showSettings) { ConnectionSettingsView(model: model) }
            .confirmationDialog(L10n.text("The current result has not been saved"), isPresented: $model.confirmDiscard, titleVisibility: .visible) {
                Button(L10n.text("Choose a new file"), role: .destructive, action: model.acceptDiscard)
                Button(L10n.text("Keep current result"), role: .cancel, action: model.rejectDiscard)
            } message: { Text(L10n.text("Choosing a new file will clear the current text from this window. Save TXT and JSON first if you need the result.")) }
    }
    private func elapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval)); return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    private func timestamp(_ interval: Double) -> String {
        let millis = Int(interval * 1000)
        return String(format: "%02d:%02d:%02d.%03d", millis / 3600000, millis / 60000 % 60, millis / 1000 % 60, millis % 1000)
    }
}
