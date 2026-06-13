import Foundation
import Testing
@testable import TermPilot

struct ProfileValidationTests {
    @Test func vaultNameValidationRejectsBlankLongAndDuplicateNames() {
        #expect(ProfileValidation.vaultNameMessages("  ").contains("Vault name is required."))

        let longName = String(repeating: "v", count: ProfileValidation.vaultNameLimit + 1)
        #expect(ProfileValidation.vaultNameMessages(longName).contains("Vault name must be 64 characters or fewer."))

        #expect(ProfileValidation.vaultNameMessages("personal vault", existingNames: ["Personal Vault"]) == [
            "A vault with this name already exists."
        ])
    }

    @Test func hostValidationRejectsInvalidFieldsAndDuplicateAliases() {
        let messages = ProfileValidation.hostMessages(
            alias: "Production",
            host: "bad host.local",
            username: "",
            port: 70_000,
            existingAliases: ["production"]
        )

        #expect(messages.contains("A host with this alias already exists in this vault."))
        #expect(messages.contains("Host address cannot contain spaces."))
        #expect(messages.contains("Username is required."))
        #expect(messages.contains("Port must be between 1 and 65535."))
    }

    @Test func hostValidationAcceptsTypicalSSHProfile() {
        let messages = ProfileValidation.hostMessages(
            alias: "Production",
            host: "prod.example.com",
            username: "ubuntu",
            port: 22
        )

        #expect(messages.isEmpty)
    }

    @Test func hostValidationRequiresLinkedKeychainItemWhenRequested() {
        let messages = ProfileValidation.hostMessages(
            alias: "Production",
            host: "prod.example.com",
            username: "ubuntu",
            port: 22,
            requiresLinkedKeychainItem: true
        )

        #expect(messages == ["Select a keychain item for this authentication method."])

        let acceptedMessages = ProfileValidation.hostMessages(
            alias: "Production",
            host: "prod.example.com",
            username: "ubuntu",
            port: 22,
            linkedKeychainItemID: UUID(),
            requiresLinkedKeychainItem: true
        )
        #expect(acceptedMessages.isEmpty)
    }

    @Test func keychainValidationRejectsMissingSecretAndDuplicateNames() {
        let messages = ProfileValidation.keychainItemMessages(
            name: "Deploy Key",
            secret: "",
            kind: .sshKey,
            existingNames: ["deploy key"]
        )

        #expect(messages.contains("A keychain item with this name already exists in this vault."))
        #expect(messages.contains("Private key is required."))
    }

    @Test func keychainValidationRejectsTypeChangeWhenLinkedToHosts() {
        let messages = ProfileValidation.keychainItemMessages(
            name: "Production Password",
            secret: "secret",
            kind: .sshKey,
            originalKind: .password,
            isLinkedToHosts: true
        )

        #expect(messages == ["Keychain item type cannot change while linked hosts use it."])

        let allowedMessages = ProfileValidation.keychainItemMessages(
            name: "Production Password",
            secret: "secret",
            kind: .password,
            originalKind: .password,
            isLinkedToHosts: true
        )
        #expect(allowedMessages.isEmpty)
    }

    @Test func snippetValidationRejectsMissingCommandAndDuplicateTitles() {
        let messages = ProfileValidation.snippetMessages(
            title: "Tail Logs",
            command: " ",
            existingTitles: ["tail logs"]
        )

        #expect(messages.contains("A snippet with this title already exists in this vault."))
        #expect(messages.contains("Command is required."))
    }
}
