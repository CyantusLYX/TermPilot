# Login View 規劃

## 目標

Login View 是 TermPilot 的入口，負責 Firebase Authentication 登入與加密同步解鎖。v1 UI 只顯示 Google 登入，登入成功後由 Firebase Auth 提供穩定的使用者 `uid`，作為 Firestore 同步資料的 owner key。

本階段以 simulator 錄影展示為目標，不處理 App Store 上架合規。Apple 登入只保留為未來可擴充 provider；若未來要送 App Store review，再重新評估 Apple Guideline 4.8。

## 核心服務組合

- Firebase Authentication：處理 Google 登入後的 Firebase sign-in，取得 `FirebaseAuth.User.uid`。
- Cloud Firestore：儲存每位使用者的加密同步 blob，並提供 realtime sync 與離線支援。
- Apple CryptoKit：使用 `AES.GCM.seal/open` 加密與解密同步資料。
- CommonCrypto：使用 PBKDF2-HMAC-SHA256 從同步主密碼派生 256-bit AES key。
- Keychain：保存 Firebase/Google credential 相關資料，以及所有 SSH / Vault secrets。v1 預設不長期保存同步主密碼派生出的 AES key material。

## Firebase 與 Google 登入基礎設定

### SPM Dependencies

- Firebase Apple SDK repository：`https://github.com/firebase/firebase-ios-sdk`
- Firebase package products 只勾選：
  - `FirebaseAuth`
  - `FirebaseFirestore`
- Google Sign-In SDK repository：`https://github.com/google/GoogleSignIn-iOS`
- Google package products：
  - `GoogleSignIn`
  - `GoogleSignInSwift`：若使用官方 SwiftUI Google button 才加入。

不要加入 FirebaseAnalytics、FirebaseStorage、FirebaseDatabase 或其他暫時不需要的 Firebase products，避免錄影版本範圍膨脹。

### 初始化

- v1 使用 SwiftUI app lifecycle，不新增傳統 `AppDelegate` / `SceneDelegate` 檔案。
- 在 `TermPilotApp.init()` 呼叫 `FirebaseApp.configure()`；若後續真的需要 delegate-based Firebase 功能，再改用 `@UIApplicationDelegateAdaptor`。
- `TermPilotApp` 的 `WindowGroup` 要加 `.onOpenURL`，將 Google redirect URL 交給 `GIDSignIn.sharedInstance.handle(url)`。
- `GoogleService-Info.plist` 需加入 app target。此檔案包含 Firebase 專案識別資訊，不是使用者 secret，但仍不應放入公開教學截圖中的完整專案資訊。

### Info.plist 設定

- 必須設定 `GIDClientID`，值為 Google Cloud Console 產生的 iOS OAuth Client ID。
- 必須設定 `CFBundleURLTypes`，加入 reversed client ID，否則 Google 登入完成後無法跳轉回 App。
- 範例：

```xml
<key>GIDClientID</key>
<string>YOUR_IOS_CLIENT_ID</string>
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>YOUR_DOT_REVERSED_IOS_CLIENT_ID</string>
    </array>
  </dict>
</array>
```

## 使用者流程

1. App 啟動後，`AuthStore` 監聽 Firebase Auth state。
2. 若沒有 Firebase user，顯示 Google 登入按鈕。
3. 使用者完成 Google OAuth 流程後，App 使用 Google ID token / access token 建立 Firebase credential，呼叫 Firebase Auth sign-in。
4. Firebase sign-in 成功後，App 建立 `CurrentUser`，保存 `uid`、display name、email、avatar URL 等非機密 profile metadata。
5. App 讀取 Firestore `users/{uid}/syncData/latest`。
6. 若沒有 sync blob，使用者可以先進入 App，或建立同步主密碼並啟用同步。
7. 若有 sync blob 但本機尚未解鎖，Login View 顯示同步主密碼輸入畫面。
8. 使用者輸入正確同步主密碼後，App 派生 AES key，解密 Firestore blob，將 payload 匯入 SwiftData 與 Keychain，然後進入 Main Tab View。
9. 若主密碼錯誤或解密失敗，停留在解鎖畫面，不覆蓋本機資料。
10. 從 Settings View 登出時，由 `SignOutCoordinator` 先停止 terminal sessions、清除本機資料與 secrets，再執行 Firebase / Google signOut，最後回到 Login View。

