import SwiftUI
import Security
import TranscriberCore

enum APIKeyStore {
    private static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.transcriber.connection",
         kSecAttrAccount as String: account]
    }
    static func read(account: String = "api-key") throws -> String {
        var query = self.query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw keychainError(status)
        }
        return key
    }
    static func save(_ key: String, account: String = "api-key") throws {
        let query = self.query(account: account)
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
            return
        }
        let data = Data(key.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw keychainError(status) }
    }
    private struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            L10n.text("Could not read or save the API key in macOS Keychain. Code: %d.", status)
        }
    }
    private static func keychainError(_ status: OSStatus) -> KeychainError {
        KeychainError(status: status)
    }
}

struct ConnectionSettingsView: View {
    @ObservedObject var model: TranscriberModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TranscriptionSettings
    @State private var serverKey: String
    @State private var externalKey: String
    @State private var preset: ServerModelPreset
    @State private var error: Error?
    @AppStorage("appearance.theme") private var theme = AppTheme.system
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system

    init(model: TranscriberModel) {
        self.model = model
        _draft = State(initialValue: model.settings)
        _serverKey = State(initialValue: model.serverKey)
        _externalKey = State(initialValue: model.externalKey)
        _preset = State(initialValue: .selected(for: model.settings.connection.model, in: model.settings.mode))
    }

