import SwiftData
import SwiftUI

struct LoginView: View {
    @Environment(SyncUnlockStore.self) private var syncUnlockStore
    @Environment(SecureSecretStore.self) private var secureSecretStore
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \VaultProfile.createdAt) private var vaults: [VaultProfile]
    @Query(sort: \HostProfile.alias) private var hosts: [HostProfile]
    @Query(sort: \KeychainItemProfile.name) private var keychainItems: [KeychainItemProfile]
    @Query(sort: \SnippetProfile.title) private var snippets: [SnippetProfile]

    @State private var masterPassword = ""
    @State private var confirmMasterPassword = ""
    @State private var isConfirmingCloudDelete = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 32)
                brandHeader

                switch syncUnlockStore.phase {
                case .checkingSession:
                    ProgressView("Checking session")
                case .signedOut:
                    signedOutActions
                case .needsSyncChoice:
                    syncChoiceActions
                case .needsUnlock:
                    unlockActions
                case .unlocked:
                    ProgressView("Opening vaults")
                }

                statusMessages
                Spacer(minLength: 32)
            }
            .frame(maxWidth: 440)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog(
            "Clear encrypted cloud sync data?",
            isPresented: $isConfirmingCloudDelete,
            titleVisibility: .visible
        ) {
            Button("Clear Cloud Sync Data", role: .destructive) {
                Task {
                    await syncUnlockStore.deleteCloudSyncData()
                }
                resetPasswordFields()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes only the encrypted demo sync blob. Local data on this device can be used to create a new sync password.")
        }
        .onChange(of: syncUnlockStore.phase) {
            resetPasswordFields()
        }
    }

    private var brandHeader: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 58, weight: .semibold))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("TermPilot")
                    .font(.largeTitle.bold())
                Text("Vault-centric SSH workspace")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var signedOutActions: some View {
        VStack(spacing: 14) {
            Button {
                Task {
                    await syncUnlockStore.signInWithGoogle()
                }
            } label: {
                Label("Continue with Google", systemImage: "g.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(syncUnlockStore.isBusy)

            Text("Use the Google account linked to your Firebase project.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var syncChoiceActions: some View {
        VStack(spacing: 18) {
            if let user = syncUnlockStore.currentUser {
                userSummary(user)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Enable Encrypted Sync")
                    .font(.headline)
                Text("Your sync master password cannot be recovered. Forgetting it makes existing cloud sync data unreadable.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                SecureField("Sync master password", text: $masterPassword)
                    .textContentType(.newPassword)
                SecureField("Confirm master password", text: $confirmMasterPassword)
                    .textContentType(.newPassword)
            }
            .textFieldStyle(.roundedBorder)

            Button {
                enableSync()
            } label: {
                Label("Create Master Password", systemImage: "lock.shield")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(syncUnlockStore.isBusy)

            Button {
                syncUnlockStore.continueWithoutSync()
            } label: {
                Label("Enter Without Sync", systemImage: "iphone")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(syncUnlockStore.isBusy)
        }
    }

    private var unlockActions: some View {
        VStack(spacing: 18) {
            if let user = syncUnlockStore.currentUser {
                userSummary(user)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Unlock Encrypted Sync")
                    .font(.headline)
                SecureField("Sync master password", text: $masterPassword)
                    .textContentType(.password)
                    .textFieldStyle(.roundedBorder)
            }

            Button {
                unlockSync()
            } label: {
                Label("Unlock Vaults", systemImage: "lock.open")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(syncUnlockStore.isBusy)

            Button(role: .destructive) {
                isConfirmingCloudDelete = true
            } label: {
                Label("Forgot Password", systemImage: "exclamationmark.triangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(syncUnlockStore.isBusy)
        }
    }

    private var statusMessages: some View {
        VStack(spacing: 8) {
            if syncUnlockStore.isBusy {
                ProgressView()
            }

            if let statusMessage = syncUnlockStore.statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let errorMessage = syncUnlockStore.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func userSummary(_ user: CurrentUser) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(user.displayName)
                    .font(.headline)
                Text(user.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func enableSync() {
        let exportVaults = ensureVaultsForInitialSync()

        Task {
            await syncUnlockStore.enableSync(
                masterPassword: masterPassword,
                confirmPassword: confirmMasterPassword,
                vaults: exportVaults,
                hosts: hosts,
                keychainItems: keychainItems,
                snippets: snippets,
                secureSecretStore: secureSecretStore
            )
        }
    }

    private func unlockSync() {
        Task {
            await syncUnlockStore.unlock(
                masterPassword: masterPassword,
                modelContext: modelContext,
                secureSecretStore: secureSecretStore
            )
        }
    }

    private func ensureVaultsForInitialSync() -> [VaultProfile] {
        guard vaults.isEmpty else { return vaults }

        let personalVault = VaultProfile(name: "Personal Vault")
        modelContext.insert(personalVault)
        try? modelContext.save()
        return [personalVault]
    }

    private func resetPasswordFields() {
        masterPassword = ""
        confirmMasterPassword = ""
    }
}
