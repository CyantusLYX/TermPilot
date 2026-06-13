import CommonCrypto
import CryptoKit
import Foundation
import Security
import SwiftData

struct SyncBlobDocument: Codable, Equatable {
    var encryptedBlob: String
    var salt: String
    var kdf: String
    var kdfIterations: Int
    var schemaVersion: Int
    var lastUpdated: Date

    nonisolated static let currentKDF = "PBKDF2-HMAC-SHA256"
    nonisolated static let currentIterations = 600_000
    nonisolated static let currentSchemaVersion = 1
}

struct SyncPayload: Codable, Equatable {
    var version: Int
    var exportedAt: Date
    var vaults: [SyncVault]
    var hosts: [SyncHost]
    var keychainItems: [SyncKeychainItem]
    var snippets: [SyncSnippet]

    init(
        version: Int = 1,
        exportedAt: Date = .now,
        vaults: [SyncVault],
        hosts: [SyncHost],
        keychainItems: [SyncKeychainItem],
        snippets: [SyncSnippet] = []
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.vaults = vaults
        self.hosts = hosts
        self.keychainItems = keychainItems
        self.snippets = snippets
    }

    enum CodingKeys: String, CodingKey {
        case version
        case exportedAt
        case vaults
        case hosts
        case keychainItems
        case snippets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        vaults = try container.decode([SyncVault].self, forKey: .vaults)
        hosts = try container.decode([SyncHost].self, forKey: .hosts)
        keychainItems = try container.decode([SyncKeychainItem].self, forKey: .keychainItems)
        snippets = try container.decodeIfPresent([SyncSnippet].self, forKey: .snippets) ?? []
    }
}

struct SyncVault: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
}

struct SyncHost: Codable, Equatable, Identifiable {
    var id: UUID
    var vaultID: UUID
    var alias: String
    var host: String
    var port: Int
    var username: String
    var authMethod: HostAuthMethod
    var linkedKeychainItemID: UUID?
    var notes: String
    var lastConnectedAt: Date?
    var createdAt: Date
    var updatedAt: Date
}

struct SyncKeychainItem: Codable, Equatable, Identifiable {
    var id: UUID
    var vaultID: UUID
    var name: String
    var kind: KeychainItemKind
    var username: String
    var fingerprint: String
    var secret: String
    var passphrase: String?
    var createdAt: Date
    var updatedAt: Date
}

struct SyncSnippet: Codable, Equatable, Identifiable {
    var id: UUID
    var vaultID: UUID
    var title: String
    var command: String
    var notes: String
    var createdAt: Date
    var updatedAt: Date
}

enum SyncError: LocalizedError {
    case randomSaltFailed(OSStatus)
    case keyDerivationFailed(Int32)
    case sealedBoxMissingCombinedData
    case unsupportedPayloadVersion(Int)
    case missingSecret(String)
    case invalidPayload(String)

    var errorDescription: String? {
        switch self {
        case .randomSaltFailed(let status):
            "Unable to create sync salt. Security status: \(status)."
        case .keyDerivationFailed(let status):
            "Unable to derive sync key. CommonCrypto status: \(status)."
        case .sealedBoxMissingCombinedData:
            "Unable to serialize encrypted sync payload."
        case .unsupportedPayloadVersion(let version):
            "Unsupported sync payload version: \(version)."
        case .missingSecret(let name):
            "Missing Keychain secret for \(name)."
        case .invalidPayload(let message):
            "Invalid sync payload: \(message)"
        }
    }
}

enum SyncEncryptionService {
    static func createDocument(
        payload: SyncPayload,
        masterPassword: String,
        iterations: Int = SyncBlobDocument.currentIterations
    ) async throws -> SyncBlobDocument {
        let salt = try randomSalt()
        let keyMaterial = try await deriveKeyMaterial(
            masterPassword: masterPassword,
            salt: salt,
            iterations: iterations
        )

        return try await createDocument(
            payload: payload,
            keyMaterial: keyMaterial,
            salt: salt,
            iterations: iterations
        )
    }

    static func createDocument(
        payload: SyncPayload,
        keyMaterial: Data,
        salt: Data,
        iterations: Int
    ) async throws -> SyncBlobDocument {
        let payloadData = try encoder.encode(payload)
        let encryptedBlob = try await encrypt(
            payloadData,
            keyMaterial: keyMaterial
        )

        return SyncBlobDocument(
            encryptedBlob: encryptedBlob,
            salt: salt.base64EncodedString(),
            kdf: SyncBlobDocument.currentKDF,
            kdfIterations: iterations,
            schemaVersion: SyncBlobDocument.currentSchemaVersion,
            lastUpdated: .now
        )
    }

