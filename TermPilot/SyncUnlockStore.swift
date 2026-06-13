import Foundation
import SwiftData

enum SyncUnlockPhase: Equatable {
    case checkingSession
    case signedOut
    case needsSyncChoice
    case needsUnlock
    case unlocked
}

@Observable
final class SyncUnlockStore {
    var phase: SyncUnlockPhase = .checkingSession
    var currentUser: CurrentUser?
    var errorMessage: String?
    var statusMessage: String?
    var isBusy = false
    var hasRemoteSyncBlob = false

    private let authRepository: any AuthRepository
    private let syncRepository: any SyncBlobRepository
    private var unlockedKeyMaterial: Data?
    private var unlockedSalt: Data?
    private var unlockedIterations = SyncBlobDocument.currentIterations
    private var pendingUploadTask: Task<Void, Never>?
    private var pendingUploadGeneration = 0

    init(
        authRepository: any AuthRepository = FirebaseAuthRepository(),
        syncRepository: any SyncBlobRepository = FirestoreSyncBlobRepository()
    ) {
        self.authRepository = authRepository
        self.syncRepository = syncRepository
    }

    var isUnlocked: Bool {
        phase == .unlocked
    }

    var canUploadEncryptedSync: Bool {
        isUnlocked && currentUser != nil && unlockedKeyMaterial != nil && unlockedSalt != nil
    }

    var requiresMasterPassword: Bool {
        phase == .needsUnlock
    }

    func restorePreviousSession() async {
        guard phase == .checkingSession else { return }

        do {
            guard let user = try await authRepository.restoreUser() else {
                phase = .signedOut
                return
            }

            currentUser = user
            await routeAfterSignIn(for: user)
        } catch {
            errorMessage = error.localizedDescription
            phase = .signedOut
        }
    }

    func signInWithGoogle() async {
        errorMessage = nil
        statusMessage = nil
        isBusy = true
        defer { isBusy = false }

        guard let presentingViewController = PresentingViewControllerProvider.current() else {
            errorMessage = FirebaseIntegrationError.missingPresentingViewController.localizedDescription
            return
        }

        do {
            let user = try await authRepository.signInWithGoogle(presenting: presentingViewController)
            currentUser = user
            await routeAfterSignIn(for: user)
        } catch {
            errorMessage = error.localizedDescription
            phase = .signedOut
        }
    }

    func continueWithoutSync() {
        errorMessage = nil
        statusMessage = "Using local-only vault data."
        phase = .unlocked
    }

