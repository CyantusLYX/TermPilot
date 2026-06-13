## 真 SSH Terminal Implementation 計劃

本階段目標不是做 mock SSH demo，而是完成一條可在 simulator 錄影展示的真 SSH usable path：

Vault Host → SSH connect/auth → PTY shell → SwiftTerm rendering → keyboard input → resize → SessionRecorder → AI context snapshot。

Mock driver 只保留作為單元測試、UI preview 與 CI fixture，不作為主線 milestone。

## 實作原則

* Raw Mode 必須接真 SSH interactive PTY，不使用 fake stream 作為主要 demo。
* SwiftTerm 只負責 terminal rendering，不負責 SSH lifecycle。
* SSH driver 必須能處理 connect、auth、PTY request、shell stream、stdin write、terminal resize、disconnect。
* v1 先支援 password auth，再支援 private key auth。
* v1 不做 separate exec channel；`Run` 仍寫入同一個 interactive PTY。
* `executeCommand` 不作為 Raw Mode 實作方式，只能作為未來精準 command result 或 health check 的補充。
* MockSSHDriver 只能用於測試 recorder、keyboard mapping、UI loading/error state，不列為 demo 主路徑。

## 主要架構

### 1. `SSHSessionDriver`

定義真 SSH driver protocol，讓 UI 不依賴 Citadel 或 NIOSSH 細節。

```swift
protocol SSHSessionDriver: AnyObject {
    var events: AsyncStream<SSHSessionEvent> { get }

    func connect(config: SSHConnectionConfig) async throws
    func startPTY(term: String, columns: Int, rows: Int) async throws
    func write(_ data: Data) async throws
    func resize(columns: Int, rows: Int) async throws
    func disconnect() async
}
```

`SSHSessionEvent` 至少包含：

```swift
enum SSHSessionEvent {
    case connecting
    case authenticating
    case connected
    case ptyStarted
    case output(Data)
    case resized(columns: Int, rows: Int)
    case disconnected(reason: String?)
    case failed(SSHSessionError)
}
```

### 2. `CitadelSSHSessionDriver`

v1 主要實作。

責任：

* 建立 SSH connection。
* 使用 password auth。
* 後續加入 private key auth。
* 發起 PTY request，term 預設 `xterm-256color`。
* 啟動 interactive shell。
* 將 remote output 轉成 `.output(Data)` event。
* 將 keyboard input bytes 寫入 PTY stdin。
* 將 terminal resize 對應成 PTY resize request。
* connection close 或 error 時發送 `.disconnected` / `.failed`。

不可做的事：

* 不解析 ANSI。
* 不自行維護 terminal cursor。
* 不把 command result 包裝成精準 stdout / stderr / exit code。
* 不讓 AI 直接呼叫 driver write。

### 3. `TerminalSessionController`

新增一層 controller 統一協調 SwiftTerm、SSH driver、recorder 與 UI state。

```swift
@MainActor
final class TerminalSessionController: ObservableObject {
    @Published var connectionState: ConnectionState = .idle
    @Published var hostAlias: String = ""
    @Published var lastCommand: String?
    @Published var cwdGuess: String?

    let recorder: SessionRecorder
    let store: TerminalSessionStore

    private let driver: SSHSessionDriver

    func open(config: SSHConnectionConfig) async
    func sendKeyboardBytes(_ data: Data)
    func resize(columns: Int, rows: Int)
    func disconnect()
}
```

資料流固定為：

```text
SSH output
→ SSHSessionDriver.events
→ TerminalSessionController
→ TerminalSessionStore.appendRemoteData
→ SwiftTerm feed
→ SessionRecorder.observeOutput
```

使用者輸入固定為：

```text
Keyboard / accessory key
→ SwiftTerm delegate / input handler
→ TerminalSessionController.sendKeyboardBytes
→ SessionRecorder.observeInput
→ SSHSessionDriver.write
```