    static func openDocument(_ document: SyncBlobDocument, masterPassword: String) async throws -> SyncPayload {
        guard let salt = Data(base64Encoded: document.salt) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid salt encoding."))
        }

        let keyMaterial = try await deriveKeyMaterial(
            masterPassword: masterPassword,
            salt: salt,
            iterations: document.kdfIterations
        )
        return try await openDocument(document, keyMaterial: keyMaterial)
    }

    static func openDocument(_ document: SyncBlobDocument, keyMaterial: Data) async throws -> SyncPayload {
        let payloadData = try await decrypt(
            document.encryptedBlob,
            keyMaterial: keyMaterial
        )
        let payload = try decoder.decode(SyncPayload.self, from: payloadData)
        guard payload.version == SyncBlobDocument.currentSchemaVersion else {
            throw SyncError.unsupportedPayloadVersion(payload.version)
        }
        return payload
    }

    static func randomSalt(byteCount: Int = 32) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw SyncError.randomSaltFailed(status)
        }
        return Data(bytes)
    }

    static func deriveKeyMaterial(
        masterPassword: String,
        salt: Data,
        iterations: Int
    ) async throws -> Data {
        try await Task.detached {
            try deriveKeyMaterialSync(
                masterPassword: masterPassword,
                salt: salt,
                iterations: iterations
            )
        }.value
    }

    static func encrypt(
        _ data: Data,
        masterPassword: String,
        salt: Data,
        iterations: Int
    ) async throws -> String {
        let keyMaterial = try await deriveKeyMaterial(
            masterPassword: masterPassword,
            salt: salt,
            iterations: iterations
        )
        return try await encrypt(data, keyMaterial: keyMaterial)
    }

    static func encrypt(
        _ data: Data,
        keyMaterial: Data
    ) async throws -> String {
        try await Task.detached {
            let key = SymmetricKey(data: keyMaterial)
            let sealedBox = try AES.GCM.seal(data, using: key)
            guard let combined = sealedBox.combined else {
                throw SyncError.sealedBoxMissingCombinedData
            }
            return combined.base64EncodedString()
        }.value
    }

    static func decrypt(
        _ encryptedBlob: String,
        masterPassword: String,
        salt: Data,
        iterations: Int
    ) async throws -> Data {
        let keyMaterial = try await deriveKeyMaterial(
            masterPassword: masterPassword,
            salt: salt,
            iterations: iterations
        )
        return try await decrypt(encryptedBlob, keyMaterial: keyMaterial)
    }

    static func decrypt(
        _ encryptedBlob: String,
        keyMaterial: Data
    ) async throws -> Data {
        try await Task.detached {
            guard let combined = Data(base64Encoded: encryptedBlob) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid encrypted blob encoding."))
            }
            let key = SymmetricKey(data: keyMaterial)
            let sealedBox = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(sealedBox, using: key)
        }.value
    }

    nonisolated private static func deriveKeyMaterialSync(
        masterPassword: String,
        salt: Data,
        iterations: Int
    ) throws -> Data {
        let passwordData = Data(masterPassword.utf8)
        var derivedKey = [UInt8](repeating: 0, count: 32)

        let status = passwordData.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.bindMemory(to: Int8.self).baseAddress,
                    passwordData.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    &derivedKey,
                    derivedKey.count
                )
            }
        }

        guard status == kCCSuccess else {
            throw SyncError.keyDerivationFailed(status)
        }
        return Data(derivedKey)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