## 主要功能

- Google-only 登入 UI。
- Firebase Auth state restore 與 sign-out。
- 登入後根據 Firebase `uid` 查詢 Firestore sync blob。
- 首次啟用同步時建立同步主密碼。
- 新設備或未解鎖設備輸入同步主密碼解密雲端資料。
- 顯示登入、讀取 Firestore、解密、匯入、失敗等狀態。
- 保留 Apple provider 擴充點，但 v1 不顯示 Apple 登入按鈕。

## SwiftUI 實作方向

- Root shell 根據 `SyncUnlockStore.state` 切換畫面：`signedOut`、`signingIn`、`signedInNeedsSyncChoice`、`signedInNeedsUnlock`、`unlocked`、`failed`。
- 未登入時顯示品牌區塊與 Google 登入按鈕。
- 需要同步選擇時顯示「先進入 App」與「啟用同步」兩個動作。
- 需要解鎖時顯示 secure field，輸入同步主密碼。
- `TermPilotApp` 初始化 Firebase，並在 `WindowGroup` 上處理 Google Sign-In redirect URL。
- 登入成功但 Firestore 離線時，允許使用本機資料；恢復網路後再由 sync repository 處理同步。

## 資料與服務

- `CurrentUser`：保存 `uid`、`displayName`、`email`、`avatarURL` 等非機密 profile metadata。
- `FirebaseAuthService`：包裝 Google Sign-In、Firebase credential 建立、Firebase Auth sign-in / sign-out。
- `AuthStore`：維護 Firebase user、profile metadata、登入 loading / error state。
- `SyncUnlockStore`：管理同步選擇、主密碼輸入、解密狀態與 root navigation state。
- `SyncEncryptionService`：負責 PBKDF2 key derivation、AES.GCM seal/open、Base64 encode/decode。
- `FirestoreSyncRepository`：讀寫 `users/{uid}/syncData/latest`，並可加入 document listener 做 realtime sync。
- `SyncPayloadExporter`：把 SwiftData metadata 與 Keychain secrets 打包成 JSON `Data`。
- `SyncPayloadImporter`：將解密後的 JSON 還原到 SwiftData 與 Keychain。
- `SecureSecretStore`：封裝 Keychain add-or-update、read、delete 與 OSStatus handling。
- `SignOutCoordinator`：協調停止 terminal sessions、清除 SwiftData / Keychain、Firebase / Google signOut 與 root state 切換。

## Sign-out Coordinator

- Sign out 不直接由 `AuthStore` 單點完成，避免 auth state 與 local state 短暫不一致。
- 順序固定為：disable UI -> close terminal sessions / read loops -> clear retained logs / recorders -> wipe SwiftData metadata -> wipe TermPilot Keychain items -> Firebase / Google signOut -> set unauthenticated。
- 若 wipe SwiftData 或 Keychain 失敗，不可先切到 unauthenticated；需顯示錯誤並保留目前登入狀態，讓使用者可重試。
- 登出不刪除 Firestore `users/{uid}/syncData/latest` encrypted blob。

## Firestore 資料格式

Firestore document path 固定為：

```text
users/{uid}/syncData/latest
```

Document 只保存 ciphertext 與必要 metadata：

```json
{
  "encryptedBlob": "U2FsdGVkX1+x9...",
  "salt": "base64-random-salt",
  "kdf": "PBKDF2-HMAC-SHA256",
  "kdfIterations": 600000,
  "schemaVersion": 1,
  "lastUpdated": "2026-06-11T12:00:00Z"
}
```

`encryptedBlob` 解密後的 payload 才包含 Vaults、Hosts、Keychain items 與 Snippets。SyncPayload v1 格式固定如下：

