# Settings View 規劃

## 目標

Settings View 管理 App 偏好設定、terminal 顯示設定、LLM provider API key，以及使用者登出。這個畫面要保持表單化、清楚、可快速展示。

## 使用者流程

1. 使用者打開 Settings tab。
2. 在 Appearance 區塊切換 Dark / Light / System。
3. 在 Terminal 區塊調整字體大小。
4. 在 AI Providers 區塊輸入或更新 OpenAI / Anthropic / Gemini API key。
5. 使用者可選擇預設 AI provider。
6. 使用者可登出 Google 帳號並回到 Login View。

## 主要功能

- Dark / Light / System theme preference。
- Terminal font size slider 或 stepper。
- OpenAI API key 管理。
- Anthropic API key 管理。
- Gemini API key 管理。
- 預設 AI provider 選擇。
- Google sign out。
- 顯示目前登入使用者 profile metadata。

## SwiftUI 實作方向

- 使用 `Form` + `Section` 建構 settings。
- Theme 使用 segmented picker 或 menu picker。
- Font size 使用 slider 或 stepper，範圍固定為 10pt 到 24pt，並顯示目前 pt 值。
- API key row 顯示 provider 名稱與是否已設定，不顯示完整 key；尾碼顯示只作為 debug/demo convenience，預設 UI 可只顯示「已設定」。
- 編輯 API key 可用 secure field sheet，儲存後寫入 Keychain。
- Sign out button 放在 Account section，使用 destructive role。
- Settings 偏好 v1 以 `@AppStorage` 作為 source of truth，透過 `SettingsStore` wrapper 暴露給 UI；secrets 一律不走 `AppStorage`。

## 資料與服務

- `SettingsStore`：包裝 `@AppStorage` 中的 theme、terminal font size、default AI provider，提供可觀察的設定狀態與更新方法。
- `SecureSecretStore`：保存 OpenAI / Anthropic / Gemini API key。
- `AuthStore`：處理 Firebase / Google sign out。
- `TabRouter`：讓 Terminal 的 AI 設定入口可以切換到 Settings tab。
- `LocalDataWipeService`：登出時清空 SwiftData 中的 local vault / host / keychain / snippet metadata。

## 安全原則

- OpenAI / Anthropic / Gemini API key 不寫入 SwiftData、`UserDefaults`、plist、source code 或 log。
- UI 預設只顯示「已設定」；若錄影或 debug 需要尾碼提示，例如 `...abcd`，不可顯示完整 key。
- 更新 key 採 Keychain add-or-update。
- 刪除 key 時要同步移除 Keychain item。
- 全量刪除 secret 的 API 必須命名並限制 scope 為 `deleteAllTermPilotSecrets()`，只刪指定 service / access group / account prefix，不可誤刪非 TermPilot item。
- 登出採嚴格零知識策略，必須清除本機 SwiftData metadata 與 Keychain secrets。

## 後續細節待補與實作決策

### 1. API Key 格式驗證與 Provider-specific 錯誤提示

- Local validation 在使用者點擊 Test Connection 或儲存前執行，避免浪費明顯無效網路請求。
- Provider-specific key prefix 可能變動，因此格式檢查只顯示 warning，不阻擋儲存。
- 真正阻擋儲存的情況只包含空白 key、包含換行、或明顯過短。
- OpenAI：若 key 不是 `sk-` 或 `sk-proj-` 開頭，顯示 warning。
- Anthropic：若 key 不是 `sk-ant-` 開頭，顯示 warning。
- Gemini：若 key 含不常見字元或過短，阻擋或 warning 依嚴重程度處理。
- Test Connection 與儲存前都先 trim 前後空白與換行；Keychain 只保存 normalized 後的 key，避免使用者從 provider console 複製時帶入隱藏字元。
- 若格式可疑，在 `SecureField` 下方即時顯示 provider-specific warning，例如 `Anthropic API Key format looks unusual`。
- 若格式正確但 Test Connection 網路測試失敗，例如 HTTP 401，顯示 provider API 回傳或 mapping 後的錯誤訊息。
- Test Connection timeout 固定為 10 秒；失敗時只顯示 provider、HTTP status、request id 或 redacted error，不 log API key 或完整 response body。
- Test Connection 不應把完整 API key 寫入 log；只可記錄 provider、狀態碼與 request id。
- Keychain load / save / delete 失敗時不可用 `try?` 靜默吞掉；需在 sheet 內顯示錯誤並阻止 dismiss，讓使用者知道 secret 沒有被正確更新或移除。

