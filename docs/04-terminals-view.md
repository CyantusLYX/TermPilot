# Terminals View 規劃

## 目標

Terminals View 是底部 tab 的第二個入口，用於切換與管理多個正在連線中的 SSH sessions，類似瀏覽器分頁或 Termius 的 active sessions 管理。它不負責建立 host profile；建立入口在 Vaults -> Hosts。

Terminal engine 目前是主要開發戰場：先完成 SwiftTerm + mock byte stream 的 simulator 可錄路徑，再接 `CitadelSSHSessionDriver` 與 `SessionRecorder`。

## 使用者流程

1. 使用者從 Vaults 的 Host 啟動 SSH 連線。
2. `TerminalSessionManager` 建立 session record，並讓 Terminals tab badge 增加。
3. 使用者進入 Terminals tab，看到目前 active、connecting、disconnected-but-kept-log 的 sessions。
4. 點擊 session row 後進入 Terminal & AI Assistant View。
5. 使用者可關閉 session、重新連線、或保留 log 稍後查看。

## 主要功能

- 顯示 active sessions list。
- 顯示每個 session 的 host alias、connection state、startedAt、lastActivityAt。
- 點擊 session 進入 Terminal View。
- 支援 close session、reconnect、clear retained log。
- 顯示 empty state：目前沒有活躍終端機。
- Tab badge 顯示 active 或 connecting sessions 數量。
- 支援批次清除 retained logs 與關閉所有 visible sessions。

## 技術選型與邊界

### Terminal Emulator: SwiftTerm Selected

- SwiftTerm 是 v1 已選定的唯一 terminal renderer。
- Raw terminal 以 `UIViewRepresentable` 包裝 SwiftTerm 的 `TerminalView`，讓 SwiftUI 只負責畫面組合與狀態呈現。
- Terminal View 外層使用 SwiftUI `ZStack` 疊加連線狀態、Chat Mode 入口、toolbar 與 suggestion UI；v1 不做游標級 Ghost Text overlay。
- 禁止自製 ANSI parser；ANSI rendering、cursor、selection 與 scrollback 行為交由 SwiftTerm 處理。
- App 需要的 retained log / AI context 只能從 SSH/session event pipeline 複製必要資料，不直接讀取或依賴 SwiftTerm 內部 buffer 結構。

### SSH Client: Citadel First Implementation

- `CitadelSSHSessionDriver` 是 v1 第一實作目標，透過 `SSHSessionDriver` protocol 隔離 UI 與 Citadel 型別。
- Integration Milestone 順序：SwiftTerm + mock byte stream -> Citadel password auth -> key auth -> PTY shell -> resize -> 大量輸出 -> disconnect / reconnect。
- `apple/swift-nio-ssh` 是 lower-level building blocks，不是 v1 primary path；只有需要自寫低階 driver 時才考慮。
- UI 層、`TerminalSessionManager` 與 Terminal View 只依賴 `SSHSessionDriver` protocol，不直接依賴 Citadel。
- `MockSSHDriver` 僅是 development fixture driver，用於錄 UI、跑 snapshot、測 AI overlay，不是正式 runtime path。
- `SSHSessionDriver` 至少需要支援 connect、authenticate、open PTY shell、read stream、send input、resize PTY、disconnect 與 connection state events。

### Security: Apple Keychain + Security Framework

- Credentials、private key metadata、host key fingerprint 與其他 SSH trust metadata 由 Apple Keychain / Security framework 管理。
- `HostKeyTrustStore` 集中封裝 host key fingerprint 保存與驗證；v1 可採 TOFU 或 demo-only accept policy，但不可散落在 SSH adapter。
- SwiftData 只保存可顯示 metadata 與 Keychain reference，不保存 password、private key body、passphrase 或 raw secret。
- MVP 不引入額外安全套件；Keychain OSStatus、SecItem query 與 host key fingerprint 驗證由 app 內部封裝。

### AI Context: Lightweight Session Recorder

- 自建輕量 `SessionRecorder`，負責記錄最近 command、最近 output ring buffer、目前 input line 與 host profile snapshot。
- `SessionRecorder` 是 AI context 的來源，不把 AI context 綁死在 SwiftTerm 或其他 renderer internals。
- Recorder 只保存有限上下文，提供 redaction 後的 snapshot 給 `AIAnalysisService` / `AIChatService`，不把完整 scrollback 直接送入 LLM。
- Recorder 隨 session lifecycle 建立與銷毀；reconnect 時沿用同一個 sessionID 與 context buffer，但不得保留已關閉 session 的敏感資料超過 retained log policy。

## Terminal Data Flow

