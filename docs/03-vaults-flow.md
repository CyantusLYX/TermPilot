# Vaults Navigation Flow 規劃

## 目標

Vaults Flow 是 TermPilot 的主要工作入口，實作類似 Termius 的 Vault-centric 架構。使用者不再從底部 tab 分別進入 hosts 與 credentials，而是先進入某個 Vault，再在該 Vault 內管理 Hosts、Keychain 與未來擴充的 Snippets。

## 使用者流程

1. 使用者進入 Vaults tab。
2. v1 只有 `Personal Vault` 時，Vaults tab root 可直接顯示 dashboard；未來多 Vault 時再顯示 All Vaults 列表。
3. 在 Vault Dashboard 中，使用者可進入 Hosts、Keychain、Snippets。
4. 初次使用時，TipKit intro guide 先引導使用者到 Keychain 新增 login method（password 或 SSH key），再引導新增 Host。
5. 使用者在 Keychain 中新增、編輯、刪除 passwords、SSH keys 與 identities。
6. 使用者在 Hosts 中新增、編輯、刪除 SSH host profiles，並將 Host 綁定到相容的 Keychain item。
7. 使用者點擊 Host 後，App 依 Host 綁定的 Keychain item 建立 SSH session。
8. 建立 session 成功後，`TerminalSessionManager` 記錄 session，並切換或 push 到 Terminal 畫面。

## 導覽層級

### Root: All Vaults

- 顯示 `Personal Vault`、`Work Vault` 等 vaults。
- v1 可以只建立 `Personal Vault`；如果只有一個 vault，建議讓 Vaults tab root 直接呈現 Vault Dashboard，不透過 navigation path 自動 push，避免 pop-to-root 邏輯複雜化。
- 未來多 vault 支援同步、匯出、刪除與重新命名。

### Level 1: Vault Dashboard

- 顯示目前 Vault 名稱與摘要，例如 hosts 數量、keychain items 數量、最近使用 host。
- Dashboard summary v1 使用簡單 computed fetch / repository query 即可，不為錄影版本新增快取層。
- 提供三個主要入口：
  - Hosts：SSH server profiles。
  - Keychain：passwords、SSH keys、identities。
  - Snippets：常用指令片段，v1 支援新增、編輯、刪除與 encrypted sync。
- First-use intro guide 使用 state-gated TipKit tips：沒有 Keychain item 時，`AddKeychainLoginMethodTip` 錨在 Keychain 入口；已有至少一個 Keychain item 且尚無 Host 時，`AddHostProfileTip` 錨在 Hosts 入口。

### Level 2: Hosts

- Host list 顯示 alias、host、port、username / identity summary、最近連線時間。
- Host detail 顯示連線設定與啟動連線按鈕。
- Host form 欄位包含 alias、host、port、username、auth method、linked keychain item、optional notes。
- v1 form 已加入基本欄位驗證、同 vault 內重複名稱檢查，以及依 auth method 篩選可綁定的 keychain item；secret body 不會被讀出或顯示。
- v1 form 會要求 Host 必須選擇一個與 auth method 相容的 Keychain item；若舊資料或同步資料造成 Host 缺少相容 item，Host detail 的 Connect 按鈕也會被停用並顯示提示。
- 點擊 Connect 後，由 `TerminalSessionManager.start(hostID:)` 建立 session。

### Host Auth Method Compatibility

- `password` auth method 只能綁定 `password` keychain item。
- `sshKey` auth method 只能綁定 `sshKey` keychain item。
- `identity` auth method 只能綁定 `identity` keychain item；identity 是 credential wrapper，可包 password 或 sshKey，但 Host form 不直接混搭多個 item。
- 不支援的組合 validation fail，Host 不可儲存或連線。

### Level 2: Keychain

- Keychain list 以 section 顯示 Passwords、SSH Keys、Identities。
- Password item 保存 username 與 password secret reference。
- SSH Key item 保存 public fingerprint、private key secret reference、optional passphrase reference。
- Identity 可作為 host auth profile，綁定 password 或 SSH key。
- row 只顯示 metadata，不顯示 password、private key 或 passphrase。
- v1 編輯 Keychain item 時，若已有 Host 連結該 item，Type 欄位會被鎖定，避免 Host auth method 與 Keychain kind 失配。
- 編輯 secret sheet 中，空白欄位代表保留原 secret；`Clear` 按鈕代表明確刪除 secret；輸入新值後儲存代表 overwrite Keychain。

### Level 2: Snippets

- v1 用於保存常用 shell commands，例如 deploy、tail logs、restart service。
- Snippet form 欄位包含 title、command、optional notes。
- Snippet metadata 與 command 文字可進 SwiftData；local SwiftData snippet command 是 plaintext metadata。同步到雲端前必須進 AES.GCM encrypted blob。
- Snippet 不應自動執行，需由使用者在 Terminal 內確認或貼上。

## SwiftUI 實作方向

- Vaults tab 內使用獨立 `NavigationStack(path: $router.vaultsPath)`。
- route 使用 `VaultsRoute` enum：
  - `vaultDashboard(vaultID:)`
  - `hosts(vaultID:)`
  - `hostDetail(hostID:)`
  - `hostEditor(hostID:)`
  - `keychain(vaultID:)`
  - `keychainItem(id:)`
  - `keychainEditor(id:)`
  - `snippets(vaultID:)`
