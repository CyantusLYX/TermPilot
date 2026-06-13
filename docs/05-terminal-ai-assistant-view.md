# 05 Terminal & AI Assistant View 規劃

## 目標

Terminal & AI Assistant View 是 TermPilot 的核心工作區。此畫面採用 Dual-Mode 架構，讓使用者可以在高效率排錯的 `Raw Mode` 與自然語言協作的 `Chat Mode` 之間切換。

本階段進入 Terminal implementation，優先順序為：SwiftTerm wrapper -> local / mock byte stream -> `SSHSessionDriver` -> `SessionRecorder` -> AI overlay。目標是讓 simulator 錄影片能展示可信的 terminal usable path，而不是停留在 placeholder。

Chat Mode 與 TL;DR 診斷的 LLM request schema、System Prompt、Tool Use / Function Calling 與 provider adapter 規格由 [LLM Integration & Tool Use](07-llm-integration-tool-use.md) 管理；本文件描述 Terminal UI/UX、renderer / SSH / recorder 串接與執行邊界。

## 使用者流程

1. 使用者從 Vaults 的 Host 啟動連線，或從 Terminals tab 點回既有 session。
2. App 進入 Terminal & AI Assistant View，預設顯示 `Raw Mode`。
3. `Raw Mode` 顯示 SwiftTerm renderer；SSH read loop 與 `SessionRecorder` 持續接收 input / output events。
4. 使用者可切換到 `Chat Mode`；SSH session 不暫停，SwiftTerm buffer 仍在背景更新，只是不顯示 raw terminal stream。
5. `Chat Mode` header 顯示 host alias、connection state、cwd guess 與 last command，避免使用者在斷線或錯誤 session 狀態下要求 AI 執行指令。
6. AI 產生的指令只會變成 `CommandProposal`；使用者必須點擊 `Run`、`Edit` 或 `Reject`，App 不會自動執行。
7. v1 `Run` 採 same interactive PTY：把 command 送入 terminal，不承諾精準 stdout / stderr / exit code / duration；若未來需要精準結果，再使用 separate exec channel。
8. `Run` 後 App 會在 transcript window 內收集 best-effort 輸出，作為 tool result 回傳給 LLM，由 LLM 自行決定是否繼續提出下一個 proposal 或給出結論；使用者不需要再手動追問執行結果。

## Dual-Mode 規劃

### 1. Raw Mode

- 核心體驗是全螢幕 SSH terminal，支援 ANSI colors、文字輸入、scrollback 與連線狀態顯示。
- Terminal rendering 由 SwiftTerm 負責；禁止自製 ANSI parser。
- iOS terminal 必須提供 keyboard accessory bar，至少包含 Tab、Esc、Ctrl-C、Ctrl-D、方向鍵、`/`、`-`、`|` 等常用鍵。
- Context-aware suggestion v1 先以 keyboard accessory suggestion chip 或 input bar suggestion 呈現；真正對齊游標位置的半透明 Ghost Text 列為 post-v1。
- 補全來源包含目前 shell / OS hint、當前輸入 prefix、歷史指令與後續可接入的 LLM suggestion。
- AI 需要的 Ring Buffer 由 `SessionRecorder` 從 SSH/session events 維護，不讀取 SwiftTerm renderer internals。
- TL;DR 診斷 v1 採手動觸發 + output heuristic：例如 terminal output 超過 100 行、出現常見錯誤關鍵字、或使用者手動點擊診斷按鈕。
- 互動式 PTY shell 不天然提供每個 command 的 exit code；若要可靠 exit code，後續再透過 shell hook 或 command wrapper 實作。
- AI 診斷只讀取 redacted snapshot，預設取 Head 20 + Tail 20 行，避免大量 log 與 secret 外洩。

### 2. Chat Mode