### 4. `SwiftTermTerminalViewRepresentable`

只處理 UIKit / SwiftUI bridge。

責任：

* 建立 SwiftTerm `TerminalView`。
* 接收 remote bytes 並餵給 SwiftTerm。
* 將 keyboard input delegate callback 轉成 bytes。
* 回報 terminal rows / columns 給 controller。
* view size 改變時觸發 resize。

不負責：

* 不 connect SSH。
* 不保存 API key。
* 不解析 command。
* 不做 AI overlay。

## 實作順序

### Milestone 1：SwiftTerm + 真 SSH skeleton

目標：畫面可以連到一台你自己的 Linux host，登入後看到 shell prompt。

工作項目：

1. 加入 SwiftTerm dependency。
2. 加入 Citadel dependency。
3. 建立 `SSHConnectionConfig`。
4. 建立 `SSHSessionDriver` protocol。
5. 建立 `CitadelSSHSessionDriver` 初版。
6. 建立 `TerminalSessionController.open(config:)`。
7. 在 `TerminalView` 進入畫面時啟動真 SSH connection。
8. 成功後 request PTY + shell。
9. remote output 餵進 SwiftTerm。

驗收：

* simulator 可連到實際 SSH server。
* 能看到真 shell prompt。
* 能執行 `whoami`、`pwd`、`ls`。
* ANSI color 能正常顯示，例如 `ls --color=auto`。
* 斷線時 UI 顯示 disconnected，不 crash。

### Milestone 2：Keyboard input usable path

目標：iOS keyboard 和 accessory bar 能真的操作遠端 shell。

工作項目：

1. 實作一般文字輸入。
2. Enter 送 `\r`。
3. Backspace 送 `0x7f`。
4. Tab 送 `\t`。
5. Esc 送 `0x1b`。
6. Ctrl-C 送 `0x03`。
7. Ctrl-D 送 `0x04`。
8. 方向鍵送 ANSI escape sequence。
9. accessory bar 加入 Tab、Esc、Ctrl-C、Ctrl-D、↑、↓、←、→、`/`、`-`、`|`。

驗收：

* 可以在 vim / nano / less 中基本操作。
* `ping 8.8.8.8` 後 Ctrl-C 可中斷。
* Tab completion 可觸發。
* 方向鍵可瀏覽 shell history。
* Backspace 不出現亂碼。

### Milestone 3：PTY resize

目標：旋轉螢幕或 keyboard 彈出後，remote shell 能知道 terminal size。

工作項目：

1. 從 SwiftTerm / view layout 計算 rows / columns。
2. 首次 request PTY 時帶入目前 rows / columns。
3. view size 改變時 debounce resize event。
4. 呼叫 driver resize。
5. 在 recorder 中記錄 resize event，但不送 LLM。

驗收：

* 執行 `stty size` 會得到合理 rows / columns。
* iPad / iPhone simulator 尺寸切換後，`stty size` 會變。
* `top`、`htop` 或 `less` 畫面不嚴重錯位。

### Milestone 4：Host config + auth

目標：從 Vault host 啟動真 SSH session。

工作項目：

1. `VaultHost` 轉成 `SSHConnectionConfig`。
2. 支援 host、port、username。
3. v1 支援 password auth。
4. password 從 Keychain 讀取。
5. 加入 host key policy：

   * debug 可使用 insecure accept。
   * production 必須有 known hosts / fingerprint confirmation。
6. connection error 顯示可理解訊息：

   * network unreachable
   * auth failed
   * host key mismatch
   * timeout
   * disconnected

驗收：

* 從 Vault Host 點擊 connect 會進入 Terminal View。
* 密碼錯誤會顯示 auth failed。
* port 錯誤會顯示 connection failed。
* API key、SSH password 不進 SwiftData、UserDefaults 或 log。

### Milestone 5：SessionRecorder 接真 stream

目標：AI context 來自真 SSH session，不來自 mock transcript。

工作項目：

