import Foundation
import SwiftData
import SwiftUI

struct CurrentUser: Codable, Equatable, Identifiable {
    var uid: String
    var displayName: String
    var email: String
    var avatarURL: URL?

    var id: String { uid }
}

enum AppTab: Hashable {
    case vaults
    case terminals
    case settings
}

enum VaultsRoute: Hashable {
    case vaultDashboard(UUID)
    case hosts(UUID)
    case hostDetail(UUID)
    case keychain(UUID)
    case keychainItem(UUID)
    case snippets(UUID)
}

enum TerminalsRoute: Hashable {
    case session(UUID)
}

enum SettingsRoute: Hashable {
    case apiKeys
    case apiKey(AIProvider)
}

enum HostAuthMethod: String, Codable, CaseIterable, Identifiable {
    case password
    case sshKey
    case identity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .password:
            "Password"
        case .sshKey:
            "SSH Key"
        case .identity:
            "Identity"
        }
    }
}

enum KeychainItemKind: String, Codable, CaseIterable, Identifiable {
    case password
    case sshKey
    case identity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .password:
            "Password"
        case .sshKey:
            "SSH Key"
        case .identity:
            "Identity"
        }
    }
}

enum TerminalSessionState: String, Codable, CaseIterable {
    case connecting
    case connected
    case disconnected
    case failed
    case closed

    var title: String {
        switch self {
        case .connecting:
            "Connecting"
        case .connected:
            "Connected"
        case .disconnected:
            "Disconnected"
        case .failed:
            "Failed"
        case .closed:
            "Closed"
        }
    }

    var color: Color {
        switch self {
        case .connecting:
            .orange
        case .connected:
            .green
        case .disconnected:
            .gray
        case .failed:
            .red
        case .closed:
            .secondary
        }
    }
}

enum AIProvider: String, Codable, CaseIterable, Hashable, Identifiable {
    case openAI
    case anthropic
    case gemini

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI:
            "OpenAI"
        case .anthropic:
            "Anthropic"
        case .gemini:
            "Gemini"
        }
    }

    var keychainAccount: String {
        "ai-provider-\(rawValue)"
    }

    func normalizedKey(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func configuredKeyDescription(for key: String) -> String? {
        let trimmed = normalizedKey(key)
        guard !trimmed.isEmpty else { return nil }

        let suffix = String(trimmed.suffix(4))
        return "Configured • ...\(suffix)"
    }

    func validationMessage(for key: String) -> String? {
        let trimmed = normalizedKey(key)
        guard !trimmed.isEmpty else { return "API key is required." }

        switch self {
        case .openAI:
            return (trimmed.hasPrefix("sk-") || trimmed.hasPrefix("sk-proj-")) && !trimmed.hasPrefix("sk-ant-")
                ? nil
                : "Invalid OpenAI API Key format."
        case .anthropic:
            return trimmed.hasPrefix("sk-ant-")
                ? nil
                : "Invalid Anthropic API Key format."
        case .gemini:
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
            return trimmed.count >= 20 && trimmed.rangeOfCharacter(from: allowed.inverted) == nil
                ? nil
                : "Invalid Gemini API Key format."
        }
    }
}

enum AppTheme: Int, CaseIterable, Identifiable {
    case system = 0
    case light = 1
    case dark = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .system:
            "System"
        case .light:
            "Light"
        case .dark:
            "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

@Model
final class VaultProfile {
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class HostProfile {
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

    init(
        id: UUID = UUID(),
        vaultID: UUID,
        alias: String,
        host: String,
        port: Int = 22,
        username: String,
        authMethod: HostAuthMethod = .password,
        linkedKeychainItemID: UUID? = nil,
        notes: String = "",
        lastConnectedAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.vaultID = vaultID
        self.alias = alias
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.linkedKeychainItemID = linkedKeychainItemID
        self.notes = notes
        self.lastConnectedAt = lastConnectedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class KeychainItemProfile {
    var id: UUID
    var vaultID: UUID
    var name: String
    var kind: KeychainItemKind
    var username: String
    var fingerprint: String
    var secretAccount: String
    var passphraseAccount: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        vaultID: UUID,
        name: String,
        kind: KeychainItemKind,
        username: String = "",
        fingerprint: String = "",
        secretAccount: String,
        passphraseAccount: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.vaultID = vaultID
        self.name = name
        self.kind = kind
        self.username = username
        self.fingerprint = fingerprint
        self.secretAccount = secretAccount
        self.passphraseAccount = passphraseAccount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class SnippetProfile {
    var id: UUID
    var vaultID: UUID
    var title: String
    var command: String
    var notes: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        vaultID: UUID,
        title: String,
        command: String,
        notes: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.vaultID = vaultID
        self.title = title
        self.command = command
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class AppSettings {
    var id: UUID
    var appThemeRawValue: Int
    var terminalFontSize: Double
    var defaultAIProviderRawValue: String

    init(
        id: UUID = UUID(),
        appThemeRawValue: Int = AppTheme.system.rawValue,
        terminalFontSize: Double = 14,
        defaultAIProviderRawValue: String = AIProvider.openAI.rawValue
    ) {
        self.id = id
        self.appThemeRawValue = appThemeRawValue
        self.terminalFontSize = terminalFontSize
        self.defaultAIProviderRawValue = defaultAIProviderRawValue
    }
}

struct TerminalSession: Identifiable, Hashable {
    let id: UUID
    let hostID: UUID?
    let vaultID: UUID?
    var title: String
    var subtitle: String
    var state: TerminalSessionState
    var startedAt: Date
    var lastActivityAt: Date
    var retainedLog: [String]
    var terminalOutputChunks: [TerminalOutputChunk]
    var terminalMode: TerminalMode
    var currentInput: String
    var cwdGuess: String
    var shellHint: String
    var osHint: String
    var userRoleHint: String
    var lastCommand: String?
    var chatMessages: [AIChatMessage]
    var chatDraft: String
    var chatError: String?
    var isAwaitingAIResponse: Bool

    init(
        id: UUID = UUID(),
        hostID: UUID? = nil,
        vaultID: UUID? = nil,
        title: String,
        subtitle: String,
        state: TerminalSessionState = .connected,
        startedAt: Date = .now,
        lastActivityAt: Date = .now,
        retainedLog: [String] = [],
        terminalOutputChunks: [TerminalOutputChunk] = [],
        terminalMode: TerminalMode = .raw,
        currentInput: String = "",
        cwdGuess: String = "~",
        shellHint: String = "bash",
        osHint: String = "unknown",
        userRoleHint: String = "standard user",
        lastCommand: String? = nil,
        chatMessages: [AIChatMessage] = [],
        chatDraft: String = "",
        chatError: String? = nil,
        isAwaitingAIResponse: Bool = false
    ) {
        self.id = id
        self.hostID = hostID
        self.vaultID = vaultID
        self.title = title
        self.subtitle = subtitle
        self.state = state
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.retainedLog = retainedLog
        self.terminalOutputChunks = terminalOutputChunks
        self.terminalMode = terminalMode
        self.currentInput = currentInput
        self.cwdGuess = cwdGuess
        self.shellHint = shellHint
        self.osHint = osHint
        self.userRoleHint = userRoleHint
        self.lastCommand = lastCommand
        self.chatMessages = chatMessages
        self.chatDraft = chatDraft
        self.chatError = chatError
        self.isAwaitingAIResponse = isAwaitingAIResponse
    }
}
