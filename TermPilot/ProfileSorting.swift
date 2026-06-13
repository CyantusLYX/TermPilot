import Foundation
import SwiftUI

protocol MenuSortOption: CaseIterable, Hashable, Identifiable {
    var title: String { get }
    var systemImage: String { get }
}

extension MenuSortOption where Self: RawRepresentable, RawValue == String {
    var id: String { rawValue }
}

enum VaultSortOption: String, MenuSortOption {
    case name
    case recentlyUpdated
    case newestCreated

    var title: String {
        switch self {
        case .name:
            "Name"
        case .recentlyUpdated:
            "Recently Updated"
        case .newestCreated:
            "Newest Created"
        }
    }

    var systemImage: String {
        switch self {
        case .name:
            "textformat"
        case .recentlyUpdated:
            "clock.arrow.circlepath"
        case .newestCreated:
            "calendar.badge.plus"
        }
    }
}

enum HostSortOption: String, MenuSortOption {
    case alias
    case host
    case recentlyConnected
    case recentlyUpdated

    var title: String {
        switch self {
        case .alias:
            "Alias"
        case .host:
            "Host"
        case .recentlyConnected:
            "Recently Connected"
        case .recentlyUpdated:
            "Recently Updated"
        }
    }

    var systemImage: String {
        switch self {
        case .alias:
            "textformat"
        case .host:
            "server.rack"
        case .recentlyConnected:
            "terminal"
        case .recentlyUpdated:
            "clock.arrow.circlepath"
        }
    }
}

enum KeychainSortOption: String, MenuSortOption {
    case name
    case recentlyUpdated
    case newestCreated

    var title: String {
        switch self {
        case .name:
            "Name"
        case .recentlyUpdated:
            "Recently Updated"
        case .newestCreated:
            "Newest Created"
        }
    }

    var systemImage: String {
        switch self {
        case .name:
            "textformat"
        case .recentlyUpdated:
            "clock.arrow.circlepath"
        case .newestCreated:
            "calendar.badge.plus"
        }
    }
}

enum SnippetSortOption: String, MenuSortOption {
    case title
    case recentlyUpdated
    case newestCreated

    var title: String {
        switch self {
        case .title:
            "Title"
        case .recentlyUpdated:
            "Recently Updated"
        case .newestCreated:
            "Newest Created"
        }
    }

    var systemImage: String {
        switch self {
        case .title:
            "textformat"
        case .recentlyUpdated:
            "clock.arrow.circlepath"
        case .newestCreated:
            "calendar.badge.plus"
        }
    }
}

enum TerminalSessionSortOption: String, MenuSortOption {
    case recentActivity
    case startedAt
    case title
    case state

    var title: String {
        switch self {
        case .recentActivity:
            "Recent Activity"
        case .startedAt:
            "Started"
        case .title:
            "Host Name"
        case .state:
            "State"
        }
    }

    var systemImage: String {
        switch self {
        case .recentActivity:
            "clock.arrow.circlepath"
        case .startedAt:
            "calendar"
        case .title:
            "textformat"
        case .state:
            "circle.lefthalf.filled"
        }
    }
}

struct SortOptionsMenu<Option: MenuSortOption>: View {
    @Binding var selection: Option

