import SwiftUI

struct MainTabView: View {
    @Environment(TabRouter.self) private var router
    @Environment(TerminalSessionManager.self) private var terminalSessionManager

    var body: some View {
        @Bindable var router = router

        TabView(selection: Binding(
            get: { router.selectedTab },
            set: { router.select($0) }
        )) {
            Tab("Vaults", systemImage: "archivebox", value: AppTab.vaults) {
                NavigationStack(path: $router.vaultsPath) {
                    VaultsFlowView()
                        .navigationDestination(for: VaultsRoute.self, destination: vaultsDestination)
                }
            }

            Tab("Terminals", systemImage: "terminal", value: AppTab.terminals) {
                NavigationStack(path: $router.terminalsPath) {
                    TerminalsView()
                        .navigationDestination(for: TerminalsRoute.self, destination: terminalsDestination)
                }
            }
            .badge(terminalSessionManager.activeBadgeLabel.map { Text($0) })

            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                NavigationStack(path: $router.settingsPath) {
                    SettingsView()
                        .navigationDestination(for: SettingsRoute.self, destination: settingsDestination)
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }

    @ViewBuilder
    private func vaultsDestination(_ route: VaultsRoute) -> some View {
        switch route {
        case .vaultDashboard(let vaultID):
            VaultDashboardRouteView(vaultID: vaultID)
        case .hosts(let vaultID):
            HostsListView(vaultID: vaultID)
        case .hostDetail(let hostID):
            HostDetailRouteView(hostID: hostID)
        case .keychain(let vaultID):
            VaultKeychainListView(vaultID: vaultID)
        case .keychainItem(let id):
            KeychainItemDetailRouteView(itemID: id)
        case .snippets(let vaultID):
            SnippetsListView(vaultID: vaultID)
        }
    }

    @ViewBuilder
    private func terminalsDestination(_ route: TerminalsRoute) -> some View {
        switch route {
        case .session(let sessionID):
            TerminalPlaceholderView(sessionID: sessionID)
        }
    }
}

@ViewBuilder
private func settingsDestination(_ route: SettingsRoute) -> some View {
    switch route {
    case .apiKeys:
        APIKeysSettingsView()
    case .apiKey(let provider):
        APIKeysSettingsView(focusedProvider: provider)
    }
}