- v1 預設建立 `Personal Vault`，Vaults tab root 可直接呈現其 dashboard；不要為單 Vault 場景自動 push path。
- 新增 / 編輯可使用 `.sheet(item:)` 或 push form；v1 優先用 sheet，避免深層 navigation 過長。
- Host connect action 不直接持有 SSH secret，而是透過 linked keychain item 交給 `TerminalSessionManager` / `SSHSessionDriver`。
- 成功建立 session 後，可將 `TabRouter.selectedTab = .terminals` 並 append `TerminalsRoute.session(sessionID:)`。
- v1 已在 All Vaults、Hosts、Keychain、Snippets 列表加入 `.searchable`；搜尋比對名稱、host、username、auth method、fingerprint、command 與 notes 等可見 metadata，不讀取 Keychain secret body。
- v1 已加入排序 menu，並以 `@AppStorage` 保存使用者選擇：Vaults 可依名稱 / 最近更新 / 建立時間排序；Hosts 可依 alias / host / 最近連線 / 最近更新排序；Keychain 與 Snippets 可依名稱或時間排序。
- v1 已實作 Vault / Host / Keychain / Snippet 的 local validation；進一步的 SSH 連線前檢查留給 `SSHSessionDriver` adapter。
- Vault first-use tips 使用 `VaultIntroTipState` 依目前 vault 的 keychain / host 數量回傳可顯示的 tip；Dashboard 的 Keychain / Hosts 入口、Keychain list 的 Add button、Hosts list 的 Add button 都使用同一組 gating，避免使用者進入列表後失去引導。
- 成功新增 Keychain item 後 invalidate `AddKeychainLoginMethodTip`；成功新增 Host 後 invalidate `AddHostProfileTip`。取消 sheet 不會完成 tip。

## 資料模型與服務

- `VaultProfile`：SwiftData model，保存 vault id、name、createdAt、updatedAt。
- `HostProfile`：SwiftData model，保存 vaultID、alias、host、port、username、auth method、linked keychain item id、notes、lastConnectedAt。
- `KeychainItemProfile`：SwiftData model，保存 vaultID、name、type、username、fingerprint、secret references。
- `SnippetProfile`：SwiftData model，保存 vaultID、title、command、notes、createdAt、updatedAt。
- `VaultRepository`：查詢與管理 vault、dashboard summary。
- `HostRepository`：CRUD host profiles；刪除 Host 前需協調 `TerminalSessionManager.closeSessions(forHostID:)`。
- `VaultKeychainRepository`：CRUD keychain metadata，透過 `SecureSecretStore` 管理 secret body。
- `SecureSecretStore`：Keychain add-or-update、read、delete。
- `TerminalSessionManager`：依 host profile 建立 session，管理 session lifecycle。

## 安全原則

- Vault / Host / Keychain metadata 可進 SwiftData；password、private key、passphrase 不可進 SwiftData、`UserDefaults`、log 或 source code。
- Snippet command 在本機 SwiftData 中是 plaintext metadata；安全保證是雲端同步前進 AES.GCM encrypted blob，不代表本地也 encrypted。
- Firestore sync 只上傳 AES.GCM encrypted blob，不攤平保存 vault、host 或 keychain 明文欄位。
- 匯入同步 payload 時，metadata 寫 SwiftData，secret body 寫 Keychain；任何一邊失敗都不能留下半套資料。
- 刪除 Keychain item 前需檢查是否仍被 HostProfile 引用；已被 Host 使用的 Keychain item 不可改成另一種 type，除非先解除 Host 連結。
- 同步匯入前必須驗證 Vault-centric 關聯完整性：Host / Keychain / Snippet 不能引用不存在的 Vault，Host 不能引用不存在或跨 Vault 的 Keychain item，且 Host auth method 必須與 linked Keychain item kind 相容。
- 關聯驗證失敗時不得覆蓋既有本機 Vaults / Hosts / Keychain / Snippets，也不得把錯誤 payload 的 secret 寫入 Keychain。

## 測試情境

- 只有 Personal Vault 時，進入 Vaults tab 後直接看到 Vault Dashboard。
- 初次使用且沒有 Keychain item 時，Vault Dashboard 先提示新增 login method；新增 Keychain item 後才提示新增 Host。
- 新增 Host 後，在 Hosts list 出現 alias、host、port。
- 新增 Password 或 SSH Key 後，可在 Host form 中選取作為 auth method。
- Host form 送出前會阻擋空白 alias、無效 host、超出範圍的 port、缺少 username、缺少對應 keychain item 與同 vault 內重複 alias。
- 刪除 Host profile 時，`HostRepository.delete()` 成功前呼叫 `TerminalSessionManager.closeSessions(forHostID:)`；若 close 失敗，刪除流程需停住或顯示確認，避免 Terminals tab 留下已不存在 Host 的入口。
- 點擊 Host Connect 後，建立 terminal session，Terminals tab badge 增加。
- 刪除被 Host 引用的 Keychain item 時，顯示阻擋或確認流程；編輯被 Host 引用的 Keychain item 時，Type picker 需被鎖定。
- 編輯 secret sheet 時，空白欄位會保留舊 secret；只有 `Clear` 會刪除，輸入新值才會 overwrite。
- 新增 / 編輯 / 刪除 Snippet 後，Snippets list 立即更新，並觸發 debounce encrypted sync。
- 同步解密匯入後，Vault Dashboard、Hosts、Keychain、Snippets 都能重建。
- 同步 payload 若有重複 id、missing vault reference、missing keychain reference 或 auth method mismatch，匯入失敗且原本本機資料仍保留。
- 在 Hosts / Keychain / Snippets 搜尋時，只顯示符合 visible metadata 的項目；清空搜尋後完整列表恢復。
- 切換 Vaults / Hosts / Keychain / Snippets 的排序選項時，列表順序更新且不修改 SwiftData schema 或 sync payload。

## 後續細節待補

- 未來多 Vault 時，All Vaults root 與 Personal Vault Dashboard 的切換策略。
- Identity wrapper 到實際 `SSHSessionDriver` auth request 的 mapping 細節。
