import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(SyncUnlockStore.self) private var syncUnlockStore
    @Environment(TerminalSessionManager.self) private var terminalSessionManager
    @Environment(SecureSecretStore.self) private var secureSecretStore
    @Environment(\.modelContext) private var modelContext

    @AppStorage("appTheme") private var appThemeRawValue = AppTheme.system.rawValue
    @AppStorage("terminalFontSize") private var terminalFontSize = 14.0
    @AppStorage("selectedAIProvider") private var selectedAIProviderRawValue = AIProvider.openAI.rawValue
    @AppStorage("openAIBaseURL") private var openAIBaseURL = LLMProviderConfiguration.defaultOpenAIBaseURLString
    @AppStorage("openAIModelID") private var openAIModelID = LLMProviderConfiguration.defaultOpenAIModelID
    @AppStorage("geminiBaseURL") private var geminiBaseURL = LLMProviderConfiguration.defaultGeminiBaseURLString
    @AppStorage("geminiModelID") private var geminiModelID = LLMProviderConfiguration.defaultGeminiModelID

    @Query(sort: \VaultProfile.createdAt) private var vaults: [VaultProfile]
    @Query(sort: \HostProfile.alias) private var hosts: [HostProfile]
    @Query(sort: \KeychainItemProfile.name) private var keychainItems: [KeychainItemProfile]
    @Query(sort: \SnippetProfile.title) private var snippets: [SnippetProfile]

    @State private var configuredProviderDescriptions: [AIProvider: String] = [:]
    @State private var editingProvider: AIProvider?
    @State private var isConfirmingSignOut = false
    @State private var isUploadingSync = false
    @State private var isSigningOut = false
    @State private var signOutError: String?

    private var selectedProvider: Binding<AIProvider> {
        Binding {
            AIProvider(rawValue: selectedAIProviderRawValue) ?? .openAI
        } set: { provider in
            selectedAIProviderRawValue = provider.rawValue
        }
    }

    var body: some View {
        Form {
            accountSection
            syncSection
            appearanceSection
            terminalSection
            aiProvidersSection
        }
        .navigationTitle("Settings")
        .task {
            await refreshConfiguredProviders()
        }
        .sheet(item: $editingProvider) { provider in
            APIKeyEditorSheet(provider: provider) {
                await refreshConfiguredProviders()
            }
        }
        .confirmationDialog(
            "Sign out and wipe local data?",
            isPresented: $isConfirmingSignOut,
            titleVisibility: .visible
        ) {
            Button(isSigningOut ? "Signing Out" : "Sign Out and Wipe This Device", role: .destructive) {
                signOut()
            }
            .disabled(isSigningOut)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The encrypted sync blob is not deleted, but local vault metadata, Keychain secrets, AI keys, and terminal sessions will be removed.")
        }
    }

    private var accountSection: some View {
        Section("Account") {
            LabeledContent("User", value: syncUnlockStore.currentUser?.displayName ?? "Signed in")
            LabeledContent("Email", value: syncUnlockStore.currentUser?.email ?? "No email")

            Button(role: .destructive) {
                isConfirmingSignOut = true
            } label: {
                Label(isSigningOut ? "Signing Out" : "Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .disabled(isSigningOut)

            if let signOutError {
                Text(signOutError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var syncSection: some View {
        Section("Encrypted Sync") {
            LabeledContent("Cloud Blob", value: syncUnlockStore.hasRemoteSyncBlob ? "Available" : "Not created")
            LabeledContent("Unlock State", value: syncUnlockStore.canUploadEncryptedSync ? "Ready" : "Locked")

            Button {
                uploadEncryptedSync()
            } label: {
                Label(isUploadingSync ? "Uploading" : "Upload Current Device Now", systemImage: "arrow.up.doc")
            }
            .disabled(!syncUnlockStore.canUploadEncryptedSync || isUploadingSync || isSigningOut)

            if !syncUnlockStore.canUploadEncryptedSync {
                Text("Enable or unlock encrypted sync from Login before uploading this device snapshot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: $appThemeRawValue) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.title).tag(theme.rawValue)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var terminalSection: some View {
        Section("Terminal") {
            HStack {
                Image(systemName: "textformat.size.smaller")
                Slider(value: $terminalFontSize, in: 10...24, step: 1)
                Image(systemName: "textformat.size.larger")
            }
            LabeledContent("Font Size", value: "\(Int(terminalFontSize)) pt")

            Text("root@myserver:~$ tail -f /var/log/syslog")
                .font(.system(size: terminalFontSize, design: .monospaced))
                .foregroundStyle(.green)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var aiProvidersSection: some View {
        Section("AI Providers") {
            Picker("Default Provider", selection: selectedProvider) {
                ForEach(AIProvider.allCases) { provider in
                    Text(provider.title).tag(provider)
                }
            }

            if selectedProvider.wrappedValue == .openAI {
                TextField("OpenAI-compatible Base URL", text: $openAIBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                TextField("OpenAI Model", text: $openAIModelID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            if selectedProvider.wrappedValue == .gemini {
                TextField("Gemini API Base URL", text: $geminiBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                TextField("Gemini Model", text: $geminiModelID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            ForEach(AIProvider.allCases) { provider in
                let description = configuredProviderDescriptions[provider]
                Button {
                    editingProvider = provider
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(provider.title)
                            Text(description ?? "Not configured")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: description == nil ? "exclamationmark.circle" : "checkmark.circle.fill")
                            .foregroundStyle(description == nil ? .orange : .green)
                    }
                }
                .foregroundStyle(.primary)
                .disabled(isSigningOut)
            }
        }
    }

    private func refreshConfiguredProviders() async {
        var descriptions: [AIProvider: String] = [:]
        for provider in AIProvider.allCases {
            guard
                let key = try? await secureSecretStore.loadAPIKey(for: provider),
                let description = provider.configuredKeyDescription(for: key)
            else {
                continue
            }
            descriptions[provider] = description
        }
        configuredProviderDescriptions = descriptions
    }

    private func signOut() {
        guard !isSigningOut else { return }
        signOutError = nil
        isSigningOut = true

        Task {
            do {
                try await secureSecretStore.deleteAll()
                try LocalDataWipeService.wipeVaultMetadata(in: modelContext)
                terminalSessionManager.clearAll()
                try await syncUnlockStore.signOut()
            } catch {
                signOutError = error.localizedDescription
            }
            isSigningOut = false
        }
    }

    private func uploadEncryptedSync() {
        isUploadingSync = true
        Task {
            await syncUnlockStore.uploadCurrentData(
                vaults: vaults,
                hosts: hosts,
                keychainItems: keychainItems,
                snippets: snippets,
                secureSecretStore: secureSecretStore
            )
            isUploadingSync = false
        }
    }
}

struct APIKeysSettingsView: View {
    @Environment(SecureSecretStore.self) private var secureSecretStore

    let focusedProvider: AIProvider?

    @State private var providerToEdit: AIProvider?
    @State private var configuredProviderDescriptions: [AIProvider: String] = [:]
    @State private var didOpenFocusedProvider = false

    init(focusedProvider: AIProvider? = nil) {
        self.focusedProvider = focusedProvider
    }

    var body: some View {
        List {
            ForEach(AIProvider.allCases) { provider in
                let description = configuredProviderDescriptions[provider]
                Button {
                    providerToEdit = provider
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(provider.title)
                            Text(description ?? "Not configured")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: description == nil ? "exclamationmark.circle" : "checkmark.circle.fill")
                            .foregroundStyle(description == nil ? .orange : .green)
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        .navigationTitle("API Keys")
        .task {
            await refreshConfiguredProviders()
            openFocusedProviderIfNeeded()
        }
        .sheet(item: $providerToEdit) { provider in
            APIKeyEditorSheet(provider: provider) {
                await refreshConfiguredProviders()
            }
        }
    }

    private func refreshConfiguredProviders() async {
        var descriptions: [AIProvider: String] = [:]
        for provider in AIProvider.allCases {
            guard
                let key = try? await secureSecretStore.loadAPIKey(for: provider),
                let description = provider.configuredKeyDescription(for: key)
            else {
                continue
            }
            descriptions[provider] = description
        }
        configuredProviderDescriptions = descriptions
    }

    private func openFocusedProviderIfNeeded() {
        guard !didOpenFocusedProvider, let focusedProvider else { return }
        providerToEdit = focusedProvider
        didOpenFocusedProvider = true
    }
}

private struct APIKeyEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SecureSecretStore.self) private var secureSecretStore
    @AppStorage("openAIBaseURL") private var openAIBaseURL = LLMProviderConfiguration.defaultOpenAIBaseURLString
    @AppStorage("openAIModelID") private var openAIModelID = LLMProviderConfiguration.defaultOpenAIModelID
    @AppStorage("geminiBaseURL") private var geminiBaseURL = LLMProviderConfiguration.defaultGeminiBaseURLString
    @AppStorage("geminiModelID") private var geminiModelID = LLMProviderConfiguration.defaultGeminiModelID

    let provider: AIProvider
    var onSave: (() async -> Void)?

    @State private var apiKey = ""
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var isSaving = false
    @State private var isTesting = false
    @State private var isDeleting = false

    private var validationMessage: String? {
        provider.validationMessage(for: apiKey)
    }

    private var isBusy: Bool {
        isSaving || isTesting || isDeleting
    }

    private var providerConfiguration: LLMProviderConfiguration {
        switch provider {
        case .openAI:
            LLMProviderConfiguration(provider: provider, baseURLString: openAIBaseURL, modelID: openAIModelID)
        case .gemini:
            LLMProviderConfiguration(provider: provider, baseURLString: geminiBaseURL, modelID: geminiModelID)
        case .anthropic:
            LLMProviderConfiguration(provider: provider, baseURLString: "", modelID: "")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(provider.title) {
                    SecureField("API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if let validationMessage, !apiKey.isEmpty {
                        Text(validationMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if let successMessage {
                        Text(successMessage)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                Section {
                    Button(isTesting ? "Testing" : "Test Connection") {
                        testConnection()
                    }
                    .disabled(validationMessage != nil || isBusy)
                }

                Section {
                    Button(role: .destructive) {
                        deleteKey()
                    } label: {
                        Label(isDeleting ? "Deleting" : "Delete Key", systemImage: "trash")
                    }
                    .disabled(isBusy)
                }
            }
            .navigationTitle("\(provider.title) Key")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving" : "Save") {
                        saveKey()
                    }
                    .disabled(validationMessage != nil || isBusy)
                }
            }
            .task {
                do {
                    apiKey = try await secureSecretStore.loadAPIKey(for: provider) ?? ""
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func testConnection() {
        guard validationMessage == nil else {
            errorMessage = validationMessage
            successMessage = nil
            return
        }

        isTesting = true
        errorMessage = nil
        successMessage = nil

        Task {
            do {
                try await AIProviderConnectionTester.testConnection(
                    for: provider,
                    apiKey: provider.normalizedKey(apiKey),
                    configuration: providerConfiguration
                )
                successMessage = "\(provider.title) connection succeeded."
            } catch {
                errorMessage = error.localizedDescription
            }
            isTesting = false
        }
    }

    private func saveKey() {
        guard validationMessage == nil else { return }
        isSaving = true
        errorMessage = nil

        Task {
            do {
                try await secureSecretStore.saveAPIKey(provider.normalizedKey(apiKey), for: provider)
                await onSave?()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func deleteKey() {
        isDeleting = true
        errorMessage = nil
        successMessage = nil

        Task {
            do {
                try await secureSecretStore.deleteAPIKey(for: provider)
                await onSave?()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isDeleting = false
        }
    }
}