```json
{
  "version": 1,
  "exportedAt": "2026-06-11T12:00:00Z",
  "vaults": [
    {
      "id": "UUID",
      "name": "Personal Vault",
      "createdAt": "2026-06-11T12:00:00Z",
      "updatedAt": "2026-06-11T12:00:00Z"
    }
  ],
  "hosts": [
    {
      "id": "UUID",
      "vaultID": "UUID",
      "alias": "My Server",
      "host": "192.168.1.1",
      "port": 22,
      "username": "root",
      "authMethod": "password",
      "linkedKeychainItemID": "UUID"
    }
  ],
  "keychainItems": [
    {
      "id": "UUID",
      "vaultID": "UUID",
      "name": "Root Password",
      "kind": "password",
      "username": "root",
      "secret": "真正的密碼或私鑰字串"
    }
  ],
  "snippets": [
    {
      "id": "UUID",
      "vaultID": "UUID",
      "title": "Tail syslog",
      "command": "tail -f /var/log/syslog",
      "notes": "常用 log 追蹤指令"
    }
  ]
}
```

Firestore top-level 不攤平保存 host、username、password、private key、API key 或 snippet command 等欄位。Vaults / Hosts / Keychain items / Snippets 的可同步內容必須先轉成 JSON，再用 AES.GCM 加密後才可上傳。`secret` 只允許短暫存在於記憶體中的 `SyncPayload`，匯入後要立即寫入 Keychain。

`SyncPayload` 解密後包含明文 secret，禁止 `print`、`debugDescription`、console log、request log 或測試 snapshot 輸出完整 payload。Exporter / importer tests 不得 snapshot 明文 password、private key 或 passphrase。

## Payload Schema 與遷移策略

- `SyncPayload.version` 是解密後第一個要檢查的欄位。
- v1 `vaults` 必填欄位：`id`、`name`、`createdAt`、`updatedAt`。
- v1 `hosts` 必填欄位：`id`、`vaultID`、`alias`、`host`、`port`、`username`、`authMethod`。
- v1 `keychainItems` 必填欄位：`id`、`vaultID`、`name`、`kind`、`username`、`secret`。
- v1 `snippets` 欄位：`id`、`vaultID`、`title`、`command`、`notes`、`createdAt`、`updatedAt`；為了相容舊 demo blob，缺少 `snippets` 時匯入器可視為空陣列。
- `kind` v1 先支援 `password`、`sshKey` 與 `identity`；其他值視為不支援，匯入時顯示錯誤並避免覆蓋本機資料。
- 匯入前必須先做完整性驗證：Vault / Host / Keychain / Snippet id 不可重複；Host / Keychain / Snippet 的 `vaultID` 必須存在；Host 若有 `linkedKeychainItemID`，該 Keychain item 必須存在、位於同一個 Vault，且 `authMethod` 與 `kind` 相容。
- 若 payload 缺少關聯、出現重複 id、Host port / name / command 等欄位不符合本機 validation 規則，匯入器必須在寫入 SwiftData 或 Keychain 前失敗，保留既有本機資料。
- 未來若推出 v2，例如新增 tags，`SyncPayloadImporter` 必須提供 v1 到目前 SwiftData model 的 migration / upgrade 邏輯。
- 遷移順序：decode envelope -> 檢查 `version` -> 轉成目前 app 的 domain import model -> 寫入 SwiftData metadata -> 寫入 Keychain secrets。
- 匯入過程需具備 transaction-like 行為；若 Keychain secret 寫入失敗，不應只留下不完整的 SwiftData metadata，也必須刪除本次匯入已經成功寫入的新 Keychain accounts，避免留下孤兒 secret。
- SwiftData metadata 置換需包在單一 transaction 中；只有所有 Vault / Host / Keychain / Snippet metadata 都能建立時，才提交本機資料替換。
- 匯入成功後，需刪除舊 SwiftData `KeychainItemProfile` 曾引用、但新 payload 不再引用的本機 Keychain accounts，避免同步替換後殘留過期 secret。

## PBKDF2 迭代次數與效能

- CryptoKit 內建 HKDF 適合高熵 key material，不適合直接處理人類可記憶的低熵主密碼。
- 同步主密碼必須使用 CommonCrypto `CCKeyDerivationPBKDF` 實作 PBKDF2-HMAC-SHA256。
- `kdfIterations` v1 預設為 `600000`，對齊 OWASP Password Storage Cheat Sheet 對 PBKDF2-HMAC-SHA256 的建議。
- 首次設定同步主密碼時，使用 `SecRandomCopyBytes` 產生 32 bytes random salt，Base64 後明文存於 Firestore document 的 `salt` 欄位。
- KDF 目標耗時：實機 300ms 到 500ms。
- PBKDF2 必須放到 `Task.detached` 或 background queue 執行，UI 顯示 loading / progress，不可阻塞 MainActor。
- 測試環境可透過 debug flag 降低 iteration 以加速單元測試，但 release / demo data 不得混用低 iteration blob。
- 解鎖流程要以 document 中的 `kdf`、`kdfIterations`、`salt` 為準，讓未來可以提高 work factor 並支援舊 blob。

