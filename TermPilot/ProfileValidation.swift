import Foundation
import SwiftUI

struct ProfileValidationFailure: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

enum ProfileValidation {
    static let vaultNameLimit = 64
    static let aliasLimit = 80
    static let hostLimit = 253
    static let usernameLimit = 64
    static let keychainNameLimit = 80
    static let snippetTitleLimit = 80
    static let snippetCommandLimit = 4_000

    static func vaultNameMessages(_ name: String, existingNames: [String] = []) -> [String] {
        var messages: [String] = []
        let trimmedName = trimmed(name)
        if trimmedName.isEmpty {
            messages.append("Vault name is required.")
        }
        if trimmedName.count > vaultNameLimit {
            messages.append("Vault name must be \(vaultNameLimit) characters or fewer.")
        }
        if contains(existingNames, matching: trimmedName) {
            messages.append("A vault with this name already exists.")
        }
        return messages
    }

    static func hostMessages(
        alias: String,
        host: String,
        username: String,
        port: Int,
        existingAliases: [String] = [],
        linkedKeychainItemID: UUID? = nil,
        requiresLinkedKeychainItem: Bool = false
    ) -> [String] {
        var messages: [String] = []
        let trimmedAlias = trimmed(alias)
        let trimmedHost = trimmed(host)
        let trimmedUsername = trimmed(username)

        if trimmedAlias.isEmpty {
            messages.append("Host alias is required.")
        }
        if trimmedAlias.count > aliasLimit {
            messages.append("Host alias must be \(aliasLimit) characters or fewer.")
        }
        if contains(existingAliases, matching: trimmedAlias) {
            messages.append("A host with this alias already exists in this vault.")
        }

        if trimmedHost.isEmpty {
            messages.append("Host address is required.")
        }
        if trimmedHost.count > hostLimit {
            messages.append("Host address must be \(hostLimit) characters or fewer.")
        }
        if trimmedHost.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            messages.append("Host address cannot contain spaces.")
        }

        if trimmedUsername.isEmpty {
            messages.append("Username is required.")
        }
        if trimmedUsername.count > usernameLimit {
            messages.append("Username must be \(usernameLimit) characters or fewer.")
        }
        if !(1...65_535).contains(port) {
            messages.append("Port must be between 1 and 65535.")
        }
        if requiresLinkedKeychainItem && linkedKeychainItemID == nil {
            messages.append("Select a keychain item for this authentication method.")
        }

        return messages
    }

    static func keychainItemMessages(
        name: String,
        secret: String,
        kind: KeychainItemKind,
        existingNames: [String] = [],
        originalKind: KeychainItemKind? = nil,
        isLinkedToHosts: Bool = false
    ) -> [String] {
        var messages: [String] = []
        let trimmedName = trimmed(name)
        if trimmedName.isEmpty {
            messages.append("Keychain item name is required.")
        }
        if trimmedName.count > keychainNameLimit {
            messages.append("Keychain item name must be \(keychainNameLimit) characters or fewer.")
        }
        if contains(existingNames, matching: trimmedName) {
            messages.append("A keychain item with this name already exists in this vault.")
        }
        if isLinkedToHosts, let originalKind, originalKind != kind {
            messages.append("Keychain item type cannot change while linked hosts use it.")
        }
        if trimmed(secret).isEmpty {
            switch kind {
            case .sshKey:
                messages.append("Private key is required.")
            case .password, .identity:
                messages.append("Secret is required.")
            }
        }
        return messages
    }

    static func snippetMessages(
        title: String,
        command: String,
        existingTitles: [String] = []
    ) -> [String] {
        var messages: [String] = []
        let trimmedTitle = trimmed(title)
        let trimmedCommand = trimmed(command)

        if trimmedTitle.isEmpty {
            messages.append("Snippet title is required.")
        }
        if trimmedTitle.count > snippetTitleLimit {
            messages.append("Snippet title must be \(snippetTitleLimit) characters or fewer.")
        }
        if contains(existingTitles, matching: trimmedTitle) {
            messages.append("A snippet with this title already exists in this vault.")
        }
        if trimmedCommand.isEmpty {
            messages.append("Command is required.")
        }
        if trimmedCommand.count > snippetCommandLimit {
            messages.append("Command must be \(snippetCommandLimit) characters or fewer.")
        }
        return messages
    }

    static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func contains(_ values: [String], matching candidate: String) -> Bool {
        let normalizedCandidate = candidate.lowercased()
        return values.contains {
            trimmed($0).lowercased() == normalizedCandidate
        }
    }
}

struct ValidationMessagesView: View {
    let messages: [String]

    var body: some View {
        if !messages.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(messages, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.top, 2)
        }
    }
}
