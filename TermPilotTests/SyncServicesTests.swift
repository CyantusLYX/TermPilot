import Foundation
import SwiftData
import Testing
@testable import TermPilot

struct SyncServicesTests {
    @Test func syncPayloadDecodesOlderBlobWithoutSnippets() throws {
        let json = """
        {
          "version": 1,
          "exportedAt": "2026-06-11T12:00:00Z",
          "vaults": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "name": "Personal Vault",
              "createdAt": "2026-06-11T12:00:00Z",
              "updatedAt": "2026-06-11T12:01:00Z"
            }
          ],
          "hosts": [
            {
              "id": "22222222-2222-2222-2222-222222222222",
              "vaultID": "11111111-1111-1111-1111-111111111111",
              "alias": "My Server",
              "host": "192.168.1.1",
              "port": 22,
              "username": "root",
              "authMethod": "password",
              "linkedKeychainItemID": null,
              "notes": "",
              "lastConnectedAt": null,
              "createdAt": "2026-06-11T12:00:00Z",
              "updatedAt": "2026-06-11T12:01:00Z"
            }
          ],
          "keychainItems": []
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(SyncPayload.self, from: Data(json.utf8))

        #expect(payload.version == 1)
        #expect(payload.vaults.map(\.name) == ["Personal Vault"])
        #expect(payload.hosts.map(\.alias) == ["My Server"])
        #expect(payload.snippets.isEmpty)
    }

    @Test func syncEncryptionRoundTripsSnippetPayload() async throws {
        let payload = makePayload()

        let document = try await SyncEncryptionService.createDocument(
            payload: payload,
            masterPassword: "correct horse battery staple",
            iterations: 1_000
        )

        let openedPayload = try await SyncEncryptionService.openDocument(
            document,
            masterPassword: "correct horse battery staple"
        )

        #expect(document.kdf == SyncBlobDocument.currentKDF)
        #expect(document.kdfIterations == 1_000)
        #expect(document.schemaVersion == SyncBlobDocument.currentSchemaVersion)
        #expect(openedPayload == payload)
        #expect(openedPayload.snippets.first?.command == "tail -f /var/log/syslog")
    }

    @Test func wrongMasterPasswordDoesNotOpenDocument() async throws {
        let document = try await SyncEncryptionService.createDocument(
            payload: makePayload(),
            masterPassword: "correct horse battery staple",
            iterations: 1_000
        )

        var didThrow = false
        do {
            _ = try await SyncEncryptionService.openDocument(
                document,
                masterPassword: "wrong password"
            )
        } catch {
            didThrow = true
        }

        #expect(didThrow)
    }

    @Test func exporterIncludesSnippetsInPayload() async throws {
        let vaultID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let timestamp = Date(timeIntervalSince1970: 1_780_000_000)
        let vault = VaultProfile(
            id: vaultID,
            name: "Personal Vault",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let snippet = SnippetProfile(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            vaultID: vaultID,
            title: "Follow syslog",
            command: "tail -f /var/log/syslog",
            notes: "Useful during demos.",
            createdAt: timestamp,
            updatedAt: timestamp
        )

        let payload = try await SyncPayloadExporter.export(
            vaults: [vault],
            hosts: [],
            keychainItems: [],
            snippets: [snippet],
            secureSecretStore: SecureSecretStore()
        )

        #expect(payload.vaults.map(\.name) == ["Personal Vault"])
        #expect(payload.keychainItems.isEmpty)
        #expect(payload.snippets == [
            SyncSnippet(
                id: snippet.id,
                vaultID: vaultID,
                title: "Follow syslog",
                command: "tail -f /var/log/syslog",
                notes: "Useful during demos.",
                createdAt: timestamp,
                updatedAt: timestamp
            )
        ])
    }

    @Test func syncPayloadValidatorRejectsBrokenReferences() throws {
        let validPayload = makePayload()
        try SyncPayloadValidator.validate(validPayload)

        var missingVaultPayload = validPayload
        missingVaultPayload.hosts[0].vaultID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!

        var didRejectMissingVault = false
        do {
            try SyncPayloadValidator.validate(missingVaultPayload)
        } catch SyncError.invalidPayload(let message) {
            didRejectMissingVault = message.contains("missing vault")
        }
        #expect(didRejectMissingVault)

        var duplicateIDPayload = validPayload
        duplicateIDPayload.vaults.append(validPayload.vaults[0])

        var didRejectDuplicateID = false
        do {
            try SyncPayloadValidator.validate(duplicateIDPayload)
        } catch SyncError.invalidPayload(let message) {
            didRejectDuplicateID = message.contains("Duplicate vault id")
        }
        #expect(didRejectDuplicateID)
    }

    @MainActor
    @Test func invalidPayloadImportDoesNotReplaceLocalData() async throws {
        let container = try makeInMemoryModelContainer()
        let context = container.mainContext
        let existingVault = VaultProfile(
            id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            name: "Local Vault"
        )
        context.insert(existingVault)
        try context.save()

        var invalidPayload = makePayload()
        invalidPayload.hosts[0].vaultID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!

        var didRejectImport = false
        do {
            try await SyncPayloadImporter.replaceLocalData(
                with: invalidPayload,
                modelContext: context,
                secureSecretStore: SecureSecretStore()
            )
        } catch SyncError.invalidPayload {
            didRejectImport = true
        }

        let vaults = try context.fetch(FetchDescriptor<VaultProfile>())
        #expect(didRejectImport)
        #expect(vaults.map(\.name) == ["Local Vault"])
    }

    @MainActor
    @Test func failedSecretImportDeletesWrittenSecretsAndPreservesLocalData() async throws {
        let container = try makeInMemoryModelContainer()
        let context = container.mainContext
        let existingVault = VaultProfile(
            id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            name: "Local Vault"
        )
        context.insert(existingVault)
        try context.save()

        let remoteVaultID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let firstItemID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let secondItemID = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
        let failingAccount = "vault-secret-\(secondItemID.uuidString)"
        let store = FailingVaultSecretStore(failingSaveAccount: failingAccount)
        let timestamp = Date(timeIntervalSince1970: 1_780_000_000)
        let payload = SyncPayload(
            version: 1,
            exportedAt: timestamp,
            vaults: [
                SyncVault(id: remoteVaultID, name: "Remote Vault", createdAt: timestamp, updatedAt: timestamp)
            ],
            hosts: [],
            keychainItems: [
                SyncKeychainItem(
                    id: firstItemID,
                    vaultID: remoteVaultID,
                    name: "First Password",
                    kind: .password,
                    username: "root",
                    fingerprint: "",
                    secret: "first-secret",
                    passphrase: nil,
                    createdAt: timestamp,
                    updatedAt: timestamp
                ),
                SyncKeychainItem(
                    id: secondItemID,
                    vaultID: remoteVaultID,
                    name: "Second Password",
                    kind: .password,
                    username: "admin",
                    fingerprint: "",
                    secret: "second-secret",
                    passphrase: nil,
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            ],
            snippets: []
        )

        var didRejectImport = false
        do {
            try await SyncPayloadImporter.replaceLocalData(
                with: payload,
                modelContext: context,
                secureSecretStore: store
            )
        } catch TestSecretStoreError.saveFailed {
            didRejectImport = true
        }

        #expect(didRejectImport)
        #expect(store.secrets.isEmpty)
        #expect(store.deletedAccounts == ["vault-secret-\(firstItemID.uuidString)"])
        #expect(try context.fetch(FetchDescriptor<VaultProfile>()).map(\.name) == ["Local Vault"])
        #expect(try context.fetch(FetchDescriptor<KeychainItemProfile>()).isEmpty)
    }

    @MainActor
    @Test func successfulSecretImportDeletesStaleLocalSecrets() async throws {
        let container = try makeInMemoryModelContainer()
        let context = container.mainContext
        let localVaultID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        context.insert(VaultProfile(id: localVaultID, name: "Local Vault"))
        context.insert(KeychainItemProfile(
            vaultID: localVaultID,
            name: "Old Password",
            kind: .password,
            secretAccount: "old-secret-account",
            passphraseAccount: "old-passphrase-account"
        ))
        try context.save()

        let remoteVaultID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let newItemID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let timestamp = Date(timeIntervalSince1970: 1_780_000_000)
        let store = FailingVaultSecretStore(failingSaveAccount: "__never__")
        store.secrets = [
            "old-secret-account": "old-secret",
            "old-passphrase-account": "old-passphrase"
        ]
        let payload = SyncPayload(
            version: 1,
            exportedAt: timestamp,
            vaults: [
                SyncVault(id: remoteVaultID, name: "Remote Vault", createdAt: timestamp, updatedAt: timestamp)
            ],
            hosts: [],
            keychainItems: [
                SyncKeychainItem(
                    id: newItemID,
                    vaultID: remoteVaultID,
                    name: "New Password",
                    kind: .password,
                    username: "root",
                    fingerprint: "",
                    secret: "new-secret",
                    passphrase: nil,
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            ],
            snippets: []
        )

        try await SyncPayloadImporter.replaceLocalData(
            with: payload,
            modelContext: context,
            secureSecretStore: store
        )

        let newAccount = "vault-secret-\(newItemID.uuidString)"
        #expect(store.secrets == [newAccount: "new-secret"])
        #expect(Set(store.deletedAccounts) == ["old-secret-account", "old-passphrase-account"])
        #expect(try context.fetch(FetchDescriptor<VaultProfile>()).map(\.name) == ["Remote Vault"])
        #expect(try context.fetch(FetchDescriptor<KeychainItemProfile>()).map(\.secretAccount) == [newAccount])
    }

    @MainActor
    @Test func localDataWipeServiceRemovesVaultMetadataOnly() throws {
        let container = try makeInMemoryModelContainer()
        let context = container.mainContext
        let vaultID = UUID()
        let keychainItemID = UUID()

        context.insert(VaultProfile(id: vaultID, name: "Personal Vault"))
        context.insert(HostProfile(
            vaultID: vaultID,
            alias: "Production",
            host: "prod.example.com",
            username: "ubuntu",
            linkedKeychainItemID: keychainItemID
        ))
        context.insert(KeychainItemProfile(
            id: keychainItemID,
            vaultID: vaultID,
            name: "Production Password",
            kind: .password,
            secretAccount: "vault-secret-\(keychainItemID.uuidString)"
        ))
        context.insert(SnippetProfile(
            vaultID: vaultID,
            title: "Tail Logs",
            command: "tail -f /var/log/syslog"
        ))
        context.insert(AppSettings(terminalFontSize: 18))
        try context.save()

        try LocalDataWipeService.wipeVaultMetadata(in: context)

        #expect(try context.fetch(FetchDescriptor<VaultProfile>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<HostProfile>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<KeychainItemProfile>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<SnippetProfile>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<AppSettings>()).map(\.terminalFontSize) == [18])
    }

    private func makePayload() -> SyncPayload {
        let vaultID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let timestamp = Date(timeIntervalSince1970: 1_780_000_000)

        return SyncPayload(
            version: 1,
            exportedAt: timestamp,
            vaults: [
                SyncVault(
                    id: vaultID,
                    name: "Personal Vault",
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            ],
            hosts: [
                SyncHost(
                    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    vaultID: vaultID,
                    alias: "My Server",
                    host: "192.168.1.1",
                    port: 22,
                    username: "root",
                    authMethod: .password,
                    linkedKeychainItemID: nil,
                    notes: "",
                    lastConnectedAt: nil,
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            ],
            keychainItems: [],
            snippets: [
                SyncSnippet(
                    id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                    vaultID: vaultID,
                    title: "Follow syslog",
                    command: "tail -f /var/log/syslog",
                    notes: "Useful during demos.",
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            ]
        )
    }

    @MainActor
    private func makeInMemoryModelContainer() throws -> ModelContainer {
        let schema = Schema([
            VaultProfile.self,
            HostProfile.self,
            KeychainItemProfile.self,
            SnippetProfile.self,
            AppSettings.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

private enum TestSecretStoreError: Error {
    case saveFailed(String)
}

private final class FailingVaultSecretStore: VaultSecretStoring {
    let failingSaveAccount: String
    var secrets: [String: String] = [:]
    var deletedAccounts: [String] = []

    init(failingSaveAccount: String) {
        self.failingSaveAccount = failingSaveAccount
    }

    func saveVaultSecret(_ secret: String, account: String) async throws {
        if account == failingSaveAccount {
            throw TestSecretStoreError.saveFailed(account)
        }
        secrets[account] = secret
    }

    func loadVaultSecret(account: String) async throws -> String? {
        secrets[account]
    }

    func deleteVaultSecret(account: String) async throws {
        secrets.removeValue(forKey: account)
        deletedAccounts.append(account)
    }
}