- Remote output：`SSHSessionDriver.readStream` -> `TerminalSessionStore.appendRemoteData(_:)` -> `rawByteRingBuffer` -> batched MainActor flush -> `SwiftTerm.TerminalView`。
- Remote output 同時進入 `plainTextLineRingBuffer` 的 best-effort text projection，用於 session row retained log summary 與 AI context；此 buffer 不參與 terminal rendering。
- Local input：SwiftTerm input delegate -> `TerminalSessionStore.handleLocalInput(_:)` -> `SSHSessionDriver.send(_:)`。
- Local input 同時交給 `SessionRecorder.observeLocalInput(_:)`，用輸入側事件記錄 current input line 與 command history。
- Resize：`SwiftTermTerminalViewRepresentable` 依 view bounds / font metrics 計算 columns、rows，尺寸變更後 debounce 100-200ms，再呼叫 `SSHSessionDriver.resize(columns:rows:)`。
- Connection state events：`SSHSessionDriver` -> `TerminalSessionManager` -> session row、badge、Terminal header。

## Buffer 策略

- `rawByteRingBuffer` 保存有限 raw SSH bytes，用於 terminal replay、debug 與 reconnect 後的本地 context，不用於 AI prompt。
- `plainTextLineRingBuffer` 保存有限文字行，用於 retained log list、TL;DR 與 Chat Mode context。
- `TerminalSessionManager.retainedLogLineLimit = 500` 只套用於 `plainTextLineRingBuffer`；raw bytes 另以 byte count 限制。
- Raw output 可能包含 ANSI escape、cursor move、clear screen；因此 retained log summary 不等同 terminal 畫面真實狀態。
- 清除 retained logs 時必須清除 plain text retained summary；是否清除 raw bytes 由 debug policy 決定，v1 建議一起清除。

## SessionRecorder Command Detection

- v1 只從使用者輸入側記錄 command，不從 terminal output 猜 prompt 或 command。
- Recorder 維護 `currentInputLine`；收到 Enter 時提交一筆 command。
- Backspace / Delete 需更新 `currentInputLine`。
- Ctrl-C 清空或標記目前 input line 為 interrupted。
- Ctrl-D 記錄 EOF intent，不把它當一般 shell command。
- Paste multi-line 時，每個 newline 都可提交一筆 command；最後未結束行保留為 current input line。
- AI context 只使用 recorder snapshot 經 `RedactionService.redact(snapshot:)` 後的結果。

## Output Batching 與效能

- SSH read loop 收到 bytes 後先進 `TerminalSessionStore` buffer，不直接每個 packet 觸發 SwiftUI / UIKit update。
- UI flush 在 MainActor 批次執行，可用短 interval 或 frame-coalescing 策略。
- 大量輸出時優先保 terminal 可互動與 UI 不卡頓；session row summary 可延遲更新。
- `TerminalSessionManager` 發布 list state 時只更新必要欄位，例如 state、lastActivityAt、buffer summary，避免 terminal output 每包資料都重算整個 list。

## SwiftUI 實作方向

- Terminals tab 使用獨立 `NavigationStack(path: $router.terminalsPath)`。
- `TerminalsView` 從 `TerminalSessionManager.sessions` 讀取 session list。
- route 使用 `TerminalsRoute.session(sessionID:)`。
- row 要可整列點擊，並顯示狀態色點或 SF Symbol。
- Terminal View push 後可使用 `.toolbar(.hidden, for: .tabBar)` 提供全螢幕感。
- close / reconnect 可放在 swipe actions 或 context menu。
- v1 已在 row swipe actions 提供 close、reconnect、clear log；toolbar menu 提供 clear retained logs 與 close all。
- v1 session list 預設依 `lastActivityAt` descending 排序，並可透過 toolbar menu 切換為建立時間、host name 或 state 排序；排序選擇以 `@AppStorage` 保存。
- session list 更新要由 `TerminalSessionManager` 發布，避免每個 Terminal View 自己管理全域狀態。

## 資料與服務

- `TerminalSession`：記憶體優先的 session model，保存 sessionID、hostID、vaultID、alias、state、startedAt、lastActivityAt、buffer summary。
- `TerminalSessionManager`：建立、查詢、切換、關閉、重新連線 sessions。
- `TerminalSessionStore`：單一 Terminal View 的 renderer state reference、input state、raw byte ring buffer、plain text line ring buffer、output batching queue。
- `SwiftTermTerminalViewRepresentable`：SwiftTerm wrapper，負責將 renderer 嵌入 SwiftUI。
- `SSHSessionDriver`：SSH backend protocol，隔離 UI / session lifecycle 與 Citadel 實作細節。
- `CitadelSSHSessionDriver`：Citadel adapter，v1 第一實作目標。
- `HostKeyTrustStore`：集中保存與驗證 host key fingerprint。
- `SessionRecorder`：維護最近 command、output ring buffer、目前 input line 與 host profile snapshot，提供 AI context snapshot。
- `AIAnalysisService`：Terminal View 的 AI 分析，不由 Terminals list 直接呼叫。