## 同步加密流程

1. 使用者建立同步主密碼。
2. App 使用 `SecRandomCopyBytes` 產生 32 bytes random salt，使用 PBKDF2-HMAC-SHA256 派生 256-bit key。
3. App 將 SwiftData 中的 Vaults / Hosts / Keychain metadata / Snippets 與 Keychain 中需同步的 Vault secrets 打包成 `SyncPayload` JSON。
4. App 使用 CryptoKit `AES.GCM.seal()` 加密 payload，取得 combined sealed box。
5. App 將 sealed box Base64 後寫入 Firestore `encryptedBlob`。
6. 新設備登入同一 Firebase 帳號後，下載 `encryptedBlob`，要求使用者輸入同步主密碼。
7. App 使用 Firestore document 的 salt / kdf metadata 派生 key，呼叫 `AES.GCM.open()` 解密。
8. 解密成功後匯入 SwiftData 與 Keychain；解密失敗時不修改本機資料。

## Firestore Sync Rules

- Firestore path 固定為 `users/{uid}/syncData/latest`。
- 只允許已登入使用者讀寫自己的同步文件。
- Security Rules 規劃：

```text
match /users/{uid}/syncData/latest {
  allow read, write: if request.auth != null && request.auth.uid == uid;
}
```

- v1 衝突策略採單一 blob + `lastUpdated`，多設備同時修改時以最後寫入為準。
- 更細緻的 per-record merge、版本向量或 conflict UI 留到後續版本。

## Firestore Listener 與防抖

- 本機資料不應在每次文字輸入時同步。
- Vaults / Hosts / Keychain repositories 在 form 儲存成功或 SwiftData save 成功後呼叫 `SyncManager.markDirty()`。
- `SyncManager` 使用 3 秒 debounce：3 秒內若有新修改，取消前一次排程。
- debounce 結束後才執行 export -> AES.GCM encrypt -> upload Firestore。
- 可用 Combine `.debounce(for: .seconds(3))`，或用 Swift Concurrency 保存一個 pending `Task` 並在新修改時 cancel，再 `try await Task.sleep(for: .seconds(3))`。
- 手動立即上傳、登出或清除雲端同步資料時，必須讓既有 pending debounce 失效；舊 snapshot 不可在稍後完成並覆蓋較新的 blob。
- Firestore `addSnapshotListener` 收到雲端變更時，比對 Firestore `lastUpdated` 與本機 `lastUploadedAt`。
- 若雲端較新：暫停本機 pending debounce，上鎖 `SyncManager` 的 upload path，下載 encrypted blob，背景解密並匯入本機。
- 雲端匯入造成的 SwiftData 寫入要標記 source = cloud，避免立刻觸發新的上傳回圈。
- v1 採 Last-Writer-Wins；若本機與雲端都有未同步修改，先以 `lastUpdated` 較新的 blob 為準，後續版本再加入 conflict UI。

## 安全與隱私

- 同步主密碼絕對不可傳送到 Firebase，也不可寫入 Firestore、SwiftData、`UserDefaults`、plist、source code 或 log。
- 不直接用人類密碼建立 `SymmetricKey`；必須使用 PBKDF2-HMAC-SHA256 與 random salt 派生 key。
- AES.GCM nonce 交由 CryptoKit 自動產生，不手動重用 nonce。
- v1 預設不長期保存派生後的 AES key material；解鎖後只保留在目前 process memory。
- 若未來要保存可重用 key material，只可存在 Keychain，並搭配 device passcode / biometric accessibility policy，且登出必刪。
- OAuth token、Vault password、SSH private key、LLM API key 不可明文寫入 Firestore、SwiftData 或 `UserDefaults`。
- LLM API keys 暫不跨設備同步，仍只存在本機 Keychain。
- 登出時由 `SignOutCoordinator` 先關閉 active terminal sessions 與 recorders，再清除 SwiftData vault metadata、TermPilot Keychain secrets，最後清除 Firebase Auth / Google session；雲端 encrypted blob 不因登出而刪除。