enum SyncPayloadExporter {
    static func export(
        vaults: [VaultProfile],
        hosts: [HostProfile],
        keychainItems: [KeychainItemProfile],
        snippets: [SnippetProfile] = [],
        secureSecretStore: any VaultSecretStoring
    ) async throws -> SyncPayload {
        let syncVaults = vaults.map {
            SyncVault(id: $0.id, name: $0.name, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
        }

        let syncHosts = hosts.map {
            SyncHost(
                id: $0.id,
                vaultID: $0.vaultID,
                alias: $0.alias,
                host: $0.host,
                port: $0.port,
                username: $0.username,
                authMethod: $0.authMethod,
                linkedKeychainItemID: $0.linkedKeychainItemID,
                notes: $0.notes,
                lastConnectedAt: $0.lastConnectedAt,
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt
            )
        }

        var syncKeychainItems: [SyncKeychainItem] = []
        for item in keychainItems {
            guard let secret = try await secureSecretStore.loadVaultSecret(account: item.secretAccount), !secret.isEmpty else {
                throw SyncError.missingSecret(item.name)
            }

            let passphrase: String?
            if let passphraseAccount = item.passphraseAccount {
                passphrase = try await secureSecretStore.loadVaultSecret(account: passphraseAccount)
            } else {
                passphrase = nil
            }

            syncKeychainItems.append(SyncKeychainItem(
                id: item.id,
                vaultID: item.vaultID,
                name: item.name,
                kind: item.kind,
                username: item.username,
                fingerprint: item.fingerprint,
                secret: secret,
                passphrase: passphrase,
                createdAt: item.createdAt,
                updatedAt: item.updatedAt
            ))
        }

        let syncSnippets = snippets.map {
            SyncSnippet(
                id: $0.id,
                vaultID: $0.vaultID,
                title: $0.title,
                command: $0.command,
                notes: $0.notes,
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt
            )
        }

        return SyncPayload(
            vaults: syncVaults,
            hosts: syncHosts,
            keychainItems: syncKeychainItems,
            snippets: syncSnippets
        )
    }
}

enum SyncPayloadImporter {
    static func replaceLocalData(
        with payload: SyncPayload,
        modelContext: ModelContext,
        secureSecretStore: any VaultSecretStoring
    ) async throws {
        try SyncPayloadValidator.validate(payload)

        let existingSecretAccounts = try Set(existingSecretAccounts(in: modelContext))
        var importedSecretAccounts: [(account: String, secret: String)] = []
        for item in payload.keychainItems {
            let account = secretAccount(for: item.id)
            importedSecretAccounts.append((account, item.secret))

            if let passphrase = item.passphrase {
                importedSecretAccounts.append((passphraseAccount(for: item.id), passphrase))
            }
        }

        var savedAccounts: [String] = []
        do {
            for entry in importedSecretAccounts {
                try await secureSecretStore.saveVaultSecret(entry.secret, account: entry.account)
                savedAccounts.append(entry.account)
            }
        } catch {
            await deleteImportedSecrets(savedAccounts, secureSecretStore: secureSecretStore)
            throw error
        }

        do {
            try modelContext.transaction {
                try deleteExistingData(in: modelContext)

                for vault in payload.vaults {
                    modelContext.insert(VaultProfile(
                        id: vault.id,
                        name: vault.name,
                        createdAt: vault.createdAt,
                        updatedAt: vault.updatedAt
                    ))
                }

                for host in payload.hosts {
                    modelContext.insert(HostProfile(
                        id: host.id,
                        vaultID: host.vaultID,
                        alias: host.alias,
                        host: host.host,
                        port: host.port,
                        username: host.username,
                        authMethod: host.authMethod,
                        linkedKeychainItemID: host.linkedKeychainItemID,
                        notes: host.notes,
                        lastConnectedAt: host.lastConnectedAt,
                        createdAt: host.createdAt,
                        updatedAt: host.updatedAt
                    ))
                }

                for item in payload.keychainItems {
                    modelContext.insert(KeychainItemProfile(
                        id: item.id,
                        vaultID: item.vaultID,
                        name: item.name,
                        kind: item.kind,
                        username: item.username,
                        fingerprint: item.fingerprint,
                        secretAccount: secretAccount(for: item.id),
                        passphraseAccount: item.passphrase == nil ? nil : passphraseAccount(for: item.id),
                        createdAt: item.createdAt,
                        updatedAt: item.updatedAt
                    ))
                }

                for snippet in payload.snippets {
                    modelContext.insert(SnippetProfile(
                        id: snippet.id,
                        vaultID: snippet.vaultID,
                        title: snippet.title,
                        command: snippet.command,
                        notes: snippet.notes,
                        createdAt: snippet.createdAt,
                        updatedAt: snippet.updatedAt
                    ))
                }
            }
        } catch {
            await deleteImportedSecrets(savedAccounts, secureSecretStore: secureSecretStore)
            throw error
        }

        let importedAccountSet = Set(savedAccounts)
        await deleteStaleSecrets(
            existingSecretAccounts.subtracting(importedAccountSet),
            secureSecretStore: secureSecretStore
        )
    }

    private static func existingSecretAccounts(in modelContext: ModelContext) throws -> [String] {
        try modelContext.fetch(FetchDescriptor<KeychainItemProfile>()).flatMap { item in
            [item.secretAccount, item.passphraseAccount].compactMap(\.self)
        }
    }

    private static func deleteExistingData(in modelContext: ModelContext) throws {
        for vault in try modelContext.fetch(FetchDescriptor<VaultProfile>()) {
            modelContext.delete(vault)
        }
        for host in try modelContext.fetch(FetchDescriptor<HostProfile>()) {
            modelContext.delete(host)
        }
        for item in try modelContext.fetch(FetchDescriptor<KeychainItemProfile>()) {
            modelContext.delete(item)
        }
        for snippet in try modelContext.fetch(FetchDescriptor<SnippetProfile>()) {
            modelContext.delete(snippet)
        }
    }

    private static func secretAccount(for id: UUID) -> String {
        "vault-secret-\(id.uuidString)"
    }

