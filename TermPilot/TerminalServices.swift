import Foundation

enum TerminalMode: String, CaseIterable, Identifiable, Hashable {
    case raw
    case chat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .raw:
            "Raw"
        case .chat:
            "Chat"
        }
    }

    var systemImage: String {
        switch self {
        case .raw:
            "terminal"
        case .chat:
            "sparkles"
        }
    }
}

enum CommandRiskLevel: String, Codable, CaseIterable, Identifiable, Hashable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low:
            "Low"
        case .medium:
            "Medium"
        case .high:
            "High"
        }
    }
}

enum AIChatRole: String, Codable, Hashable {
    case user
    case assistant
    case execution
}

enum CommandProposalStatus: String, Codable, Hashable {
    case pending
    case approved
    case rejected
}

struct CommandProposal: Identifiable, Codable, Hashable {
    var id: UUID
    var command: String
    var explanation: String
    var expectedEffect: String
    var riskLevel: CommandRiskLevel
    var requiresSudo: Bool
    var destructive: Bool
    var provider: AIProvider
    var sourceMessageID: UUID?
    var toolCallID: String?
    var status: CommandProposalStatus
    var executionTranscript: String?
    var userFeedback: String?
    var createdAt: Date
    var approvedAt: Date?

    init(
        id: UUID = UUID(),
        command: String,
        explanation: String,
        expectedEffect: String,
        riskLevel: CommandRiskLevel,
        requiresSudo: Bool,
        destructive: Bool,
        provider: AIProvider,
        sourceMessageID: UUID? = nil,
        toolCallID: String? = nil,
        status: CommandProposalStatus = .pending,
        executionTranscript: String? = nil,
        userFeedback: String? = nil,
        createdAt: Date = .now,
        approvedAt: Date? = nil
    ) {
        self.id = id
        self.command = command
        self.explanation = explanation
        self.expectedEffect = expectedEffect
        self.riskLevel = riskLevel
        self.requiresSudo = requiresSudo
        self.destructive = destructive
        self.provider = provider
        self.sourceMessageID = sourceMessageID
        self.toolCallID = toolCallID
        self.status = status
        self.executionTranscript = executionTranscript
        self.userFeedback = userFeedback
        self.createdAt = createdAt
        self.approvedAt = approvedAt
    }
}

struct CommandExecutionResult: Identifiable, Codable, Hashable {
    var id: UUID
    var proposalID: UUID?
    var submittedCommand: String
    var transcriptSummary: String
    var startedAt: Date
    var finishedAt: Date?
    var approvedByUser: Bool

    init(
        id: UUID = UUID(),
        proposalID: UUID? = nil,
        submittedCommand: String,
        transcriptSummary: String,
        startedAt: Date = .now,
        finishedAt: Date? = nil,
        approvedByUser: Bool
    ) {
        self.id = id
        self.proposalID = proposalID
        self.submittedCommand = submittedCommand
        self.transcriptSummary = transcriptSummary
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.approvedByUser = approvedByUser
    }
}

struct AIChatMessage: Identifiable, Codable, Hashable {
    var id: UUID
    var role: AIChatRole
    var content: String
    var timestamp: Date
    var commandProposals: [CommandProposal]
    var executionResults: [CommandExecutionResult]

    init(
        id: UUID = UUID(),
        role: AIChatRole,
        content: String,
        timestamp: Date = .now,
        commandProposals: [CommandProposal] = [],
        executionResults: [CommandExecutionResult] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.commandProposals = commandProposals
        self.executionResults = executionResults
    }
}

enum TerminalInputSource: String, Codable, Hashable {
    case user
    case aiApproved
}

struct SessionCommandRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var command: String
    var source: TerminalInputSource
    var submittedAt: Date

    init(
        id: UUID = UUID(),
        command: String,
        source: TerminalInputSource,
        submittedAt: Date = .now
    ) {
        self.id = id
        self.command = command
        self.source = source
        self.submittedAt = submittedAt
    }
}

struct RedactionSummary: Codable, Hashable {
    var apiKeys: Int = 0
    var authorizationHeaders: Int = 0
    var privateKeys: Int = 0
    var credentials: Int = 0
    var connectionStrings: Int = 0