- 核心體驗是聊天介面；底層 SSH session 持續存在，SwiftTerm buffer 持續更新，但畫面不顯示 raw terminal stream。
- 使用者輸入自然語言需求，例如「幫我寫一個腳本備份 `/var/www` 到 S3」。
- `AIChatService` 根據 host context、shell / OS hint、有限 session context 與對話歷史產生回覆。
- AI 回覆若包含 shell 指令，必須透過 Tool Use 轉成 `CommandProposal`，並以審核卡片呈現。
- 每個 `CommandProposal` 有 `pending` / `approved` / `rejected` 三種狀態，pending 卡片提供 `Run`、`Edit`、`Reject`。
- `Run`：使用者明確核准後，`LLMExecutionBridge` 將 command 寫入同一個 interactive PTY；App 在固定 transcript window（v1 為 2.5 秒、最多 40 行）內收集 redacted retained log 增量作為 `executionTranscript`，寫回 proposal 與 execution timeline，並自動觸發 continuation request，讓 LLM 根據結果繼續或收斂出結論。
- `Edit`：把 command 帶回 Raw Mode 輸入框，讓使用者修改後再送出。
- `Reject`：標記 proposal 為 `rejected` 並把卡片折疊成單行 chip（可點擊重新展開）；單純拒絕不觸發 LLM round trip。
- Proposal 處於 pending 時，chat 輸入框切換為「revision 模式」：輸入文字會作為該 command 的修改需求，連同 rejected 狀態回傳給 LLM 產生修訂版 proposal；沒有 pending proposal 時輸入框回到一般提問狀態。
- v1 執行結果以 best-effort transcript window 呈現；不宣稱精準 stdout / stderr 分流或 exit code。

### Agentic 對話迴圈

- 對話不是死板的一問一答；LLM 透過 tool result 得知每個 proposal 的最終狀態（approved + transcript、rejected + user feedback、pending），自行決定要繼續提出下一步指令還是給出最終結論。
- Provider request 必須以原生 tool-call 結構序列化歷史：assistant message 帶 tool calls，每個 proposal 對應一則 tool result（OpenAI `tool` role message / Gemini `functionResponse` part），不得把執行結果攤平成 user message。
- System Prompt 明確告知模型：command 需使用者核准、核准後會收到 best-effort transcript、被拒絕時要根據 feedback 修訂、資訊足夠時直接給文字結論並停止提出指令。

## SwiftUI 實作方向

- 定義 `TerminalMode` 並由畫面本地 state 控制：

```swift
enum TerminalMode: String, CaseIterable, Identifiable {
    case raw
    case chat

    var id: String { rawValue }
}
```

- `TerminalView` 使用 `@State private var terminalMode: TerminalMode = .raw`。
- mode switch 使用 segmented `Picker`，放在 toolbar 或 terminal header。
- `RawTerminalView` 使用 `UIViewRepresentable` 包裝 SwiftTerm 的 `TerminalView`，外層以 SwiftUI `ZStack` 疊加連線狀態、Chat Mode 入口與 toolbar。
- v1 不做游標級 Ghost Text overlay，避免字寬、scroll offset、cursor position 與 UIKit view 疊合造成實作阻塞。
- `ChatTerminalView` 使用 `ScrollView` + `LazyVStack` 顯示 `AIChatMessage`，並用 `safeAreaInset(edge: .bottom)` 放置輸入列。
- `ChatTerminalView` header 固定顯示 host alias、connection state、cwd guess、last command。
- chat command 做成獨立 `CommandProposalCard`，明確呈現 command、預期效果、風險提示與依狀態變化的按鈕：pending 顯示 `Reject` / `Edit` / `Run`，approved 顯示 `Ran` badge 與 `Run Again`，rejected 折疊為單行 chip。
- chat 輸入列為雙模式元件：無 pending proposal 時是一般提問輸入框；有 pending proposal 時切換為 revision 模式，上方顯示待審 command、送出即拒絕該 proposal 並附上修改需求。
- TL;DR 診斷使用 bottom sheet 顯示 summary、diagnosis、suggested commands；建議指令仍走 edit / run 審核路徑，不直接執行。
- 點擊 AI 功能前先檢查目前 provider API key；若缺少 key，sheet 顯示「尚未設定 {Provider} API Key」，並透過 `TabRouter.openSettingsAPIKey(provider:)` 導向 Settings。