    var body: some View {
        Menu {
            Picker("Sort By", selection: $selection) {
                ForEach(Array(Option.allCases), id: \.id) { option in
                    Label(option.title, systemImage: option.systemImage)
                        .tag(option)
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort")
    }
}

enum SortOptionStorage {
    static func value<Option: RawRepresentable>(
        from rawValue: String,
        default defaultValue: Option
    ) -> Option where Option.RawValue == String {
        Option(rawValue: rawValue) ?? defaultValue
    }
}

extension Binding where Value == String {
    func sortOption<Option: RawRepresentable>(
        _ type: Option.Type,
        default defaultValue: Option
    ) -> Binding<Option> where Option.RawValue == String {
        Binding<Option> {
            SortOptionStorage.value(from: wrappedValue, default: defaultValue)
        } set: { option in
            wrappedValue = option.rawValue
        }
    }
}

enum ProfileSorting {
    static func sortVaults(_ vaults: [VaultProfile], by option: VaultSortOption) -> [VaultProfile] {
        vaults.sorted { lhs, rhs in
            switch option {
            case .name:
                return orderedByText(lhs.name, rhs.name, tie: lhs.createdAt < rhs.createdAt)
            case .recentlyUpdated:
                return newestFirst(lhs.updatedAt, rhs.updatedAt, tie: orderedByText(lhs.name, rhs.name))
            case .newestCreated:
                return newestFirst(lhs.createdAt, rhs.createdAt, tie: orderedByText(lhs.name, rhs.name))
            }
        }
    }

    static func sortHosts(_ hosts: [HostProfile], by option: HostSortOption) -> [HostProfile] {
        hosts.sorted { lhs, rhs in
            switch option {
            case .alias:
                return orderedByText(lhs.alias, rhs.alias, tie: orderedByText(lhs.host, rhs.host))
            case .host:
                return orderedByText(lhs.host, rhs.host, tie: orderedByText(lhs.alias, rhs.alias))
            case .recentlyConnected:
                return newestOptionalFirst(lhs.lastConnectedAt, rhs.lastConnectedAt, tie: orderedByText(lhs.alias, rhs.alias))
            case .recentlyUpdated:
                return newestFirst(lhs.updatedAt, rhs.updatedAt, tie: orderedByText(lhs.alias, rhs.alias))
            }
        }
    }

    static func sortKeychainItems(_ items: [KeychainItemProfile], by option: KeychainSortOption) -> [KeychainItemProfile] {
        items.sorted { lhs, rhs in
            switch option {
            case .name:
                return orderedByText(lhs.name, rhs.name, tie: orderedByText(lhs.kind.title, rhs.kind.title))
            case .recentlyUpdated:
                return newestFirst(lhs.updatedAt, rhs.updatedAt, tie: orderedByText(lhs.name, rhs.name))
            case .newestCreated:
                return newestFirst(lhs.createdAt, rhs.createdAt, tie: orderedByText(lhs.name, rhs.name))
            }
        }
    }

    static func sortSnippets(_ snippets: [SnippetProfile], by option: SnippetSortOption) -> [SnippetProfile] {
        snippets.sorted { lhs, rhs in
            switch option {
            case .title:
                return orderedByText(lhs.title, rhs.title, tie: lhs.createdAt < rhs.createdAt)
            case .recentlyUpdated:
                return newestFirst(lhs.updatedAt, rhs.updatedAt, tie: orderedByText(lhs.title, rhs.title))
            case .newestCreated:
                return newestFirst(lhs.createdAt, rhs.createdAt, tie: orderedByText(lhs.title, rhs.title))
            }
        }
    }

    static func sortTerminalSessions(_ sessions: [TerminalSession], by option: TerminalSessionSortOption) -> [TerminalSession] {
        sessions.sorted { lhs, rhs in
            switch option {
            case .recentActivity:
                return newestFirst(lhs.lastActivityAt, rhs.lastActivityAt, tie: orderedByText(lhs.title, rhs.title))
            case .startedAt:
                return newestFirst(lhs.startedAt, rhs.startedAt, tie: orderedByText(lhs.title, rhs.title))
            case .title:
                return orderedByText(lhs.title, rhs.title, tie: newestFirst(lhs.lastActivityAt, rhs.lastActivityAt))
            case .state:
                let lhsRank = stateRank(lhs.state)
                let rhsRank = stateRank(rhs.state)
                return lhsRank == rhsRank
                    ? orderedByText(lhs.title, rhs.title)
                    : lhsRank < rhsRank
            }
        }
    }

    private static func orderedByText(_ lhs: String, _ rhs: String, tie: Bool = false) -> Bool {
        switch lhs.localizedStandardCompare(rhs) {
        case .orderedAscending:
            return true
        case .orderedDescending:
            return false
        case .orderedSame:
            return tie
        }
    }

    private static func newestFirst(_ lhs: Date, _ rhs: Date, tie: Bool = false) -> Bool {
        lhs == rhs ? tie : lhs > rhs
    }

    private static func newestOptionalFirst(_ lhs: Date?, _ rhs: Date?, tie: Bool = false) -> Bool {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            newestFirst(lhs, rhs, tie: tie)
        case (_?, nil):
            true
        case (nil, _?):
            false
        case (nil, nil):
            tie
        }
    }

    private static func stateRank(_ state: TerminalSessionState) -> Int {
        switch state {
        case .connecting:
            0
        case .connected:
            1
        case .failed:
            2
        case .disconnected:
            3
        case .closed:
            4
        }
    }
}