    var total: Int {
        apiKeys + authorizationHeaders + privateKeys + credentials + connectionStrings
    }

    var label: String {
        total == 1 ? "1 secret redacted" : "\(total) secrets redacted"
    }
}

struct TerminalRingBufferSnapshot: Codable, Hashable {
    var headLines: [String]
    var tailLines: [String]
    var totalLineCount: Int
    var redactionSummary: RedactionSummary

    var isEmpty: Bool {
        totalLineCount == 0 && headLines.isEmpty && tailLines.isEmpty
    }
}

struct SessionContextSnapshot: Codable, Hashable {
    var hostAlias: String
    var subtitle: String
    var connectionState: TerminalSessionState
    var cwdGuess: String
    var shellHint: String
    var osHint: String
    var userRoleHint: String
    var lastCommand: String?
    var recentCommands: [SessionCommandRecord]
    var currentInputLine: String
    var ringBuffer: TerminalRingBufferSnapshot
}

struct SessionRecorder {
    static let defaultSnapshotLineLimit = 20
    static let defaultRecentCommandLimit = 20

    private(set) var currentInputLine = ""
    private(set) var recentCommands: [SessionCommandRecord] = []
    private(set) var headLines: [String] = []
    private(set) var tailLines: [String] = []
    private(set) var totalOutputLineCount = 0

    private var partialOutputLine = ""
    private let snapshotLineLimit: Int
    private let recentCommandLimit: Int

    init(
        snapshotLineLimit: Int = Self.defaultSnapshotLineLimit,
        recentCommandLimit: Int = Self.defaultRecentCommandLimit
    ) {
        self.snapshotLineLimit = snapshotLineLimit
        self.recentCommandLimit = recentCommandLimit
    }

    var lastCommand: String? {
        recentCommands.last?.command
    }

    mutating func replaceCurrentInputLine(_ input: String) {
        currentInputLine = input
    }

    mutating func clearOutput() {
        headLines.removeAll()
        tailLines.removeAll()
        totalOutputLineCount = 0
        partialOutputLine.removeAll()
    }

    mutating func recordInput(_ data: Data, source: TerminalInputSource = .user) -> [SessionCommandRecord] {
        var submittedCommands: [SessionCommandRecord] = []

        for byte in data {
            switch byte {
            case 3, 4:
                currentInputLine.removeAll()
            case 8, 127:
                if !currentInputLine.isEmpty {
                    currentInputLine.removeLast()
                }
            case 10, 13:
                if let record = recordSubmittedCommand(currentInputLine, source: source) {
                    submittedCommands.append(record)
                }
                currentInputLine.removeAll()
            case 9:
                currentInputLine.append("\t")
            case 32...126:
                currentInputLine.append(Character(UnicodeScalar(byte)))
            default:
                break
            }
        }

        return submittedCommands
    }

    @discardableResult
    mutating func recordSubmittedCommand(
        _ command: String,
        source: TerminalInputSource = .user,
        submittedAt: Date = .now
    ) -> SessionCommandRecord? {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { return nil }

        let record = SessionCommandRecord(
            command: trimmedCommand,
            source: source,
            submittedAt: submittedAt
        )
        recentCommands.append(record)
        if recentCommands.count > recentCommandLimit {
            recentCommands.removeFirst(recentCommands.count - recentCommandLimit)
        }
        return record
    }

