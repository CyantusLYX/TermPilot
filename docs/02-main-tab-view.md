# Main Tab View & Architecture

## 目標

Main Tab View 是 App 登入並完成同步解鎖後的主層級導覽。它捨棄扁平的「主機 / 憑證」分離設計，改採 Vault-centric 架構：Vaults 是主要工作區，Terminals 負責切換活躍 SSH 會話，Settings 管理全域偏好與 AI API key。

Main Tab View 需在 iPhone 上顯示 bottom tab bar。iPad sidebar/adaptable 行為列為 P2，錄影版本優先確保 iPhone simulator 流程穩定。每個 tab 都保留自己的 navigation state。

## 使用者流程

1. 使用者在 Login View 或同步主密碼解鎖畫面成功驗證後，透過平滑轉場進入 Main Tab View。
2. 預設顯示第一個 tab：Vaults。
3. 使用者在 Vaults 中進入 Personal Vault，管理 Hosts、Keychain 與未來的 Snippets。
4. 使用者從 Vaults 的 Host 啟動 SSH session 後，App 建立 terminal session，並可切換到 Terminals tab 顯示該 session。
5. 使用者點擊 Terminals 可快速回到正在背景執行或剛斷線但保留 log 的 SSH 會話。
6. 使用者點擊 Settings 進行全域外觀、terminal 字體、AI provider API key 與登出管理。
7. 若使用者已在目前 tab，再次點擊該 tab icon，可選擇觸發 pop to root；此行為為 optional UX，不阻塞 terminal 錄影主線。

## 主要功能

- 整合 `VaultsFlowView`、`TerminalsView` 與 `SettingsView`。
- iPhone 使用 bottom tab bar；iPad 系統自適應 sidebar 列為 P2。
- 每個 tab 維護獨立 `NavigationPath`，切換 tab 不重置深層畫面。
- 可選支援重複點擊目前 tab 時 pop to root；若 SwiftUI `TabView(selection:)` 無法穩定捕捉同 selection，v1 可不實作。
- Vaults tab 是所有設定檔入口，包含 Vault Dashboard、Hosts、Keychain 與未來 Snippets。
- Terminals tab 顯示活躍或保留 log 的 sessions，點擊 session 進入 Terminal & AI Assistant View。
- 根據 `TerminalSessionManager` 的 active session count 顯示 Terminals badge；v1 規則為 0 不顯示、1...99 顯示數字、100 以上顯示 `99+`。
- Settings tab sign out 成功後，由 root shell 回到 Login View。

## Tab 規劃

- Vaults：圖示使用 `archivebox` 或 `server.rack`。作為所有資料的入口，預設顯示 Personal Vault 的 dashboard；若未來支援多 Vault，先顯示 All Vaults。
- Terminals：圖示使用 `terminal`。顯示目前正在連線中，或剛斷線但保留 log 的 SSH sessions。
- Settings：圖示使用 `gearshape`。管理外觀、terminal、AI API key、同步與登出。

## SwiftUI 實作方向

- 專案目前 iOS target 高於 iOS 18，v1 已使用新的 `Tab` API；若未來 target 下修，再改回傳統 `.tabItem`。
- `MainTabView` 使用 `TabView(selection:)` 管理目前選取的 `AppTab`。
- `AppTab` 定義為 `Hashable` enum：`vaults`、`terminals`、`settings`。
- 每個 tab 內包一層獨立 `NavigationStack(path:)`。
- `vaultsPath`、`terminalsPath`、`settingsPath` 在 `MainTabView` 或 `TabRouter` 中以 `@State` / `@Observable` 保存。
- route 使用 type-safe enum，例如 `VaultsRoute.hostDetail(id:)`、`VaultsRoute.keychainItem(id:)`、`TerminalsRoute.session(id:)`、`SettingsRoute.apiKey(provider:)`。
- root shell 監聽 `SyncUnlockStore.state`，從 Login / Unlock 切到 Main Tab 時使用 transition：

```swift
.transition(.asymmetric(
    insertion: .scale.combined(with: .opacity),
    removal: .opacity
))
```

- 重複點擊目前 tab 的 pop-to-root 需使用 custom tab button handler 或明確測試目前實作；不能只依賴 `TabView(selection:)` 的 `onChange`，因為相同 selection 可能不觸發。
- Terminals tab 的 badge 綁定 `TerminalSessionManager.activeBadgeLabel`：

```swift
.badge(terminalSessionManager.activeBadgeLabel.map { Text($0) })
```

- 共享 store 透過 SwiftUI environment 注入，例如 `AuthStore`、`SyncUnlockStore`、`SettingsStore`、repositories、`TerminalSessionManager`。
- tab icon 使用 SF Symbols：Vaults `archivebox` 或 `server.rack`、Terminals `terminal`、Settings `gearshape`。
- v1 已套用 `.tabViewStyle(.sidebarAdaptable)`，讓 iPad 交給系統轉為 adaptable sidebar。
- tab root view 不可在初始化或 `onAppear` 自動啟動 SSH connection、讀取 Keychain secret、或發送 LLM request；這些操作只能由使用者明確動作觸發。