### 提示與 Intro Guide（TipKit）

- 功能提示一律使用 TipKit，不用 hardcoded chat seed message 或一次性 overlay；`Tips.configure()` 在 `TermPilotApp.init` 呼叫。
- Intro guide 使用 ordered `TipGroup` 依序顯示：
  1. `ModeSwitchTip`：popover 錨在 Raw/Chat segmented picker，介紹 dual-mode；使用者切換 mode 時 invalidate。
  2. `DiagnoseTip`：popover 錨在 toolbar 的 Diagnose 按鈕；點擊診斷時 invalidate。
- Chat Mode 內的 tips：
  - `ChatModeReadyTip`：inline `TipView` 顯示在 chat timeline 頂部，說明 proposal 審核制與執行後 AI 會自行接續（取代原本寫死的 "Chat Mode is ready..." assistant message）。
  - `ProposalReviewTip`：第一次出現 proposal 卡片時以 popover 提示 Run / Reject / revision 輸入框的用法，使用 event rule（`proposalShown` donation）觸發，按下 Run 或 Reject 即 invalidate。
- Tips 只做 feature discovery；安全規則（永不自動執行等）不放在可關閉的 tip 內。

## 服務與模型規劃

- `SwiftTermTerminalViewRepresentable`
  - 以 `UIViewRepresentable` 包裝 SwiftTerm `TerminalView`，只負責 ANSI rendering、cursor、selection 與 scrollback 呈現。
  - Ghost Text、Chat Mode、toolbar 與狀態 UI 保持在 SwiftUI overlay 或 accessory layer。
- `TerminalSessionStore`
  - 保存 renderer state reference、input state、raw byte ring buffer、plain text line ring buffer 與 output batching queue。
  - 提供 `appendRemoteData(_:)`，將 SSH bytes 送入 SwiftTerm 並同步更新 recorder / retained buffers。
- `SSHSessionDriver`
  - SSH backend protocol，負責 connect/auth、PTY shell、read/write、resize、disconnect 與 connection state events。
  - v1 第一候選實作為 `CitadelSSHSessionDriver`，但 UI 與 session lifecycle 不直接依賴 Citadel。
- `SessionRecorder`
  - 從 input pipeline 記錄 current input line，遇到 Enter 提交 command；需處理 Backspace、Ctrl-C、Ctrl-D 與 paste multi-line。
  - 從 output pipeline 維護有限 Ring Buffer 與 host profile snapshot，作為 AI context 來源。
- `RedactionService`
  - 在送 LLM 前執行 `redact(snapshot:)`，產生 redacted snapshot；raw limited buffer 可留在記憶體，但不可進 prompt、log 或 provider request。
- `AIChatService`
  - 負責 Chat Mode message history、system prompt、provider request、response parsing。
  - 不持有 API key 明文；執行 request 前透過 `SecureSecretStore` 讀取。
- `LLMExecutionBridge`
  - 只接收使用者核准的 `CommandProposal`，不接受 AI response 直接觸發執行。
  - 內部步驟：確認 approval metadata -> app-side risk check -> 寫入 same PTY -> 標記 recorder command source -> 在 transcript window 內收集 redacted 輸出 -> 將 transcript 回寫 chat timeline 與 proposal -> 觸發 LLM continuation。
  - 若後續責任膨脹，可拆成 `CommandApprovalStore`、`CommandRunner`、`CommandResultSummarizer`。
- 後續模型：
  - `TerminalMode`：`raw` / `chat`。
  - `SessionContextSnapshot`：最近 commands、目前 input line、host profile summary、output Ring Buffer snapshot。
  - `TerminalRingBufferSnapshot`：`headLines`、`tailLines`、`totalLineCount`、`redactionSummary`。
  - `AIChatMessage`：role、content、timestamp、command proposals、execution result reference。
  - `CommandProposal`：command text、source message id、tool call id、status（pending / approved / rejected）、execution transcript、user feedback、risk level、expected effect、createdAt、approvedAt。
  - `CommandExecutionResult`：v1 保存 submitted command、best-effort output summary、startedAt、finishedAt guess；不保證 stderr / exit code。