    mutating func recordOutput(_ data: Data) -> [String] {
        let text = String(decoding: data, as: UTF8.self)
        var completedLines: [String] = []

        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 10:
                flushPartialOutputLine(to: &completedLines)
            case 13:
                flushPartialOutputLine(to: &completedLines)
            default:
                partialOutputLine.append(String(scalar))
            }
        }

        return completedLines
    }

    mutating func recordOutputLines(_ lines: [String]) {
        for line in lines {
            appendOutputLine(line)
        }
    }

    func snapshot(
        hostAlias: String,
        subtitle: String,
        connectionState: TerminalSessionState,
        cwdGuess: String,
        shellHint: String,
        osHint: String,
        userRoleHint: String
    ) -> SessionContextSnapshot {
        let normalizedPendingLine = normalizedOutputLine(partialOutputLine)
        let pendingLine = shouldRecordOutputLine(normalizedPendingLine) ? normalizedPendingLine : ""
        let hasPendingLine = !pendingLine.isEmpty
        let snapshotHeadLines = headLinesWithPendingLine(pendingLine)
        let snapshotTailLines = tailLinesWithPendingLine(pendingLine)

        return SessionContextSnapshot(
            hostAlias: hostAlias,
            subtitle: subtitle,
            connectionState: connectionState,
            cwdGuess: cwdGuess,
            shellHint: shellHint,
            osHint: osHint,
            userRoleHint: userRoleHint,
            lastCommand: lastCommand,
            recentCommands: recentCommands,
            currentInputLine: currentInputLine,
            ringBuffer: TerminalRingBufferSnapshot(
                headLines: snapshotHeadLines,
                tailLines: snapshotTailLines,
                totalLineCount: totalOutputLineCount + (hasPendingLine ? 1 : 0),
                redactionSummary: RedactionSummary()
            )
        )
    }

    private func headLinesWithPendingLine(_ pendingLine: String) -> [String] {
        guard !pendingLine.isEmpty, headLines.count < snapshotLineLimit else {
            return headLines
        }
        return headLines + [pendingLine]
    }

    private func tailLinesWithPendingLine(_ pendingLine: String) -> [String] {
        guard !pendingLine.isEmpty else { return tailLines }
        var lines = tailLines + [pendingLine]
        if lines.count > snapshotLineLimit {
            lines.removeFirst(lines.count - snapshotLineLimit)
        }
        return lines
    }

    private mutating func flushPartialOutputLine(to completedLines: inout [String]) {
        let line = normalizedOutputLine(partialOutputLine)
        partialOutputLine.removeAll()
        guard !line.isEmpty, shouldRecordOutputLine(line) else { return }
        completedLines.append(line)
        appendOutputLine(line)
    }

    private mutating func appendOutputLine(_ line: String) {
        let line = normalizedOutputLine(line)
        guard !line.isEmpty, shouldRecordOutputLine(line) else { return }

        totalOutputLineCount += 1
        if headLines.count < snapshotLineLimit {
            headLines.append(line)
        }

        tailLines.append(line)
        if tailLines.count > snapshotLineLimit {
            tailLines.removeFirst(tailLines.count - snapshotLineLimit)
        }
    }

    private func shouldRecordOutputLine(_ line: String) -> Bool {
        !isLikelyEchoedInputLine(line)
    }

    private func isLikelyEchoedInputLine(_ line: String) -> Bool {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty else { return false }

        let commands = echoCandidateCommands
        for command in commands {
            let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedCommand.isEmpty, trimmedLine != trimmedCommand else { continue }

            let suffixes: [String]
            if let firstCharacter = trimmedCommand.first {
                suffixes = [trimmedCommand, "\(firstCharacter)\(trimmedCommand)"]
            } else {
                suffixes = [trimmedCommand]
            }

            for suffix in suffixes where trimmedLine.hasSuffix(suffix) {
                let prefix = trimmedLine.dropLast(suffix.count).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !prefix.isEmpty else { continue }
                if Self.looksLikeShellPromptPrefix(String(prefix)) {
                    return true
                }
            }
        }

        return false
    }

    private var echoCandidateCommands: [String] {
        var commands = recentCommands.suffix(5).map(\.command)
        if !currentInputLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            commands.append(currentInputLine)
        }
        return commands
    }

    private static func looksLikeShellPromptPrefix(_ prefix: String) -> Bool {
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrefix.isEmpty else { return false }

        if trimmedPrefix.contains("➜") || trimmedPrefix.contains("❯") || trimmedPrefix.contains("❮") {
            return true
        }

        if let lastCharacter = trimmedPrefix.last, "$%#>".contains(lastCharacter) {
            return true
        }

        if trimmedPrefix.contains("@"), trimmedPrefix.contains(":") {
            return true
        }

        return false
    }

    private func normalizedOutputLine(_ line: String) -> String {
        var result = line
        result = Self.ansiControlSequenceRegex.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..<result.endIndex, in: result),
            withTemplate: ""
        )
        result = result.unicodeScalars
            .filter { scalar in
                scalar.value == 9 || scalar.value >= 32
            }
            .map(String.init)
            .joined()
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let ansiControlSequenceRegex = try! NSRegularExpression(
        pattern: #"\x{1B}(?:\[[0-?]*[ -/]*[@-~]|\][^\x{07}\x{1B}]*(?:\x{07}|\x{1B}\\)|[()*+\-./][0-~]|[0-~])"#
    )
}

