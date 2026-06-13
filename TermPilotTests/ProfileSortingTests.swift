import Foundation
import Testing
@testable import TermPilot

struct ProfileSortingTests {
    @Test func sortOptionStorageFallsBackForUnknownRawValue() {
        #expect(SortOptionStorage.value(from: "unknown", default: VaultSortOption.name) == .name)
        #expect(SortOptionStorage.value(from: HostSortOption.host.rawValue, default: HostSortOption.alias) == .host)
    }

    @Test func vaultSortingSupportsNameAndRecentUpdate() {
        let older = Date(timeIntervalSince1970: 10)
        let newer = Date(timeIntervalSince1970: 20)
        let beta = VaultProfile(name: "Beta", createdAt: older, updatedAt: older)
        let alpha = VaultProfile(name: "Alpha", createdAt: newer, updatedAt: newer)

        #expect(ProfileSorting.sortVaults([beta, alpha], by: .name).map(\.name) == ["Alpha", "Beta"])
        #expect(ProfileSorting.sortVaults([beta, alpha], by: .recentlyUpdated).map(\.name) == ["Alpha", "Beta"])
    }

    @Test func hostSortingPlacesRecentlyConnectedHostsFirstAndNilLast() {
        let vaultID = UUID()
        let older = Date(timeIntervalSince1970: 10)
        let newer = Date(timeIntervalSince1970: 20)
        let neverConnected = HostProfile(
            vaultID: vaultID,
            alias: "Never",
            host: "never.example.com",
            username: "root",
            lastConnectedAt: nil
        )
        let recent = HostProfile(
            vaultID: vaultID,
            alias: "Recent",
            host: "recent.example.com",
            username: "root",
            lastConnectedAt: newer
        )
        let old = HostProfile(
            vaultID: vaultID,
            alias: "Old",
            host: "old.example.com",
            username: "root",
            lastConnectedAt: older
        )

        #expect(ProfileSorting.sortHosts([neverConnected, old, recent], by: .recentlyConnected).map(\.alias) == [
            "Recent",
            "Old",
            "Never"
        ])
    }

    @Test func keychainAndSnippetSortingSupportRecentUpdate() {
        let vaultID = UUID()
        let older = Date(timeIntervalSince1970: 10)
        let newer = Date(timeIntervalSince1970: 20)
        let password = KeychainItemProfile(
            vaultID: vaultID,
            name: "Password",
            kind: .password,
            secretAccount: "password-secret",
            updatedAt: older
        )
        let key = KeychainItemProfile(
            vaultID: vaultID,
            name: "Deploy Key",
            kind: .sshKey,
            secretAccount: "key-secret",
            updatedAt: newer
        )
        let tail = SnippetProfile(vaultID: vaultID, title: "Tail Logs", command: "tail -f app.log", updatedAt: older)
        let deploy = SnippetProfile(vaultID: vaultID, title: "Deploy", command: "./deploy", updatedAt: newer)

        #expect(ProfileSorting.sortKeychainItems([password, key], by: .recentlyUpdated).map(\.name) == [
            "Deploy Key",
            "Password"
        ])
        #expect(ProfileSorting.sortSnippets([tail, deploy], by: .recentlyUpdated).map(\.title) == [
            "Deploy",
            "Tail Logs"
        ])
    }

    @Test func terminalSortingCanUseActivityTitleOrState() {
        let older = Date(timeIntervalSince1970: 10)
        let newer = Date(timeIntervalSince1970: 20)
        let disconnected = TerminalSession(
            title: "Beta",
            subtitle: "root@beta",
            state: .disconnected,
            lastActivityAt: older
        )
        let connected = TerminalSession(
            title: "Alpha",
            subtitle: "root@alpha",
            state: .connected,
            lastActivityAt: newer
        )
        let connecting = TerminalSession(
            title: "Gamma",
            subtitle: "root@gamma",
            state: .connecting,
            lastActivityAt: older
        )

        #expect(ProfileSorting.sortTerminalSessions([disconnected, connected, connecting], by: .recentActivity).map(\.title) == [
            "Alpha",
            "Beta",
            "Gamma"
        ])
        #expect(ProfileSorting.sortTerminalSessions([disconnected, connected, connecting], by: .title).map(\.title) == [
            "Alpha",
            "Beta",
            "Gamma"
        ])
        #expect(ProfileSorting.sortTerminalSessions([disconnected, connected, connecting], by: .state).map(\.title) == [
            "Gamma",
            "Alpha",
            "Beta"
        ])
    }
}