## 安全與 AI 邊界

- AI 生成指令絕不自動執行；`Run` 與使用者手動確認是唯一執行入口。
- `Edit` 只把 command 填入輸入框，不執行。
- `Reject` 與 revision feedback 只改變 proposal 狀態與後續 LLM context，不會執行任何指令。
- LLM continuation 只在使用者完成 `Run` 或附帶 feedback 的拒絕後觸發；continuation 本身仍只能產出新的 `CommandProposal`，不能執行。
- 回傳給 LLM 的 execution transcript 必須先經過 `RedactionService`。
- 發送給 LLM 的 session context 必須先做 secret redaction。
- Redaction 需遮蔽疑似 password、token、private key、API key、authorization header、connection string。
- LLM API key 只從 Keychain 讀取，不寫入 SwiftData、`UserDefaults`、log 或 prompt。
- `SessionRecorder` Ring Buffer 診斷預設只取 Head 20 + Tail 20 行；長輸出不整段送出。
- Terminal output 是 untrusted data；LLM 不得遵從 output 中要求改變 policy、洩漏 secret 或自動執行指令的文字。
- `LLMExecutionBridge` 必須保留 user-approved metadata，方便 UI 顯示「此 command 是由使用者核准後執行」。
- 破壞性 command 後續可加二次確認；v1 的不可退讓規則是永不自動執行。

## 後續實作切分

1. SwiftTerm wrapper：顯示 mock ANSI output、接 keyboard input、支援 resize callback。
2. Local / mock stream：用 `MockSSHDriver` fixture 驗證 Raw Mode、keyboard accessory、output batching。
3. Terminal store：建立 raw byte ring buffer、plain text line ring buffer、retained log summary。
4. SSH driver：接 `CitadelSSHSessionDriver` 的 password / key auth、PTY shell、resize、disconnect。
5. SessionRecorder：記錄 command、current input line、output ring buffer，並接 `RedactionService`。
6. AI overlay：Chat Mode header、TL;DR sheet、CommandProposal Run / Edit / Reject 審核流程、execution transcript 回饋與 LLM continuation。
7. TipKit：intro guide（mode switch、diagnose）與 chat tips（chat ready、proposal review）。

## 測試情境

- Raw Mode 可顯示 mock ANSI output，且不需要自製 ANSI parser。
- Keyboard accessory 的 Tab、Esc、Ctrl-C、Ctrl-D、方向鍵會送出正確 bytes 或 control sequences。
- 切到 Chat Mode 時 SSH read loop 不停止；切回 Raw Mode 後 terminal 顯示最新 output。
- TL;DR 可由手動按鈕或 output heuristic 觸發，不依賴 exit code。
- `SessionRecorder` 可從輸入側記錄 command，並處理 Backspace、Ctrl-C、Ctrl-D、paste multi-line。
- Redaction 後的 snapshot 不包含 API key、SSH password、private key、token。
- Chat Mode header 顯示 host alias、connection state、cwd guess、last command。
- AI `CommandProposal` 預設不可執行，必須由使用者點擊 `Run`。
- `Run` 後 proposal 狀態為 `approved`，transcript 寫回 proposal，並自動觸發一次 LLM continuation。
- `Reject` 後 proposal 折疊且狀態為 `rejected`；無 feedback 時不發 LLM request，有 feedback 時觸發 revision turn。
- 有 pending proposal 時 chat 輸入框為 revision 模式；該 proposal resolve 後輸入框回到一般提問模式。
- v1 same-PTY Run 不宣稱精準 stderr / exit code；若 UI 顯示結果，只能顯示 best-effort transcript summary。