enum RedactionService {
    static func redact(_ snapshot: SessionContextSnapshot) -> SessionContextSnapshot {
        var summary = RedactionSummary()
        var redactedSnapshot = snapshot

        redactedSnapshot.hostAlias = redact(snapshot.hostAlias, summary: &summary)
        redactedSnapshot.subtitle = redact(snapshot.subtitle, summary: &summary)
        redactedSnapshot.cwdGuess = redact(snapshot.cwdGuess, summary: &summary)
        redactedSnapshot.lastCommand = snapshot.lastCommand.map { redact($0, summary: &summary) }
        redactedSnapshot.currentInputLine = redact(snapshot.currentInputLine, summary: &summary)
        redactedSnapshot.recentCommands = snapshot.recentCommands.map { record in
            var record = record
            record.command = redact(record.command, summary: &summary)
            return record
        }
        redactedSnapshot.ringBuffer.headLines = snapshot.ringBuffer.headLines.map { redact($0, summary: &summary) }
        redactedSnapshot.ringBuffer.tailLines = snapshot.ringBuffer.tailLines.map { redact($0, summary: &summary) }
        redactedSnapshot.ringBuffer.redactionSummary = summary

        return redactedSnapshot
    }

    static func redact(_ text: String) -> String {
        var summary = RedactionSummary()
        return redact(text, summary: &summary)
    }

    private static func redact(_ text: String, summary: inout RedactionSummary) -> String {
        var result = text
        result = replace(
            in: result,
            pattern: #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#,
            placeholder: "[REDACTED_PRIVATE_KEY]",
            count: &summary.privateKeys
        )
        result = replace(
            in: result,
            pattern: #"(?i)\bAuthorization\s*:\s*(Bearer|Basic)\s+[^\s]+"#,
            placeholder: "Authorization: [REDACTED_AUTHORIZATION]",
            count: &summary.authorizationHeaders
        )
        result = replace(
            in: result,
            pattern: #"\b(?:sk-(?:proj-)?[A-Za-z0-9_\-]{8,}|sk-ant-[A-Za-z0-9_\-]{8,}|AIza[0-9A-Za-z_\-]{16,})\b"#,
            placeholder: "[REDACTED_API_KEY]",
            count: &summary.apiKeys
        )
        result = replace(
            in: result,
            pattern: #"(?i)\b(password|passwd|token|api[_-]?key|secret)\s*[:=]\s*['"]?[^'"\s]+"#,
            placeholder: "[REDACTED_CREDENTIAL]",
            count: &summary.credentials
        )
        result = replace(
            in: result,
            pattern: #"\b[a-z][a-z0-9+.-]*://[^\s:@]+:[^\s@]+@[^\s]+"#,
            placeholder: "[REDACTED_CONNECTION_STRING]",
            count: &summary.connectionStrings
        )
        return result
    }

    private static func replace(
        in text: String,
        pattern: String,
        placeholder: String,
        count: inout Int
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.numberOfMatches(in: text, range: range)
        guard matches > 0 else { return text }
        count += matches
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: placeholder)
    }
}

enum CommandRiskEvaluator {
    static func normalizedProposal(_ proposal: CommandProposal) -> CommandProposal {
        var proposal = proposal
        let forcedRisk = riskLevel(for: proposal.command, destructive: proposal.destructive)
        if forcedRisk == .high || (forcedRisk == .medium && proposal.riskLevel == .low) {
            proposal.riskLevel = forcedRisk
        }
        if forcedRisk == .high {
            proposal.destructive = true
        }
        return proposal
    }