## 建議結構

```swift
enum AppTab: Hashable {
    case vaults
    case terminals
    case settings
}

@MainActor
@Observable
final class TabRouter {
    var selectedTab: AppTab = .vaults
    var vaultsPath = NavigationPath()
    var terminalsPath = NavigationPath()
    var settingsPath = NavigationPath()

    func select(_ tab: AppTab) {
        if selectedTab == tab {
            popToRoot(tab)
        } else {
            selectedTab = tab
        }
    }

    func popToRoot(_ tab: AppTab) {
        switch tab {
        case .vaults:
            vaultsPath = NavigationPath()
        case .terminals:
            terminalsPath = NavigationPath()
        case .settings:
            settingsPath = NavigationPath()
        }
    }

    func openSettingsAPIKey(provider: AIProvider) {
        selectedTab = .settings
        settingsPath = NavigationPath()
        settingsPath.append(SettingsRoute.apiKey(provider: provider))
    }
}
```

## 資料與服務

- `AppTab`：主 tab selection。
- `TabRouter`：管理目前 tab 與各 tab 的 `NavigationPath`。
- `VaultsRoute`、`TerminalsRoute`、`SettingsRoute`：各 tab 的 type-safe route enum。
- `TerminalSessionManager`：發布目前活躍 SSH session 數量與 badge label，供 Terminals tab 使用，並提供 session lookup / close / reconnect。
- `TabRouter.openSettingsAPIKey(provider:)`：切到 Settings tab、push `SettingsRoute.apiKey(provider:)`，必要時由 Settings 子頁自動打開 API key editor sheet。
- `SyncUnlockStore`：由 root shell 判斷是否顯示 Main Tab View。
- `AuthStore`：Settings sign out 後更新登入狀態。
- `SettingsStore`：提供 theme、terminal font size 等全域設定。

## 詳細架構與邊界決策

- iPad sidebar 支援列為 P2；目前優先交給 SwiftUI `TabView` / `Tab` API 的 adaptable 行為，不手刻 `NavigationSplitView`。
- 每個 tab 的 stack 獨立保存，避免跨 tab 共用單一 `NavigationPath` 導致 route 混雜。
- Host 啟動連線的入口在 Vaults tab；成功建立 session 後，由 `TerminalSessionManager` 建立 session record，並可切換到 Terminals tab。
- Terminal View 由 Terminals 的 route push 進入，route payload 使用 `sessionID`，Terminal session 由 `TerminalSessionManager` 查找。
- Terminal route 必須做 guard：若 `sessionID` 查不到或 session 已 `closed`，顯示「Session no longer exists」並提供返回 Terminals list 的 action，不建立新的 session。
- 進入 Terminal 後可使用 `.toolbar(.hidden, for: .tabBar)` 隱藏底部導覽列；返回 Terminals session list 時恢復。
- `TabView` 可能會提前建立子 View，`VaultsFlowView` 與 `SettingsView` 的 `onAppear` 必須輕量，資料載入改用 async task / repository，不在 main thread 做同步 I/O。
- tab root 的 async task 只能載入非機密 metadata；SSH connection、Keychain secret read、LLM request 都必須由 user action 觸發。
- active session badge 只顯示數量，不直接反映連線健康；詳細連線狀態留在 Terminals / Terminal 畫面。
- root transition 由 ContentView / AppShell 負責，Main Tab View 本身不直接處理 login state mutation。

## 測試情境

- 登入並同步解鎖成功後，預設進入 Vaults tab。
- 切換 Vaults / Terminals / Settings 時，各 tab 的 navigation path 保持不變。
- 從 Vaults 啟動 host 後成功建立 terminal session，Terminals badge 增加。
- 在 Terminal 畫面切到 Vaults 再切回 Terminals，仍能回到原本 session。
- 若實作 custom tab button handler，在目前 tab 再次點擊 tab icon 時該 tab pop to root；若使用系統 TabView 無法穩定捕捉同 selection，v1 可略過。
- active session count 從 0 變 1 時，Terminals tab 顯示 badge；回到 0 時 badge 消失。
- iPhone 顯示 bottom tab bar；iPad adaptable sidebar 行為列為 P2，不阻塞錄影版本。
- tab root 初始化與 `onAppear` 不會啟動 SSH、讀取 Keychain secret 或發送 LLM request。
- 打開不存在或已關閉的 `TerminalsRoute.session(id:)` 時，顯示「Session no longer exists」並可返回 Terminals list。
- Settings sign out 後，root shell 回到 Login View，不保留 Main Tab 畫面。

## 後續細節待補

- P2：`Tab` API 實作時的實際 iPad sidebar 行為截圖。
- Terminal route guard 與 deep link unavailable-state 的 UI copy。
- Terminal 隱藏 tab bar 的細節與返回動畫。
