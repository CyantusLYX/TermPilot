# TermPilot 視圖規劃總覽

## 目標

TermPilot 是一個以 iPhone simulator 錄影展示為目標的 SSH terminal app，核心概念是「有 LLM 輔助的 Termius」。使用者可以儲存伺服器連線、管理登入憑證與 SSH key，進入 terminal 後用 AI 分析錯誤訊息並取得建議指令。

本階段優先追求錄影展示完整度、可重拍、畫面可控與功能可信度，不以 live demo failure recovery 作為主要設計導向。v1 登入 UI 只規劃 Google 登入，並透過 Firebase Authentication 取得穩定 `uid`；若未來要上架，再重新評估 Apple App Review Guideline 4.8，補上 Sign in with Apple 或其他符合要求的等效登入選項。

## 畫面與文件

- [Login View](01-login-view.md)：Firebase Auth 登入與加密同步解鎖入口。
- [Main Tab View](02-main-tab-view.md)：Vaults / Terminals / Settings 主導覽架構。
- [Vaults Navigation Flow](03-vaults-flow.md)：以 Vault 為核心管理 Hosts、Keychain 與未來 Snippets。
- [Terminals View](04-terminals-view.md)：管理活躍或保留 log 的 SSH terminal sessions。
- [Terminal & AI Assistant View](05-terminal-ai-assistant-view.md)：終端機與 AI 診斷建議。
- [Settings View](06-settings-view.md)：偏好設定、LLM API key 與登出。
- [LLM Integration & Tool Use](07-llm-integration-tool-use.md)：LLM provider、prompt、tool use 與指令審核規格。
- [Tech Stack Selection](08-tech-stack-selection.md)：SwiftTerm、Citadel、SessionRecorder 與 security 技術選型。

## 整體使用者流程

1. App 啟動時監聽 Firebase Auth 狀態。
2. 未登入時顯示 Login View；Google 登入成功後取得 Firebase `uid`。
3. App 讀取 Firestore `users/{uid}/syncData/latest`；若有同步 blob，要求同步主密碼解鎖。
4. 同步解鎖成功或使用者選擇先不啟用同步後，進入 Main Tab View。
5. Main Tab View 提供 Vaults、Terminals、Settings 三個 tab。
6. 使用者在 Vaults 進入某個 Vault，於 Hosts 內選擇 server profile 並建立 SSH session。
7. 建立 session 後進入 Terminal View；使用者可從 Terminals tab 切換多個活躍或保留 log 的 sessions。
8. Terminal View 顯示終端輸出；使用者點擊 AI 分析按鈕後，以 bottom sheet 顯示診斷結果與建議指令。
9. Settings 可調整外觀、terminal 字體大小，並儲存 OpenAI / Anthropic / Gemini API key。

## 架構方向

- SwiftUI 作為 UI 框架，主流程採 `TabView` + 各 tab 獨立 `NavigationStack`。
- 先採 Model-View / `@Observable` store 的輕量架構，讓錄影版本可以快速迭代；若 terminal session 或 AI workflow 變複雜，再抽出更明確的 ViewModel 或 service boundary。
- SwiftData 用於儲存本機資料與非機密 metadata，例如 vault 名稱、host profile、keychain item 顯示名稱、settings 偏好。
- Firestore 只儲存 AES.GCM 加密後的同步 blob 與必要 metadata，不攤平保存 server / vault 明文欄位。
- Keychain 用於儲存所有 secrets，例如 SSH password、private key、LLM API key、OAuth token 類資料。
- CryptoKit / CommonCrypto 用於同步 payload 加密與同步主密碼 key derivation。
- 接下來主要開發集中在 `SwiftTermTerminalViewRepresentable`、`SSHSessionDriver`、`TerminalSessionManager`、`SessionRecorder` 串接，先完成可錄影的 terminal usable path。
- 現有 Xcode starter 的 `Item` 範例未來會被 `VaultProfile`、`HostProfile`、`KeychainItemProfile`、`TerminalSession` 與 `SettingsStore` / `@AppStorage` 設定取代。

## Implementation Status