    static func riskLevel(for command: String, destructive: Bool = false) -> CommandRiskLevel {
        let lowered = command.lowercased()
        let highRiskPatterns = [
            "rm -rf",
            "mkfs",
            "dd if=",
            "chmod -r 777",
            "shutdown",
            "reboot",
            ">: /etc",
            "> /etc/",
            "tee /etc/",
            "wipefs",
            "diskutil erase"
        ]

        if destructive || highRiskPatterns.contains(where: lowered.contains) {
            return .high
        }

        if lowered.contains("sudo ") || lowered.contains("systemctl restart") || lowered.contains("service ") {
            return .medium
        }

        return .low
    }
}

struct ApprovedCommand {
    var proposal: CommandProposal
    var metadata: CommandExecutionResult
}

enum LLMExecutionBridge {
    static func approve(_ proposal: CommandProposal, at date: Date = .now) -> ApprovedCommand {
        var proposal = CommandRiskEvaluator.normalizedProposal(proposal)
        proposal.approvedAt = date

        let result = CommandExecutionResult(
            proposalID: proposal.id,
            submittedCommand: proposal.command,
            transcriptSummary: "Submitted to the existing interactive PTY after user approval.",
            startedAt: date,
            approvedByUser: true
        )

        return ApprovedCommand(proposal: proposal, metadata: result)
    }
}

enum TerminalControlKey: String, CaseIterable, Identifiable {
    case tab
    case escape
    case enter
    case backspace
    case controlC
    case controlD
    case up
    case down
    case left
    case right
    case slash
    case dash
    case pipe

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tab:
            "Tab"
        case .escape:
            "Esc"
        case .enter:
            "Enter"
        case .backspace:
            "Del"
        case .controlC:
            "Ctrl-C"
        case .controlD:
            "Ctrl-D"
        case .up:
            "Up"
        case .down:
            "Down"
        case .left:
            "Left"
        case .right:
            "Right"
        case .slash:
            "/"
        case .dash:
            "-"
        case .pipe:
            "|"
        }
    }

    var bytes: Data {
        switch self {
        case .tab:
            Data([9])
        case .escape:
            Data([27])
        case .enter:
            Data([13])
        case .backspace:
            Data([127])
        case .controlC:
            Data([3])
        case .controlD:
            Data([4])
        case .up:
            Data("\u{1B}[A".utf8)
        case .down:
            Data("\u{1B}[B".utf8)
        case .right:
            Data("\u{1B}[C".utf8)
        case .left:
            Data("\u{1B}[D".utf8)
        case .slash:
            Data("/".utf8)
        case .dash:
            Data("-".utf8)
        case .pipe:
            Data("|".utf8)
        }
    }
}

enum SSHAuthenticationConfig {
    case password(String)
    case privateKey(String, passphrase: String?)
}

struct SSHConnectionConfig {
    var host: String
    var port: Int
    var username: String
    var auth: SSHAuthenticationConfig
    var term: String
    var initialColumns: Int
    var initialRows: Int

    init(
        host: String,
        port: Int = 22,
        username: String,
        auth: SSHAuthenticationConfig,
        term: String = "xterm-256color",
        initialColumns: Int = 80,
        initialRows: Int = 24
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.term = term
        self.initialColumns = max(initialColumns, 1)
        self.initialRows = max(initialRows, 1)
    }
}

enum SSHSessionEvent {
    case status(String)
    case connecting
    case authenticating
    case connected
    case ptyStarted
    case output(Data)
    case resized(columns: Int, rows: Int)
    case disconnected(reason: String?)
    case failed(SSHSessionError)
}