    private static func passphraseAccount(for id: UUID) -> String {
        "vault-secret-passphrase-\(id.uuidString)"
    }

    private static func deleteImportedSecrets(
        _ accounts: [String],
        secureSecretStore: any VaultSecretStoring
    ) async {
        for account in accounts {
            try? await secureSecretStore.deleteVaultSecret(account: account)
        }
    }

    private static func deleteStaleSecrets(
        _ accounts: Set<String>,
        secureSecretStore: any VaultSecretStoring
    ) async {
        for account in accounts.sorted() {
            try? await secureSecretStore.deleteVaultSecret(account: account)
        }
    }
}

enum SyncPayloadValidator {
    static func validate(_ payload: SyncPayload) throws {
        guard payload.version == SyncBlobDocument.currentSchemaVersion else {
            throw SyncError.unsupportedPayloadVersion(payload.version)
        }

        try validateUniqueIDs(payload.vaults.map(\.id), label: "vault")
        try validateUniqueIDs(payload.hosts.map(\.id), label: "host")
        try validateUniqueIDs(payload.keychainItems.map(\.id), label: "keychain item")
        try validateUniqueIDs(payload.snippets.map(\.id), label: "snippet")

        let vaultIDs = Set(payload.vaults.map(\.id))
        let keychainItemsByID = Dictionary(uniqueKeysWithValues: payload.keychainItems.map { ($0.id, $0) })

        try validateVaults(payload.vaults)
        try validateKeychainItems(payload.keychainItems, vaultIDs: vaultIDs)
        try validateHosts(payload.hosts, vaultIDs: vaultIDs, keychainItemsByID: keychainItemsByID)
        try validateSnippets(payload.snippets, vaultIDs: vaultIDs)
    }

    private static func validateVaults(_ vaults: [SyncVault]) throws {
        for vault in vaults {
            let messages = ProfileValidation.vaultNameMessages(vault.name)
            guard messages.isEmpty else {
                throw SyncError.invalidPayload("Vault \(vault.id.uuidString) \(messages[0])")
            }
        }
    }

    private static func validateHosts(
        _ hosts: [SyncHost],
        vaultIDs: Set<UUID>,
        keychainItemsByID: [UUID: SyncKeychainItem]
    ) throws {
        for host in hosts {
            guard vaultIDs.contains(host.vaultID) else {
                throw SyncError.invalidPayload("Host \(host.alias) references a missing vault.")
            }

            let messages = ProfileValidation.hostMessages(
                alias: host.alias,
                host: host.host,
                username: host.username,
                port: host.port
            )
            guard messages.isEmpty else {
                throw SyncError.invalidPayload("Host \(host.alias) \(messages[0])")
            }

            guard let linkedKeychainItemID = host.linkedKeychainItemID else { continue }
            guard let keychainItem = keychainItemsByID[linkedKeychainItemID] else {
                throw SyncError.invalidPayload("Host \(host.alias) references a missing keychain item.")
            }
            guard keychainItem.vaultID == host.vaultID else {
                throw SyncError.invalidPayload("Host \(host.alias) references a keychain item from another vault.")
            }
            guard keychainItem.kind.rawValue == host.authMethod.rawValue else {
                throw SyncError.invalidPayload("Host \(host.alias) auth method does not match its linked keychain item.")
            }
        }
    }

    private static func validateKeychainItems(_ items: [SyncKeychainItem], vaultIDs: Set<UUID>) throws {
        for item in items {
            guard vaultIDs.contains(item.vaultID) else {
                throw SyncError.invalidPayload("Keychain item \(item.name) references a missing vault.")
            }

            let messages = ProfileValidation.keychainItemMessages(
                name: item.name,
                secret: item.secret,
                kind: item.kind
            )
            guard messages.isEmpty else {
                throw SyncError.invalidPayload("Keychain item \(item.name) \(messages[0])")
            }
        }
    }

    private static func validateSnippets(_ snippets: [SyncSnippet], vaultIDs: Set<UUID>) throws {
        for snippet in snippets {
            guard vaultIDs.contains(snippet.vaultID) else {
                throw SyncError.invalidPayload("Snippet \(snippet.title) references a missing vault.")
            }

            let messages = ProfileValidation.snippetMessages(
                title: snippet.title,
                command: snippet.command
            )
            guard messages.isEmpty else {
                throw SyncError.invalidPayload("Snippet \(snippet.title) \(messages[0])")
            }
        }
    }

    private static func validateUniqueIDs(_ ids: [UUID], label: String) throws {
        var seenIDs = Set<UUID>()
        for id in ids where !seenIDs.insert(id).inserted {
            throw SyncError.invalidPayload("Duplicate \(label) id \(id.uuidString).")
        }
    }
}