- Auth / Login：mostly implemented，剩餘重點是 sign-out coordinator 與 sync unlock 細節收斂。
- Vaults / Hosts / Keychain / Snippets：mostly implemented，剩餘重點是 SSH auth compatibility 與 terminal session 協調。
- Settings / API Keys：mostly implemented，剩餘重點是 Keychain scope、provider test timeout 與登出抹除順序。
- LLM provider / Tool Use：mostly implemented at interface level；錄影片版本可固定 primary provider，其餘 provider 保留 adapter 或 mock。
- Terminal engine：pending / active focus；SwiftTerm wrapper、mock stream、`SSHSessionDriver`、`SessionRecorder` 是下一階段主線。

## 共用服務草案

- `AuthStore` / `FirebaseAuthService`：Google 登入、Firebase Auth state、Firebase `uid`、sign out。
- `SyncUnlockStore`：同步選擇、同步主密碼解鎖、root navigation state。
- `SyncEncryptionService`：PBKDF2-HMAC-SHA256 key derivation、AES.GCM seal/open、Base64 encode/decode。
- `FirestoreSyncRepository`：讀寫 `users/{uid}/syncData/latest` 加密同步 blob。
- `SyncPayloadExporter` / `SyncPayloadImporter`：在 SwiftData / Keychain 與 JSON sync payload 之間轉換。
- `VaultRepository`：CRUD vaults、hosts、keychain metadata，secret body 以 Keychain reference 串接。
- `HostRepository`：管理 vault 內的 SSH host profiles，僅保存非機密連線 metadata。
- `SecureSecretStore`：封裝 Keychain add-or-update、read、delete 與錯誤處理。
- `SSHSessionDriver`：SSH backend protocol，v1 以 Citadel adapter 為第一候選並隔離 UI 與實作細節。
- `TerminalSessionManager`：維護多個 terminal sessions、active session count、connection state、目前輸入與保留 log。
- `SessionRecorder`：維護最近 command、output ring buffer、目前 input line 與 host profile snapshot，作為 AI context 來源。
- `AIAnalysisService`：根據 redacted session context 與使用者設定的 provider API key 產生診斷與建議。
- `LLMProvider`：錄影片版本先固定 primary provider，保留 OpenAI / Anthropic / Gemini / Custom adapter seam，並將 provider-native tool call 轉成 app 內部模型。
- `SettingsStore`：主題、terminal font size、預設 AI provider 等偏好。

## 安全原則

- 不把 password、private key、API key、OAuth token 寫入 `UserDefaults`、SwiftData、source code、log 或 plist。
- SwiftData 只保存可安全顯示的 metadata 與 Keychain item identifier。
- 同步主密碼不傳送到 Firebase；Firestore 只保存加密 blob、salt、kdf metadata、schema version、lastUpdated。
- 不直接使用人類密碼當 AES key；使用 PBKDF2-HMAC-SHA256 派生 256-bit key 後再用 AES.GCM 加解密。
- Keychain 寫入採 add-or-update，不以 delete-then-add 作為一般更新流程。
- AI 建議指令只顯示給使用者確認，不在本階段自動執行；LLM tool call 必須轉為 `CommandProposal`，並由 UI 的 Run / Edit 審核流程處理。

## 後續細節待補

- Vault-centric SwiftData model 的欄位、關聯與 migration 策略。
- `SyncPayload` schema v1、Firestore Security Rules 與同步衝突策略。
- Terminal integration implementation details：SwiftTerm wrapper、output batching、resize、keyboard accessory、SessionRecorder hook。
- Citadel adapter implementation details：password / key auth、PTY shell、host key trust、disconnect / reconnect。
- LLM provider request / response shape、錯誤處理與 token 成本控制。
- Demo data、simulator 錄影片腳本與測試帳號策略。

## 參考資料

- Apple App Review Guidelines, 4.8 Login Services: https://developer.apple.com/app-store/review/guidelines/
- Apple Enable App Capabilities / Sign in with Apple: https://developer.apple.com/help/account/identifiers/enable-app-capabilities
- Firebase Auth Google Sign-In: https://firebase.google.com/docs/auth/ios/google-signin
- Firestore realtime listeners: https://firebase.google.com/docs/firestore/query-data/listen
- Firestore offline persistence: https://firebase.google.com/docs/firestore/manage-data/enable-offline
- Google Sign-In for iOS Get Started: https://developers.google.com/identity/sign-in/ios/start-integrating