enum SSHSessionError: LocalizedError, Equatable {
    case authenticationFailed
    case connectionFailed(String)
    case hostKeyMismatch
    case timeout
    case ptyFailed(String)
    case disconnected(String?)
    case unsupported(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            "Authentication failed."
        case .connectionFailed(let message):
            "Connection failed: \(message)"
        case .hostKeyMismatch:
            "Host key verification failed."
        case .timeout:
            "Connection timed out."
        case .ptyFailed(let message):
            "PTY failed: \(message)"
        case .disconnected(let reason):
            reason.map { "Disconnected: \($0)" } ?? "Disconnected."
        case .unsupported(let message):
            "Unsupported SSH feature: \(message)"
        case .unknown(let message):
            message
        }
    }

    static func map(_ error: Error) -> SSHSessionError {
        if let sshError = error as? SSHSessionError {
            return sshError
        }

        let message = String(describing: error)
        let lowered = message.lowercased()

        if lowered.contains("unsupportedpasswordauthentication")
            || lowered.contains("passwordauthenticationnotsupported")
            || lowered.contains("unsupported password") {
            return .unsupported(
                "Server does not offer SSH password auth. Use an SSH key; keyboard-interactive is not supported by this backend."
            )
        }
        if lowered.contains("allauthenticationoptionsfailed")
            || lowered.contains("unsupportedprivatekeyauthentication")
            || lowered.contains("unsupported private key") {
            return .authenticationFailed
        }
        if lowered.contains("auth") || lowered.contains("password") || lowered.contains("permission denied") || lowered.contains("denied") {
            return .authenticationFailed
        }
        if lowered.contains("hostkey") || lowered.contains("host key") || lowered.contains("invalidhostkey") {
            return .hostKeyMismatch
        }
        if lowered.contains("timeout") || lowered.contains("timed out") {
            return .timeout
        }
        if lowered.contains("connection") || lowered.contains("network") || lowered.contains("socket") {
            return .connectionFailed(message)
        }
        return .unknown(message)
    }
}

struct TerminalOutputChunk: Identifiable, Hashable {
    let sequence: Int
    let data: Data

    var id: Int { sequence }
}

struct TerminalSessionStore {
    static let rawByteLimit = 1_000_000

    private(set) var outputChunks: [TerminalOutputChunk] = []
    private var nextOutputSequence = 0
    private var rawByteCount = 0

    mutating func appendRemoteData(_ data: Data) -> TerminalOutputChunk? {
        guard !data.isEmpty else { return nil }

        let chunk = TerminalOutputChunk(sequence: nextOutputSequence, data: data)
        nextOutputSequence += 1
        outputChunks.append(chunk)
        rawByteCount += data.count
        trimRawBytesIfNeeded()
        return chunk
    }

    mutating func clear() {
        outputChunks.removeAll()
        rawByteCount = 0
    }

    private mutating func trimRawBytesIfNeeded() {
        while rawByteCount > Self.rawByteLimit, let first = outputChunks.first {
            rawByteCount -= first.data.count
            outputChunks.removeFirst()
        }
    }
}

protocol SSHSessionDriver: AnyObject {
    var events: AsyncStream<SSHSessionEvent> { get }

    func connect(config: SSHConnectionConfig) async throws
    func startPTY(term: String, columns: Int, rows: Int) async throws
    func write(_ data: Data) async throws
    func resize(columns: Int, rows: Int) async throws
    func disconnect() async
}

final class MockSSHDriver: SSHSessionDriver {
    private let eventStream: AsyncStream<SSHSessionEvent>
    private var eventContinuation: AsyncStream<SSHSessionEvent>.Continuation?
    private var config: SSHConnectionConfig?
    private var columns = 80
    private var rows = 24
    private var cwd = "~"
    private var commandBuffer = ""
    private var isConnected = false

    var events: AsyncStream<SSHSessionEvent> {
        eventStream
    }

    init() {
        var continuation: AsyncStream<SSHSessionEvent>.Continuation?
        eventStream = AsyncStream { continuation = $0 }
        eventContinuation = continuation
    }

    func connect(config: SSHConnectionConfig) async throws {
        self.config = config
        emit(.connecting)
        emit(.authenticating)
        emit(.connected)
        isConnected = true
    }

    func startPTY(term: String, columns: Int, rows: Int) async throws {
        self.columns = max(columns, 1)
        self.rows = max(rows, 1)
        emit(.ptyStarted)
        emitOutput("Connected to mock PTY. This stream is only for tests and previews.\r\n")
        emitPrompt()
    }