## Session 狀態

- UI public state 保持簡單：`connecting`、`connected`、`disconnected`、`failed`、`closed`。
- 內部 state 可更細：`authenticating`、`openingPTY`、`reconnecting`、`suspended`。
- `authenticating` 與 `openingPTY` 對 UI 可映射為 `connecting`。
- `reconnecting` 對 UI 可顯示 reconnecting badge，但 active badge 仍可視為 connecting。
- `suspended` 用於 iOS background grace period 內部狀態，回前景後再轉為 reconnecting / disconnected。

## 邊界決策

- Terminals tab 不新增或編輯 hosts；所有 host 設定都在 Vaults Flow。
- Terminal session 可以引用 HostProfile，但 session lifecycle 不應修改 HostProfile metadata，除了更新 `lastConnectedAt` / `lastActivityAt` 這類統計欄位。
- 若 HostProfile 被刪除，該 hostID 對應的 sessions 必須被標記為 `closed`，避免使用者從 Terminals tab 回到已不存在的 host profile。
- retained log v1 先保留在記憶體；若要跨 app restart 保存 log，後續再規劃 local file / SwiftData external storage。
- active session badge 不計入 `closed` sessions；是否計入 `disconnected` 需後續 UX 決定，v1 建議只計 `connecting` + `connected`。

## 測試情境

- 從 Vaults 啟動 host 後，Terminals list 出現新 session。
- SwiftTerm wrapper 可顯示 mock ANSI output，且不需要自製 ANSI parser。
- `SSHSessionDriver.readStream` bytes 會經 `TerminalSessionStore.appendRemoteData(_:)` 批次寫入 SwiftTerm。
- SwiftTerm input delegate 產生的 bytes 會送到 `SSHSessionDriver.send(_:)`。
- Resize debounce 後會呼叫 `SSHSessionDriver.resize(columns:rows:)`，且 columns / rows 來自 bounds / font metrics。
- 大量輸出不會每個 packet 都觸發 UI update。
- `SessionRecorder` 從輸入側記錄 command，並處理 Backspace、Ctrl-C、Ctrl-D、paste multi-line。
- clear retained logs 後，visible sessions 保留但 plain text retained summary 清空。
- append retained log 超過 500 行時，只保留最新 500 行 plain text summary。
- 切換 tab 不會清空 terminal buffer。
- 切換 session row 排序時，只改變 list 呈現順序，不改變 session lifecycle。
- 刪除 Host profile 後，該 Host 的 visible sessions 從 Terminals list 移除，其他 Host sessions 不受影響。

## 後續細節待補

### P2 背景連線維持策略與 iOS Background 限制

- iOS 系統會在 App 退至背景一段時間後凍結一般網路活動；SSH 這類長時間互動式 TCP socket 不能假設可在背景永久維持。
- v1 simulator 錄影優先不依賴背景長時間連線；背景策略放在 terminal usable path 完成後處理。
- App 進入背景時，由 root shell 監聽 `scenePhase == .background`，通知 `TerminalSessionManager` 進入 background grace period。
- `TerminalSessionManager` 可透過 `UIApplication.shared.beginBackgroundTask` 爭取短暫執行時間，用於 flush buffers、停止 read/write loop、標記 session 需要 reconnect。
- background task 必須保存 task identifier，並在 work 完成或 expiration handler 觸發時呼叫 `endBackgroundTask`，避免資源洩漏。

### P2 前景喚醒與 Auto-reconnect

- App 回到前景 (`scenePhase == .active`) 時，`TerminalSessionManager` 檢查所有 `connecting` / `connected` / `disconnected` sessions 的實際 socket 健康狀態。
- 若 SSH stream 已失效，`TerminalSessionManager` 透過 `SSHSessionDriver.reconnect(session:)` 重新建立 SSH 通道。
- 重連成功後，新的 SSH stream 必須接回同一個 `TerminalSessionStore`，保留既有 buffer、chat timeline、Ring Buffer summary 與 sessionID。
- 若使用者已手動 `Close` session，前景喚醒時不得自動重連該 session。

### 後續實作注意事項

- `SSHSessionDriver` 需要提供 health check / reconnect API，例如 `isConnectionAlive(sessionID:)`、`reconnect(session:)`。
- `TerminalSessionManager` 需要避免多個 scenePhase event 重複觸發同一 session 的 reconnect，可用 per-session reconnect task registry 去重。
- 背景任務只用於短暫收尾，不應用來實作常駐 terminal daemon。