    // Share the same label column across every settings section and processing mode.
    private let labelColumnWidth: CGFloat = 170
    private let columnSpacing: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("Settings")).font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    settingsRow("Theme") {
                        Picker("", selection: $theme) {
                            ForEach(AppTheme.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.pickerStyle(.menu).labelsHidden().accessibilityLabel(L10n.text("Theme"))
                            .accessibilityIdentifier("appearance-theme")
                    }
                    fieldCaption("The system theme follows macOS settings. Changes apply immediately.")
                    settingsRow("Interface language") {
                        Picker("", selection: $language) {
                            ForEach(AppLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.pickerStyle(.menu).labelsHidden().accessibilityLabel(L10n.text("Interface language"))
                            .accessibilityIdentifier("interface-language")
                    }
                    fieldCaption("Follows the preferred macOS language: Russian or English. Changes apply immediately.")
                    Divider()
                    Text(L10n.text("Transcription")).font(.headline)
                    settingsRow("Processing mode") {
                        Picker("", selection: $draft.mode) {
                            ForEach(TranscriptionMode.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented).labelsHidden().accessibilityLabel(L10n.text("Processing mode"))
                            .accessibilityIdentifier("transcription-mode")
                            .onChange(of: draft.mode) { _ in
                                preset = .selected(for: draft.connection.model, in: draft.mode); error = nil
                            }
                    }
                    if draft.mode == .local { localSettings }
                    else { serverSettings }
                    languageAndTimeout
                    if let error {
                        Text(error.localizedDescription).font(.callout).foregroundStyle(.red)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.trailing, 8)
            }
            Divider()
            HStack {
                Spacer()
                Button(L10n.text("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("Save")) {
                    do { try model.updateSettings(draft, serverKey: serverKey, externalKey: externalKey); dismiss() }
                    catch { self.error = error }
                }.keyboardShortcut(.defaultAction).accessibilityIdentifier("settings-save")
            }
        }.padding(24).frame(width: 660, height: 730)
    }

    private var localSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            fieldCaption("Download a model once. Transcription then runs on this Mac without an internet connection.")
            settingsRow("Model") {
                Picker("", selection: $draft.localModel) {
                    ForEach(LocalModel.allCases, id: \.self) { value in
                        Text("\(value.title) — \(value.sizeLabel)").tag(value)
                    }
                }.labelsHidden().accessibilityLabel(L10n.text("Model")).accessibilityIdentifier("local-model")
            }
            fieldCaption("Base is the default. Tiny uses less space; Small and Large v3 Turbo offer higher accuracy. All models support Russian and English.")
            settingsRow {
                HStack {
                    Image(systemName: model.downloadedModels.contains(draft.localModel) ? "checkmark.circle.fill" : "arrow.down.circle")
                        .foregroundStyle(model.downloadedModels.contains(draft.localModel) ? Color.green : Color.secondary)
                    Text(L10n.text(model.downloadedModels.contains(draft.localModel) ? "Downloaded" : "Not downloaded"))
                    Spacer()
                    if model.downloadedModels.contains(draft.localModel) {
                        Button(L10n.text("Show in Finder")) {
                            NSWorkspace.shared.activateFileViewerSelecting([model.modelStore.url(for: draft.localModel)])
                        }
                        Button(L10n.text("Remove model")) { model.removeModel(draft.localModel) }
                            .disabled(model.downloadingModel == draft.localModel)
                    } else {
                        Button(L10n.text("Download model")) { model.download(draft.localModel) }
                            .disabled(model.downloadingModel != nil).accessibilityIdentifier("download-model")
                    }
                }
            }
            if let downloading = model.downloadingModel {
                settingsRow {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("\(downloading.title) • \(L10n.text(model.downloadStatusKey))")
                        ProgressView(value: model.downloadProgress)
                        HStack {
                            Text("\(Int(model.downloadProgress * 100))% \(L10n.text("of")) \(downloading.sizeLabel)")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(L10n.text("Cancel download"), action: model.cancelDownload)
                        }
                    }
                }
            } else if !model.downloadStatusKey.isEmpty {
                fieldCaption(model.downloadStatusKey)
            }
            if let downloadError = model.downloadError {
                settingsRow {
                    Text(downloadError.localizedDescription).font(.callout).foregroundStyle(.red)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            fieldCaption("Downloaded models are kept when you close or cancel Settings.")
        }
    }

    private var serverSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            fieldCaption(draft.mode == .server
                ? "Connect to an OpenAI-compatible server on localhost or a remote computer. The server manages its models."
                : "Connect to an OpenAI-compatible transcription API. Your audio is sent to this address.")
            VStack(alignment: .leading, spacing: 10) {
                settingsRow("Base URL") {
                    TextField("", text: connectionBinding(\.baseURL))
                        .accessibilityLabel(L10n.text("Base URL")).accessibilityIdentifier("connection-base-url")
                }
                fieldCaption("Example: http://127.0.0.1:18000/v1. The /audio/transcriptions path is added automatically.")
                settingsRow("Model") {
                    Picker("", selection: $preset) {
                        ForEach(ServerModelPreset.available(in: draft.mode), id: \.self) {
                            Text($0.title).tag($0)
                        }
                    }.labelsHidden().accessibilityLabel(L10n.text("Model")).accessibilityIdentifier("connection-model-preset")
                        .onChange(of: preset) { value in
                            if value != .custom { draft.connection.model = value.rawValue }
                        }
                }
                if preset == .custom {
                    settingsRow("Model name") {
                        TextField("", text: connectionBinding(\.model))
                            .accessibilityLabel(L10n.text("Model name")).accessibilityIdentifier("connection-model")
                    }
                }
                settingsRow("API key") {
                    SecureField("", text: draft.mode == .api ? $externalKey : $serverKey)
                        .accessibilityLabel(L10n.text("API key")).accessibilityIdentifier("connection-api-key")
                }
                fieldCaption("Optional for servers without authentication. Keys for Server and External API are stored separately in macOS Keychain.")
                settingsRow("Response format") {
                    Picker("", selection: connectionBinding(\.responseFormat)) {
                        Text(L10n.text("JSON: text")).tag(ConnectionSettings.ResponseFormat.json)
                        Text(L10n.text("Verbose JSON: text and timestamps")).tag(ConnectionSettings.ResponseFormat.verboseJSON)
                    }.labelsHidden().accessibilityLabel(L10n.text("Response format"))
                }
            }.textFieldStyle(.roundedBorder)
        }
    }

    private var languageAndTimeout: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsRow("Transcription language") {
                TextField("", text: draft.mode == .local ? $draft.localLanguage : connectionBinding(\.language))
                    .accessibilityLabel(L10n.text("Transcription language")).accessibilityIdentifier("connection-language")
            }
            fieldCaption("Use a language code such as ru or en. Leave blank for automatic detection.")
            settingsRow("Timeout, minutes") {
                TextField("", value: draft.mode == .local ? $draft.localTimeoutMinutes : connectionBinding(\.timeoutMinutes),
                          format: .number.grouping(.never))
                    .accessibilityLabel(L10n.text("Timeout, minutes")).accessibilityIdentifier("connection-timeout")
            }
        }.textFieldStyle(.roundedBorder)
    }

    private func settingsRow<Content: View>(_ label: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: columnSpacing) {
            if let label {
                Text(L10n.text(label)).multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: labelColumnWidth, alignment: .trailing)
            } else {
                Color.clear.frame(width: labelColumnWidth, height: 0).accessibilityHidden(true)
            }
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func fieldCaption(_ key: String) -> some View {
        settingsRow { caption(L10n.text(key)) }
    }
    private func connectionBinding<Value>(_ keyPath: WritableKeyPath<ConnectionSettings, Value>) -> Binding<Value> {
        Binding(get: { draft.connection[keyPath: keyPath] }, set: { draft.connection[keyPath: keyPath] = $0 })
    }
    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
}
