import Foundation
import Testing
@testable import TermPilot

struct TerminalServicesTests {
    @Test func sessionRecorderTracksEditedAndPastedCommands() {
        var recorder = SessionRecorder()

        _ = recorder.recordInput(Data("echx".utf8))
        _ = recorder.recordInput(Data([127]))
        _ = recorder.recordInput(Data("o first\npwd\n".utf8))

        #expect(recorder.recentCommands.map(\.command) == ["echo first", "pwd"])
        #expect(recorder.currentInputLine.isEmpty)
        #expect(recorder.lastCommand == "pwd")
    }

    @Test func recorderKeepsHeadAndTailSnapshots() {
        var recorder = SessionRecorder(snapshotLineLimit: 2)
        recorder.recordOutputLines(["one", "two", "three", "four"])

        let snapshot = recorder.snapshot(
            hostAlias: "demo",
            subtitle: "root@example:22",
            connectionState: .connected,
            cwdGuess: "~",
            shellHint: "bash",
            osHint: "Ubuntu",
            userRoleHint: "root"
        )

        #expect(snapshot.ringBuffer.headLines == ["one", "two"])
        #expect(snapshot.ringBuffer.tailLines == ["three", "four"])
        #expect(snapshot.ringBuffer.totalLineCount == 4)
    }

    @Test func recorderIncludesUnterminatedOutputInSnapshots() {
        var recorder = SessionRecorder(snapshotLineLimit: 4)
        _ = recorder.recordInput(Data("sudo pacman -Syu\r".utf8))
        _ = recorder.recordOutput(Data("error: failed to prepare transaction".utf8))

        let snapshot = recorder.snapshot(
            hostAlias: "arch",
            subtitle: "demo@arch:22",
            connectionState: .connected,
            cwdGuess: "~",
            shellHint: "bash",
            osHint: "Arch",
            userRoleHint: "sudo-capable user"
        )

        #expect(snapshot.lastCommand == "sudo pacman -Syu")
        #expect(snapshot.ringBuffer.tailLines.contains("error: failed to prepare transaction"))
        #expect(snapshot.ringBuffer.totalLineCount == 1)
    }

    @Test func recorderFlushesCarriageReturnOutputForInteractiveTools() {
        var recorder = SessionRecorder(snapshotLineLimit: 4)
        let lines = recorder.recordOutput(Data("checking conflicts...\rerror: failed to commit transaction\r\n".utf8))

        let snapshot = recorder.snapshot(
            hostAlias: "arch",
            subtitle: "demo@arch:22",
            connectionState: .connected,
            cwdGuess: "~",
            shellHint: "bash",
            osHint: "Arch",
            userRoleHint: "sudo-capable user"
        )

        #expect(lines == ["checking conflicts...", "error: failed to commit transaction"])
        #expect(snapshot.ringBuffer.tailLines == ["checking conflicts...", "error: failed to commit transaction"])
    }

    @Test func recorderStripsANSICodesFromOutputContext() {
        var recorder = SessionRecorder()
        _ = recorder.recordOutput(Data("\u{001B}[31merror:\u{001B}[0m conflicted files\n".utf8))

        let snapshot = recorder.snapshot(
            hostAlias: "arch",
            subtitle: "demo@arch:22",
            connectionState: .connected,
            cwdGuess: "~",
            shellHint: "bash",
            osHint: "Arch",
            userRoleHint: "sudo-capable user"
        )

        #expect(snapshot.ringBuffer.tailLines == ["error: conflicted files"])
    }

    @Test func recorderStripsSingleCharacterTerminalEscapesFromOutputContext() {
        var recorder = SessionRecorder()
        _ = recorder.recordOutput(Data("\u{001B}=status ok\n".utf8))

        let snapshot = recorder.snapshot(
            hostAlias: "arch",
            subtitle: "demo@arch:22",
            connectionState: .connected,
            cwdGuess: "~",
            shellHint: "zsh",
            osHint: "Arch",
            userRoleHint: "standard user"
        )

        #expect(snapshot.ringBuffer.tailLines == ["status ok"])
    }

    @Test func recorderDropsPromptEchoLinesForSubmittedCommands() {
        var recorder = SessionRecorder()
        _ = recorder.recordInput(Data("pacman\r".utf8))
        let lines = recorder.recordOutput(Data("➜  ~ \u{001B}=ppacman\r\nresolving dependencies...\n".utf8))

        let snapshot = recorder.snapshot(
            hostAlias: "arch",
            subtitle: "demo@arch:22",
            connectionState: .connected,
            cwdGuess: "~",
            shellHint: "zsh",
            osHint: "Arch",
            userRoleHint: "standard user"
        )

        #expect(lines == ["resolving dependencies..."])
        #expect(snapshot.lastCommand == "pacman")
        #expect(snapshot.ringBuffer.tailLines == ["resolving dependencies..."])
    }

