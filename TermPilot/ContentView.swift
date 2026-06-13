import SwiftData
import SwiftUI

struct ContentView: View {
    @State private var syncUnlockStore = SyncUnlockStore()
    @State private var tabRouter = TabRouter()
    @State private var terminalSessionManager = TerminalSessionManager()
    @State private var secureSecretStore = SecureSecretStore()

    @AppStorage("appTheme") private var appThemeRawValue = AppTheme.system.rawValue

    private var appTheme: AppTheme {
        AppTheme(rawValue: appThemeRawValue) ?? .system
    }

    var body: some View {
        ZStack {
            if syncUnlockStore.isUnlocked {
                MainTabView()
                    .transition(.asymmetric(
                        insertion: .scale.combined(with: .opacity),
                        removal: .opacity
                    ))
            } else {
                LoginView()
                    .transition(.opacity)
            }
        }
        .animation(.smooth, value: syncUnlockStore.isUnlocked)
        .task {
            await syncUnlockStore.restorePreviousSession()
        }
        .environment(syncUnlockStore)
        .environment(tabRouter)
        .environment(terminalSessionManager)
        .environment(secureSecretStore)
        .preferredColorScheme(appTheme.colorScheme)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [
            VaultProfile.self,
            HostProfile.self,
            KeychainItemProfile.self,
            SnippetProfile.self,
            AppSettings.self
        ], inMemory: true)
}