## 主密碼 UX

### 啟用同步

- 介面必須明確提示：「同步主密碼絕對無法復原，忘記後雲端同步資料將無法解密。」
- 使用者必須輸入「同步主密碼」與「再次確認同步主密碼」。
- 兩次輸入不一致時不執行 KDF，也不建立 Firestore document。
- 建立成功後，立即 export 本機 Vaults / Hosts / Keychain items，產生第一份 encrypted blob。

### 變更主密碼

- 若目前未解鎖，使用者必須先輸入舊主密碼並成功解密現有 blob。
- 若目前已解鎖，可略過舊密碼輸入，但仍需輸入新主密碼與確認。
- 流程：用舊 key 解密現有 payload -> 產生新 salt -> 用新密碼派生新 AES key -> 重新 AES.GCM 加密 payload -> 覆蓋 Firestore document -> 更新目前 process 的解鎖狀態；若未來啟用安全 key reuse，才更新 Keychain 中的可重用 key material。
- 任一步驟失敗時保留舊 blob 與舊本機 key，不得寫入半套狀態。

### 忘記主密碼

- 不提供「寄送重設信」或 Firebase 密碼重設流程，因為雲端沒有同步主密碼，也沒有解密 key。
- 解鎖失敗畫面提供橘紅色警告按鈕：「清除雲端同步資料」。
- 使用者確認後刪除 Firestore `users/{uid}/syncData/latest` document。
- 刪除後，使用者可在當前設備重新設定同步主密碼，App 以當前設備的本地資料為基準重新上傳新的 encrypted blob。
- 若當前設備也沒有可用本地資料，清除雲端同步資料後等同重新開始。

## 測試情境

- 首次 Google 登入，Firestore 沒有 sync blob，使用者可直接進入 App。
- 首次啟用同步，建立同步主密碼後成功上傳 encrypted blob。
- 新設備登入同一 Firebase UID，輸入正確同步主密碼後成功解密並匯入 SwiftData / Keychain。
- 輸入錯誤同步主密碼時停留在解鎖畫面，不覆蓋本機資料。
- 解密成功但 payload 關聯不完整時，匯入失敗並保留既有本機資料。
- Firestore 離線時可使用本機資料；恢復網路後同步 repository 再處理下載或上傳。
- 登出後重新啟動 App，不應保留可直接解密同步 blob 的記憶體狀態。
- 登出流程必須先 close terminal sessions / recorders 與 wipe local data，成功後才 Firebase / Google signOut。
- `SyncPayload` exporter / importer tests 不得把明文 secret 寫入 snapshot 或 log。
- PBKDF2 在 background task 執行，MainActor 不被 600000 iterations 阻塞。
- 3 秒 debounce 期間連續編輯多筆資料，只應上傳最後一次加密 blob。
- 收到較新的 Firestore snapshot 時，暫停本機上傳並匯入雲端版本。
- 忘記主密碼流程只能刪除雲端 blob 並重新建立，不能重設或取回舊資料。

## 後續細節待補

- Google OAuth Client ID / reversed client ID URL scheme 實際設定值。
- Firebase project ID 與 `GoogleService-Info.plist` 實際檔案。
- KDF 實機效能測試紀錄與是否需要 per-device iteration tuning。
- v2 schema migration 測試資料。
- Firestore listener 在 app background / foreground 切換時的生命週期。

## 參考資料

- Firebase Auth Google Sign-In: https://firebase.google.com/docs/auth/ios/google-signin
- Firebase Apple setup / SPM: https://firebase.google.com/docs/ios/setup
- Firestore realtime listeners: https://firebase.google.com/docs/firestore/query-data/listen
- Firestore offline persistence: https://firebase.google.com/docs/firestore/manage-data/enable-offline
- Google Sign-In for iOS Get Started: https://developers.google.com/identity/sign-in/ios/start-integrating
- OWASP Password Storage Cheat Sheet: https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html
