# 08 Tech Stack Selection 規劃

## 目標

本文件固定 TermPilot v1 的 terminal、SSH、security 與 AI context 技術路線。當前目標是完成可錄製的 iPhone simulator 展示：畫面完整、流程可重拍、demo data 可控、terminal usable path 可信。

優先順序是降低錄影阻塞風險、提高畫面完整度，並讓 terminal path 可以從 mock stream 平滑接到真實 SSH；不以 live demo failure recovery 作為主要設計語氣。

## 最終決策

- Terminal：SwiftTerm selected，作為唯一 VT100/Xterm terminal renderer。
- SSH：`CitadelSSHSessionDriver` selected for first implementation，透過 `SSHSessionDriver` protocol 隔離 UI 與 Citadel 型別。
- Direct `apple/swift-nio-ssh`：不是 v1 主要路線；只有需要自己寫 lower-level driver 時才考慮。
- AI context：`SessionRecorder` selected，從 SSH/session events 維護有限 context，不讀取 SwiftTerm internals。
- Security：Apple Keychain + Security framework + CryptoKit/CommonCrypto selected。
- Feature discovery / onboarding：Apple TipKit selected；intro guide 與 chat 提示一律使用 `Tip` + `TipGroup`，不用 hardcoded seed message 或自製 overlay。
- Development fixture：`MockSSHDriver` 僅作為 development fixture driver，用於 UI 錄影、snapshot、AI overlay 測試，不是正式 runtime path。

## Terminal Integration Plan

- `SwiftTermTerminalViewRepresentable` 以 `UIViewRepresentable` 包裝 SwiftTerm `TerminalView`。
- SSH output bytes 透過 `TerminalSessionStore.appendRemoteData(_:)` 批次送入 SwiftTerm。
- SwiftTerm input delegate 將使用者輸入轉成 `Data`，交給 `SSHSessionDriver.send(_:)`。
- Terminal resize 由 wrapper 根據 view bounds 與 font metrics 計算 columns / rows，debounce 後呼叫 `SSHSessionDriver.resize(columns:rows:)`。
- 大量輸出先進 session buffer，再在 MainActor 批次 flush 到 SwiftTerm，避免每個 packet 都觸發 UI update。
- iOS terminal keyboard 需提供 accessory bar：Tab、Esc、Ctrl-C、Ctrl-D、方向鍵與常用符號。
- `SessionRecorder` hook 在 input 與 output pipeline，而不是 renderer internal buffer。

## SSH Backend Layers

- `CitadelSSHSessionDriver`：v1 第一實作目標，使用 Citadel high-level API 建立 password / key auth、PTY shell、read/write、resize 與 disconnect。
- Direct `NIOSSHSessionDriver`：未來若 Citadel 不符合需求，才以 `apple/swift-nio-ssh` building blocks 自寫 lower-level driver。
- `LibSSH2SessionDriver`：最後替代方案，需要 C library 包裝與 iOS build 配置，非 v1 優先路線。

## Security Components

- `SecureSecretStore`：管理 SSH password、private key body、passphrase、LLM API key 與 sync key material。
- `HostKeyTrustStore`：集中封裝 host key fingerprint 儲存與驗證。
- v1 host key policy 可採 TOFU 或 demo-only accept policy，但必須集中在 `HostKeyTrustStore`，不可散落在 SSH adapter。
- SwiftData 只保存可顯示 metadata 與 Keychain reference，不保存 password、private key body 或 API key。
- CryptoKit / CommonCrypto 用於 AES.GCM 與 PBKDF2-HMAC-SHA256 sync encryption。

## Integration Checklist

- `SwiftTermTerminalViewRepresentable` 可顯示 mock ANSI output。
- Keyboard input 可從 SwiftTerm delegate 回傳 bytes。
- Resize 可根據 bounds / font metrics 算出 columns、rows。
- `SSHSessionDriver` 可送入 / 讀出 `Data`。
- Output batching 在大量輸出時不造成 UI 卡頓。
- `SessionRecorder` 可記錄 command、current input line、output ring buffer 與 host profile snapshot。
- Raw Mode / Chat Mode 切換不斷線，SSH read loop 與 SwiftTerm buffer 持續更新。
- `HostKeyTrustStore` 可保存與比對 host key fingerprint。

## Implementation Milestones

1. SwiftTerm wrapper + mock byte stream：先讓 terminal UI 在 simulator 可錄、可輸入、可 resize。
2. Session store + buffers：建立 raw byte ring buffer、plain text line ring buffer 與 output batching。
3. SessionRecorder：從 input pipeline 記錄 commands，從 output pipeline 記錄有限 AI context。
4. Citadel adapter：接 password / key auth、PTY shell、resize、disconnect 與 basic reconnect。
5. AI overlay：Chat Mode / TL;DR 只讀 redacted `SessionContextSnapshot`，不碰 renderer internals。

## 不做事項

- 不自製 ANSI parser。
- 不讓 SwiftUI overlay 直接依賴 SwiftTerm internal buffer。
- 不把 direct `swift-nio-ssh` 當 v1 primary path。
- 不把 `MockSSHDriver` 當正式 runtime path。
- 不在 v1 引入額外 security package。