1. input pipeline 記錄 current input line。
2. Enter 後提交 command record。
3. Backspace 更新 input line。
4. Ctrl-C 清掉 current input line，記錄 interrupted。
5. paste multi-line 拆成多個 logical input。
6. output pipeline 維護 plain text ring buffer。
7. output pipeline 維護 raw byte limited buffer。
8. snapshot 預設取 Head 20 + Tail 20。
9. 接 `RedactionService.redact(snapshot:)`。

驗收：

* 使用者輸入 `ls -la` 後，last command 顯示正確。
* 長 output 不會整段送入 AI context。
* token、password、private key 測試字串會被 redacted。
* Chat Mode header 可以顯示 host alias、connection state、cwd guess、last command。

### Milestone 6：Chat Mode + CommandProposal same PTY Run

目標：AI 只能提出 command，使用者確認後才寫入同一個真 SSH PTY。

工作項目：

1. Chat Mode 保持 SSH session 不停止。
2. header 顯示 host alias、connection state、cwd guess、last command。
3. `AIChatService` 使用 redacted session snapshot。
4. AI 回覆中的 command 轉成 `CommandProposal`。
5. `CommandProposalView` 顯示 command、expected effect、risk。
6. `Run` 必須由使用者點擊。
7. `Run` 呼叫 `LLMExecutionBridge`。
8. `LLMExecutionBridge` 做 app-side risk check。
9. 通過後寫入 same PTY。
10. chat timeline 顯示 submitted command 與 best-effort transcript summary。

驗收：

* AI 不會自動執行任何 command。
* 點 `Edit` 只把 command 放回輸入框。
* 點 `Run` 才會把 command 寫入真 SSH terminal。
* command 執行後 Raw Mode 可以看到真 terminal output。
* UI 不顯示精準 exit code，除非未來加入 separate exec channel。

## MockSSHDriver 的正確定位

`MockSSHDriver` 保留，但只用於：

* SwiftUI Preview。
* Unit test。
* Recorder input/output parser 測試。
* Keyboard accessory bytes mapping 測試。
* CI 中不需要真 server 的測試。

`MockSSHDriver` 不作為 simulator demo 的主要路徑。

若要穩定錄影，可準備一台固定測試 SSH host，例如：

```text
Host: demo-termpilot.local / VPS
User: demo
Shell: bash or zsh
Prompt: predictable PS1
Commands: whoami, pwd, ls, cat error.log, python3 broken.py
Network: same Wi-Fi or public VPS
```

## Simulator Demo Script

錄影時展示：

1. 從 Vault 點擊 `demo-server`。
2. 進入 Terminal View。
3. 顯示 `Connecting...`。
4. 成功出現真 shell prompt。
5. 輸入 `whoami`。
6. 輸入 `pwd`。
7. 輸入 `ls --color=auto`。
8. 執行一個會報錯的 command，例如 `python3 broken.py`。
9. 點擊 TL;DR。
10. 切到 Chat Mode。
11. AI 產生 `CommandProposal`。
12. 點 `Edit` 修改 command。
13. 點 `Run`。
14. 切回 Raw Mode，看到 command 已送入同一個真 SSH session。

## 不做事項

v1 不做：

* 自製 ANSI parser。
* fake SSH 當主 demo。
* 精準 stdout / stderr / exit code。
* automatic AI command execution。
* cursor-level ghost text。
* full terminal transcript 上傳 LLM。
* separate exec channel。
* SFTP。
* port forwarding。
* jump host。
* agent forwarding。

## 成功定義

本階段完成後，TermPilot 應該可以被描述為：

「一個真的能連 SSH 的 iOS terminal，使用 SwiftTerm render 遠端 PTY output，並且能把同一個 live session 的有限、redacted context 提供給 AI。AI 只能提出指令，使用者確認後才會寫入目前 interactive PTY。」

不是：

「一個用 mock log 模擬 SSH 的 AI terminal prototype。」