    @Test func redactionRemovesSecretsFromSnapshot() {
        var recorder = SessionRecorder()
        recorder.recordOutputLines([
            "Authorization: Bearer sk-1234567890abcdef",
            "DATABASE_URL=postgres://user:password@example.com/app",
            "token=abc123456"
        ])

        let snapshot = recorder.snapshot(
            hostAlias: "demo",
            subtitle: "root@example:22",
            connectionState: .connected,
            cwdGuess: "~",
            shellHint: "bash",
            osHint: "Ubuntu",
            userRoleHint: "root"
        )
        let redacted = RedactionService.redact(snapshot)
        let joined = (redacted.ringBuffer.headLines + redacted.ringBuffer.tailLines).joined(separator: "\n")

        #expect(!joined.contains("sk-1234567890abcdef"))
        #expect(!joined.contains("password@example.com"))
        #expect(!joined.contains("abc123456"))
        #expect(redacted.ringBuffer.redactionSummary.total >= 3)
    }

    @Test func riskEvaluatorEscalatesDestructiveCommands() {
        let proposal = CommandProposal(
            command: "sudo rm -rf /var/www/releases/old",
            explanation: "Clean old release files.",
            expectedEffect: "Old release files are removed.",
            riskLevel: .low,
            requiresSudo: true,
            destructive: false,
            provider: .openAI
        )

        let normalized = CommandRiskEvaluator.normalizedProposal(proposal)

        #expect(normalized.riskLevel == .high)
        #expect(normalized.destructive)
    }

    @Test func controlKeyBytesMatchPTYExpectations() {
        #expect(TerminalControlKey.enter.bytes == Data([13]))
        #expect(TerminalControlKey.backspace.bytes == Data([127]))
        #expect(TerminalControlKey.tab.bytes == Data([9]))
        #expect(TerminalControlKey.escape.bytes == Data([27]))
        #expect(TerminalControlKey.controlC.bytes == Data([3]))
        #expect(TerminalControlKey.controlD.bytes == Data([4]))
        #expect(TerminalControlKey.up.bytes == Data("\u{1B}[A".utf8))
        #expect(TerminalControlKey.down.bytes == Data("\u{1B}[B".utf8))
        #expect(TerminalControlKey.right.bytes == Data("\u{1B}[C".utf8))
        #expect(TerminalControlKey.left.bytes == Data("\u{1B}[D".utf8))
    }

    @Test func mockDriverEmitsEventStreamOutput() async throws {
        let driver = MockSSHDriver()
        let eventTask = Task {
            var sawConnected = false
            var sawPTY = false
            var output = Data()

            for await event in driver.events {
                switch event {
                case .connected:
                    sawConnected = true
                case .ptyStarted:
                    sawPTY = true
                case .output(let data):
                    output.append(data)
                default:
                    break
                }
            }

            return (sawConnected, sawPTY, String(decoding: output, as: UTF8.self))
        }

        try await driver.connect(config: SSHConnectionConfig(
            host: "mock",
            username: "demo",
            auth: .password("secret")
        ))
        try await driver.startPTY(term: "xterm-256color", columns: 80, rows: 24)
        try await driver.write(Data("whoami\r".utf8))
        await driver.disconnect()

        let result = await eventTask.value
        #expect(result.0)
        #expect(result.1)
        #expect(result.2.contains("demo"))
    }

    @Test func controllerWritesInputAndTracksOutputWithoutRetainedReplay() async throws {
        let driver = SpySSHDriver()
        var outputChunks: [TerminalOutputChunk] = []
        var retainedLines: [String] = []
        var submittedCommands: [String] = []

        let controller = TerminalSessionController(
            sessionID: UUID(),
            driver: driver,
            eventHandler: { _, _ in },
            outputHandler: { _, chunk, lines, _ in
                outputChunks.append(chunk)
                retainedLines.append(contentsOf: lines)
            },
            inputHandler: { _, records, _ in
                submittedCommands.append(contentsOf: records.map(\.command))
            }
        )

        await controller.open(config: SSHConnectionConfig(
            host: "example.com",
            username: "demo",
            auth: .password("secret")
        ))
        controller.submitCommand("pwd", source: .user)
        try await Task.sleep(nanoseconds: 50_000_000)
        driver.emit(.output(Data("/home/demo\r\n".utf8)))

        #expect(driver.writtenData == [Data("pwd\r".utf8)])
        #expect(submittedCommands == ["pwd"])
        #expect(outputChunks.map(\.data) == [Data("/home/demo\r\n".utf8)])
        #expect(retainedLines == ["/home/demo"])
    }
}

private final class SpySSHDriver: SSHSessionDriver {
    private let eventStream: AsyncStream<SSHSessionEvent>
    private var eventContinuation: AsyncStream<SSHSessionEvent>.Continuation?
    private(set) var writtenData: [Data] = []
    private(set) var resizeEvents: [(columns: Int, rows: Int)] = []

    var events: AsyncStream<SSHSessionEvent> {
        eventStream
    }

    init() {
        var continuation: AsyncStream<SSHSessionEvent>.Continuation?
        eventStream = AsyncStream { continuation = $0 }
        eventContinuation = continuation
    }

    func connect(config: SSHConnectionConfig) async throws {
        emit(.connecting)
        emit(.connected)
    }

    func startPTY(term: String, columns: Int, rows: Int) async throws {
        emit(.ptyStarted)
    }

    func write(_ data: Data) async throws {
        writtenData.append(data)
    }

    func resize(columns: Int, rows: Int) async throws {
        resizeEvents.append((columns, rows))
        emit(.resized(columns: columns, rows: rows))
    }

    func disconnect() async {
        eventContinuation?.finish()
    }

    func emit(_ event: SSHSessionEvent) {
        eventContinuation?.yield(event)
    }
}