    func write(_ data: Data) async throws {
        guard isConnected else {
            throw SSHSessionError.disconnected(nil)
        }

        for byte in data {
            switch byte {
            case 3:
                commandBuffer.removeAll()
                emitOutput("^C\r\n")
                emitPrompt()
            case 4:
                emit(.disconnected(reason: "EOF"))
                isConnected = false
            case 8, 127:
                if !commandBuffer.isEmpty {
                    commandBuffer.removeLast()
                    emitOutput("\u{8} \u{8}")
                }
            case 10, 13:
                emitOutput("\r\n")
                submit(commandBuffer)
                commandBuffer.removeAll()
                if isConnected {
                    emitPrompt()
                }
            case 9:
                commandBuffer.append("\t")
            case 32...126:
                commandBuffer.append(Character(UnicodeScalar(byte)))
                emitOutput(Data([byte]))
            default:
                break
            }
        }
    }

    func resize(columns: Int, rows: Int) async throws {
        self.columns = max(columns, 1)
        self.rows = max(rows, 1)
        emit(.resized(columns: self.columns, rows: self.rows))
    }

    func disconnect() async {
        guard isConnected else { return }
        isConnected = false
        emit(.disconnected(reason: "Closed by user"))
        eventContinuation?.finish()
    }

    private func submit(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        for line in responseLines(for: trimmed) {
            emitOutput("\(line)\r\n")
        }
    }

    private func responseLines(for command: String) -> [String] {
        let lowered = command.lowercased()
        let username = config?.username ?? "user"

        if lowered == "pwd" {
            return [cwd]
        }
        if lowered == "whoami" {
            return [username]
        }
        if lowered == "uname -a" || lowered == "uname" {
            return ["Linux termpilot-demo 6.8.0-demo #1 SMP aarch64 GNU/Linux"]
        }
        if lowered == "echo $shell" || lowered == "echo $0" {
            return ["/bin/bash"]
        }
        if lowered == "id -u" {
            return [username == "root" ? "0" : "1000"]
        }
        if lowered.hasPrefix("echo ") {
            return [String(command.dropFirst(5))]
        }
        if lowered == "ls" || lowered == "ls -la" || lowered == "ls --color=auto" {
            return [
                "total 32",
                "drwxr-xr-x  6 \(username) staff  192 Jun 11 21:00 .",
                "drwxr-xr-x 12 \(username) staff  384 Jun 11 20:59 ..",
                "-rw-r--r--  1 \(username) staff  172 deploy.sh",
                "drwxr-xr-x  4 \(username) staff  128 logs"
            ]
        }
        if lowered.hasPrefix("cd ") {
            let target = String(command.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            if target == "~" || target.isEmpty {
                cwd = "~"
            } else if target.hasPrefix("/") {
                cwd = target
            } else if cwd == "~" {
                cwd = "~/\(target)"
            } else {
                cwd = "\(cwd)/\(target)"
            }
            return []
        }
        if lowered.hasPrefix("tail ") {
            return [
                "Jun 11 21:00:01 app web[821]: started request id=demo-1",
                "Jun 11 21:00:02 app web[821]: warning upstream latency=241ms",
                "Jun 11 21:00:03 app web[821]: error connect ECONNREFUSED 127.0.0.1:5432"
            ]
        }
        if lowered == "cat /etc/os-release" {
            return [
                #"NAME="Ubuntu""#,
                #"VERSION="24.04 LTS (Noble Numbat)""#
            ]
        }
        if lowered == "date" {
            return [Date.now.formatted(date: .abbreviated, time: .standard)]
        }
        if lowered == "clear" {
            emitOutput("\u{1B}[2J\u{1B}[H")
            return []
        }

        return [
            "mock-pty: command submitted to \(config?.host ?? "mock-host")",
            "mock-pty: viewport \(columns)x\(rows)"
        ]
    }

    private func emitPrompt() {
        let username = config?.username ?? "user"
        emitOutput("\(username)@mock:\(cwd)$ ")
    }

    private func emitOutput(_ text: String) {
        emitOutput(Data(text.utf8))
    }

    private func emitOutput(_ data: Data) {
        emit(.output(data))
    }

    private func emit(_ event: SSHSessionEvent) {
        eventContinuation?.yield(event)
    }
}