    func enableSync(
        masterPassword: String,
        confirmPassword: String,
        vaults: [VaultProfile],
        hosts: [HostProfile],
        keychainItems: [KeychainItemProfile],
        snippets: [SnippetProfile] = [],
        secureSecretStore: SecureSecretStore
    ) async {
        guard let user = currentUser else {
            errorMessage = "Sign in before enabling sync."
            return
        }

        let password = masterPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard password.count >= 8 else {
            errorMessage = "Master password must be at least 8 characters."
            return
        }
        guard password == confirmPassword else {
            errorMessage = "Master passwords do not match."
            return
        }

        errorMessage = nil
        statusMessage = nil
        isBusy = true
        defer { isBusy = false }

        do {
            let payload = try await SyncPayloadExporter.export(
                vaults: vaults,
                hosts: hosts,
                keychainItems: keychainItems,
                snippets: snippets,
                secureSecretStore: secureSecretStore
            )
            let iterations = SyncBlobDocument.currentIterations
            let salt = try SyncEncryptionService.randomSalt()
            let keyMaterial = try await SyncEncryptionService.deriveKeyMaterial(
                masterPassword: password,
                salt: salt,
                iterations: iterations
            )
            let document = try await SyncEncryptionService.createDocument(
                payload: payload,
                keyMaterial: keyMaterial,
                salt: salt,
                iterations: iterations
            )
            try await syncRepository.save(document, uid: user.uid)
            rememberUnlockedKey(keyMaterial: keyMaterial, salt: salt, iterations: iterations)
            hasRemoteSyncBlob = true
            statusMessage = "Encrypted sync is enabled."
            phase = .unlocked
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unlock(
        masterPassword: String,
        modelContext: ModelContext,
        secureSecretStore: SecureSecretStore
    ) async {
        guard let user = currentUser else {
            errorMessage = "Sign in before unlocking sync data."
            return
        }

        let password = masterPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !password.isEmpty else {
            errorMessage = "Enter your sync master password."
            return
        }

        errorMessage = nil
        statusMessage = nil
        isBusy = true
        defer { isBusy = false }

        do {
            guard let document = try await syncRepository.fetchLatest(uid: user.uid) else {
                hasRemoteSyncBlob = false
                phase = .needsSyncChoice
                return
            }

            guard let salt = Data(base64Encoded: document.salt) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid salt encoding."))
            }
            let keyMaterial = try await SyncEncryptionService.deriveKeyMaterial(
                masterPassword: password,
                salt: salt,
                iterations: document.kdfIterations
            )
            let payload = try await SyncEncryptionService.openDocument(document, keyMaterial: keyMaterial)
            try await SyncPayloadImporter.replaceLocalData(
                with: payload,
                modelContext: modelContext,
                secureSecretStore: secureSecretStore
            )
            rememberUnlockedKey(keyMaterial: keyMaterial, salt: salt, iterations: document.kdfIterations)
            hasRemoteSyncBlob = true
            statusMessage = "Encrypted sync data unlocked."
            phase = .unlocked
        } catch {
            errorMessage = "Unlock failed. Check your master password and try again."
        }
    }

    func uploadCurrentData(
        vaults: [VaultProfile],
        hosts: [HostProfile],
        keychainItems: [KeychainItemProfile],
        snippets: [SnippetProfile] = [],
        secureSecretStore: SecureSecretStore
    ) async {
        invalidatePendingUpload()
        await performUploadCurrentData(
            vaults: vaults,
            hosts: hosts,
            keychainItems: keychainItems,
            snippets: snippets,
            secureSecretStore: secureSecretStore
        )
    }

    private func performUploadCurrentData(
        vaults: [VaultProfile],
        hosts: [HostProfile],
        keychainItems: [KeychainItemProfile],
        snippets: [SnippetProfile] = [],
        secureSecretStore: SecureSecretStore
    ) async {
        guard let user = currentUser,
              let keyMaterial = unlockedKeyMaterial,
              let salt = unlockedSalt
        else {
            errorMessage = "Unlock or enable encrypted sync before uploading."
            return
        }

        errorMessage = nil
        statusMessage = nil
        isBusy = true
        defer { isBusy = false }

        do {
            let payload = try await SyncPayloadExporter.export(
                vaults: vaults,
                hosts: hosts,
                keychainItems: keychainItems,
                snippets: snippets,
                secureSecretStore: secureSecretStore
            )
            try Task.checkCancellation()

            let document = try await SyncEncryptionService.createDocument(
                payload: payload,
                keyMaterial: keyMaterial,
                salt: salt,
                iterations: unlockedIterations
            )
            try Task.checkCancellation()

            guard currentUser?.uid == user.uid,
                  unlockedKeyMaterial == keyMaterial,
                  unlockedSalt == salt
            else {
                return
            }

            try await syncRepository.save(document, uid: user.uid)
            hasRemoteSyncBlob = true
            statusMessage = "Encrypted sync upload completed."
        } catch is CancellationError {
            statusMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func scheduleUploadCurrentData(
        vaults: [VaultProfile],
        hosts: [HostProfile],
        keychainItems: [KeychainItemProfile],
        snippets: [SnippetProfile] = [],
        secureSecretStore: SecureSecretStore
    ) {
        guard canUploadEncryptedSync else { return }

        pendingUploadGeneration += 1
        let generation = pendingUploadGeneration
        pendingUploadTask?.cancel()
        statusMessage = "Encrypted sync upload scheduled."
        pendingUploadTask = Task {
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }

            guard !Task.isCancelled, pendingUploadGeneration == generation else { return }

            await performUploadCurrentData(
                vaults: vaults,
                hosts: hosts,
                keychainItems: keychainItems,
                snippets: snippets,
                secureSecretStore: secureSecretStore
            )

            if pendingUploadGeneration == generation {
                pendingUploadTask = nil
            }
        }
    }

    func deleteCloudSyncData() async {
        guard let user = currentUser else { return }

        do {
            invalidatePendingUpload()
            try await syncRepository.delete(uid: user.uid)
            hasRemoteSyncBlob = false
            errorMessage = nil
            statusMessage = "Encrypted cloud sync data was cleared."
            phase = .needsSyncChoice
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() async throws {
        invalidatePendingUpload()
        var signOutError: Error?
        do {
            try await authRepository.signOut()
        } catch {
            signOutError = error
        }
        currentUser = nil
        hasRemoteSyncBlob = false
        forgetUnlockedKey()
        errorMessage = nil
        statusMessage = nil
        isBusy = false
        phase = .signedOut

        if let signOutError {
            throw signOutError
        }
    }

    private func routeAfterSignIn(for user: CurrentUser) async {
        do {
            hasRemoteSyncBlob = try await syncRepository.fetchLatest(uid: user.uid) != nil
            phase = hasRemoteSyncBlob ? .needsUnlock : .needsSyncChoice
        } catch {
            errorMessage = error.localizedDescription
            phase = .needsSyncChoice
        }
    }

    private func rememberUnlockedKey(keyMaterial: Data, salt: Data, iterations: Int) {
        unlockedKeyMaterial = keyMaterial
        unlockedSalt = salt
        unlockedIterations = iterations
    }

    private func forgetUnlockedKey() {
        unlockedKeyMaterial = nil
        unlockedSalt = nil
        unlockedIterations = SyncBlobDocument.currentIterations
    }

    private func invalidatePendingUpload() {
        pendingUploadGeneration += 1
        pendingUploadTask?.cancel()
        pendingUploadTask = nil
    }
}