### 2. Default Provider 未設定 Key 的 UI

- 初次安裝時，`selectedProvider` 預設為 OpenAI，但 API key 為空。
- Terminal & AI Assistant View 的 AI 魔法棒按鈕會先呼叫 `AIAnalysisService.hasAPIKey(for:)`。
- 若找不到目前 provider 的 key，AI bottom sheet 不顯示 loading，也不發 request。
- Bottom sheet 直接顯示：「尚未設定 {Provider} API Key」。
- Bottom sheet 提供「前往設定」按鈕，點擊後透過 `TabRouter.openSettingsAPIKey(provider:)` 切換至 Settings tab，並 push 到 `SettingsRoute.apiKey(provider:)`。
- 回到 Settings 後，API Keys 子頁會自動打開對應 provider 的 key editor sheet；若使用者關閉 sheet，列表仍顯示該 provider 的目前 Keychain 設定狀態。

### 3. Font Size 範圍與 Terminal Preview

- Terminal font size 限制在 10pt 到 24pt。
- 控制元件優先使用 Slider，左右兩側放小 `A` / 大 `A` 圖示；若需要精準微調，可再加 Stepper。
- 設定值綁定 `@AppStorage("terminalFontSize")`，讓 Settings 與 Terminal View 共用。
- Settings 的 Terminal 區塊下方放 live preview：黑底圓角矩形，內含 monospace 範例文字。
- 範例文字：

```text
root@myserver:~$ tail -f /var/log/syslog
```

- preview 使用 `.monospaced()` 並套用目前 font size；拖曳 Slider 時即時放大縮小。

### 4. Theme Preference 與 App Root 串接

- 建立 `AppTheme` enum：

```swift
enum AppTheme: Int, CaseIterable {
    case system = 0
    case light = 1
    case dark = 2

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
```

- Settings 使用 Picker 綁定 `@AppStorage("appTheme")`。
- App 的進入點或最外層 `ContentView` 套用 `.preferredColorScheme(theme.colorScheme)`。
- `system` 對應 `nil`，跟隨系統；`light` 對應 `.light`；`dark` 對應 `.dark`。

### 5. Sign Out 的資料抹除策略

- 採嚴格零知識策略：登出必須等同於抹除本機所有明文與機密資料。
- 原因：同步資料由 Master Password 解密；如果登出後保留本機 SwiftData metadata 或 Keychain secrets，下一個拿到裝置的人可能不需同步主密碼就看到 server 或 password。
- 點擊 Sign Out 時先顯示 destructive confirmation dialog，說明本機資料將被清除，雲端 encrypted blob 不會被刪除。
- 抹除流程：
  1. Disable Settings UI，避免重複點擊。
  2. 關閉 `TerminalSessionManager` 的 active sessions、SSH read loops、retained logs 與 `SessionRecorder` buffers。
  3. 透過 `LocalDataWipeService` 清除 SwiftData 中所有 `VaultProfile`、`HostProfile`、`KeychainItemProfile`、`SnippetProfile`；可用 ModelContext batch delete 或逐 model fetch/delete。
  4. 呼叫 `KeychainService.deleteAllTermPilotSecrets()`，清除 TermPilot service / access group / account prefix 下的可重用 Master Password key material（若存在）、SSH private keys、passwords、passphrases、AI API keys。
  5. 呼叫 Firebase Auth `signOut()`，並同步清除 Google Sign-In session。
  6. 將全域 app state 設回 `unauthenticated`，強制回到 Login View。
- 登出不刪除 Firestore `users/{uid}/syncData/latest` encrypted blob；使用者下次登入仍可用同步主密碼解鎖雲端資料。
- 若 wipe 中任一步驟失敗，應顯示錯誤並阻止切回 unauthenticated，避免留下半清除狀態。
- Sign out 執行期間按鈕需進入 disabled / loading 狀態，避免使用者連點造成重複 sign out 或重複 wipe。
