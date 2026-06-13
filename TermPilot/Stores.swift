import Foundation
import Observation
import Security
import SwiftData
import SwiftUI

@Observable
final class TabRouter {
    var selectedTab: AppTab = .vaults
    var vaultsPath = NavigationPath()
    var terminalsPath = NavigationPath()
    var settingsPath = NavigationPath()
    private(set) var lastOpenedSettingsRoute: SettingsRoute?

    func select(_ tab: AppTab) {
        if selectedTab == tab {
            popToRoot(tab)
        } else {
            selectedTab = tab
        }
    }

    func openSettingsAPIKeys() {
        selectedTab = .settings
        settingsPath = NavigationPath()
        openSettingsRoute(.apiKeys)
    }

    func openSettingsAPIKey(for provider: AIProvider) {
        selectedTab = .settings
        settingsPath = NavigationPath()
        openSettingsRoute(.apiKey(provider))
    }

    func openTerminalSession(_ id: UUID) {
        selectedTab = .terminals
        terminalsPath.append(TerminalsRoute.session(id))
    }

    func popToRoot(_ tab: AppTab) {
        switch tab {
        case .vaults:
            vaultsPath = NavigationPath()
        case .terminals:
            terminalsPath = NavigationPath()
        case .settings:
            settingsPath = NavigationPath()
            lastOpenedSettingsRoute = nil
        }
    }

    private func openSettingsRoute(_ route: SettingsRoute) {
        lastOpenedSettingsRoute = route
        settingsPath.append(route)
    }
}

final class TerminalSessionController {
    typealias EventHandler = (UUID, SSHSessionEvent) -> Void
    typealias OutputHandler = (UUID, TerminalOutputChunk, [String], SessionRecorder) -> Void
    typealias InputHandler = (UUID, [SessionCommandRecord], SessionRecorder) -> Void

    let sessionID: UUID

    private let driver: any SSHSessionDriver
    private let eventHandler: EventHandler
    private let outputHandler: OutputHandler
    private let inputHandler: InputHandler
    private var recorder = SessionRecorder()
    private var store = TerminalSessionStore()
    private var eventTask: Task<Void, Never>?
    private var lastColumns = 80
    private var lastRows = 24

    init(
        sessionID: UUID,
        driver: any SSHSessionDriver,
        eventHandler: @escaping EventHandler,
        outputHandler: @escaping OutputHandler,
        inputHandler: @escaping InputHandler
    ) {
        self.sessionID = sessionID
        self.driver = driver
        self.eventHandler = eventHandler
        self.outputHandler = outputHandler
        self.inputHandler = inputHandler
    }

    func open(config: SSHConnectionConfig) async {
        startEventLoop()
        lastColumns = config.initialColumns
        lastRows = config.initialRows

        do {
            try await driver.connect(config: config)
            try await driver.startPTY(
                term: config.term,
                columns: config.initialColumns,
                rows: config.initialRows
            )
        } catch {
            await MainActor.run {
                consume(.failed(SSHSessionError.map(error)))
            }
        }
    }

    func sendKeyboardBytes(_ data: Data, source: TerminalInputSource = .user) {
        let submittedCommands = recorder.recordInput(data, source: source)
        inputHandler(sessionID, submittedCommands, recorder)

        Task { [weak self, driver] in
            do {
                try await driver.write(data)
            } catch {
                await MainActor.run {
                    self?.consume(.failed(SSHSessionError.map(error)))
                }
            }
        }
    }

    func replaceCurrentInputLine(_ input: String) {
        recorder.replaceCurrentInputLine(input)
        inputHandler(sessionID, [], recorder)
    }

    func submitCommand(_ command: String, source: TerminalInputSource) {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { return }

        let data = Data((trimmedCommand + "\r").utf8)
        let submittedCommands = recorder.recordInput(data, source: source)
        inputHandler(sessionID, submittedCommands, recorder)

        Task { [weak self, driver] in
            do {
                try await driver.write(data)
            } catch {
                await MainActor.run {
                    self?.consume(.failed(SSHSessionError.map(error)))
                }
            }
        }
    }

    func resize(columns: Int, rows: Int) {
        let columns = max(columns, 1)
        let rows = max(rows, 1)
        guard columns != lastColumns || rows != lastRows else { return }
        lastColumns = columns
        lastRows = rows

        Task { [weak self, driver] in
            do {
                try await driver.resize(columns: columns, rows: rows)
            } catch {
                await MainActor.run {
                    self?.consume(.failed(SSHSessionError.map(error)))
                }
            }
        }
    }

    func disconnect() {
        eventTask?.cancel()
        eventTask = nil
        Task { [driver] in
            await driver.disconnect()
        }
    }

    func clearBuffers() {
        store.clear()
        recorder.clearOutput()
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
        recorder.snapshot(
            hostAlias: hostAlias,
            subtitle: subtitle,
            connectionState: connectionState,
            cwdGuess: cwdGuess,
            shellHint: shellHint,
            osHint: osHint,
            userRoleHint: userRoleHint
        )
    }

    private func startEventLoop() {
        eventTask?.cancel()
        eventTask = Task { [weak self, driver] in
            for await event in driver.events {
                await MainActor.run {
                    self?.consume(event)
                }
            }
        }
    }

    private func consume(_ event: SSHSessionEvent) {
        switch event {
        case .output(let data):
            guard let chunk = store.appendRemoteData(data) else { return }
            let completedLines = recorder.recordOutput(data)
            outputHandler(sessionID, chunk, completedLines, recorder)
        default:
            eventHandler(sessionID, event)
        }
    }
}

@Observable
final class TerminalSessionManager {
    static let retainedLogLineLimit = 500

    var sessions: [TerminalSession] = []
    @ObservationIgnored private var controllers: [UUID: TerminalSessionController] = [:]
    @ObservationIgnored private var sessionConfigs: [UUID: SSHConnectionConfig] = [:]

    var activeCount: Int {
        sessions.filter { $0.state == .connecting || $0.state == .connected }.count
    }

    var activeBadgeLabel: String? {
        switch activeCount {
        case 0:
            return nil
        case 100...:
            return "99+"
        case let count:
            return "\(count)"
        }
    }

    var visibleSessions: [TerminalSession] {
        sessions
            .filter { $0.state != .closed }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    func createConnectingSession(for host: HostProfile) -> UUID {
        let id = UUID()
        let session = TerminalSession(
            id: id,
            hostID: host.id,
            vaultID: host.vaultID,
            title: host.alias,
            subtitle: "\(host.username)@\(host.host):\(host.port)",
            state: .connecting,
            userRoleHint: host.username == "root" ? "root" : "standard user"
        )
        sessions.insert(session, at: 0)
        host.lastConnectedAt = .now
        host.updatedAt = .now
        scheduleConnectingWatchdog(for: id)
        return id
    }

    func startMockSession(for host: HostProfile) -> UUID {
        let id = createConnectingSession(for: host)
        let config = SSHConnectionConfig(
            host: host.host,
            port: host.port,
            username: host.username,
            auth: .password("mock")
        )
        openSession(id, config: config, driver: MockSSHDriver())
        return id
    }

    func openSession(
        _ id: UUID,
        config: SSHConnectionConfig,
        driver: (any SSHSessionDriver)? = nil
    ) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        sessionConfigs[id] = config
        let controller = makeController(
            sessionID: id,
            driver: driver ?? makeProductionDriver()
        )
        controllers[id] = controller
        updateSessionState(.connecting, for: id)

        Task {
            await controller.open(config: config)
        }
    }

    func failSession(_ id: UUID, message: String) {
        apply(.failed(.connectionFailed(message)), to: id)
    }

    func noteSessionStatus(_ id: UUID, message: String) {
        apply(.status(message), to: id)
    }

    func session(with id: UUID) -> TerminalSession? {
        sessions.first { $0.id == id }
    }

    func close(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].state = .closed
        sessions[index].lastActivityAt = .now
        controllers[id]?.disconnect()
        controllers[id] = nil
        sessionConfigs[id] = nil
    }

    func closeVisibleSessions() {
        for index in sessions.indices where sessions[index].state != .closed {
            controllers[sessions[index].id]?.disconnect()
            controllers[sessions[index].id] = nil
            sessionConfigs[sessions[index].id] = nil
            sessions[index].state = .closed
            sessions[index].lastActivityAt = .now
        }
    }

    func closeSessions(forVaultID vaultID: UUID) {
        for index in sessions.indices where sessions[index].vaultID == vaultID {
            controllers[sessions[index].id]?.disconnect()
            controllers[sessions[index].id] = nil
            sessionConfigs[sessions[index].id] = nil
            sessions[index].state = .closed
            sessions[index].lastActivityAt = .now
        }
    }

    func closeSessions(forHostID hostID: UUID) {
        for index in sessions.indices where sessions[index].hostID == hostID {
            controllers[sessions[index].id]?.disconnect()
            controllers[sessions[index].id] = nil
            sessionConfigs[sessions[index].id] = nil
            sessions[index].state = .closed
            sessions[index].lastActivityAt = .now
        }
    }

    func clearRetainedLog(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].retainedLog.removeAll()
        sessions[index].terminalOutputChunks.removeAll()
        sessions[index].lastActivityAt = .now
        controllers[id]?.clearBuffers()
    }

    func appendRetainedLog(_ lines: [String], to id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }), !lines.isEmpty else { return }
        sessions[index].retainedLog.append(contentsOf: lines)
        trimRetainedLog(at: index)
        sessions[index].lastActivityAt = .now
    }

    func appendRetainedLog(_ line: String, to id: UUID) {
        appendRetainedLog([line], to: id)
    }

    func clearRetainedLogs() {
        for index in sessions.indices where sessions[index].state != .closed {
            controllers[sessions[index].id]?.clearBuffers()
            sessions[index].retainedLog.removeAll()
            sessions[index].terminalOutputChunks.removeAll()
            sessions[index].lastActivityAt = .now
        }
    }

    func reconnect(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        guard let config = sessionConfigs[id] else {
            sessions[index].state = .failed
            appendRetainedLog("Reconnect failed: missing connection configuration.", to: id)
            return
        }
        controllers[id]?.disconnect()
        openSession(id, config: config)
    }

    func clearAll() {
        for controller in controllers.values {
            controller.disconnect()
        }
        sessions.removeAll()
        controllers.removeAll()
        sessionConfigs.removeAll()
    }

    func setMode(_ mode: TerminalMode, for id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].terminalMode = mode
    }

    func updateTerminalInput(_ input: String, for id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].currentInput = input
        controllers[id]?.replaceCurrentInputLine(input)
    }

    func updateChatDraft(_ draft: String, for id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].chatDraft = draft
    }

    func sendControlKey(_ key: TerminalControlKey, to id: UUID) {
        controllers[id]?.sendKeyboardBytes(key.bytes)
    }

    func receiveTerminalInputData(_ data: Data, for id: UUID) {
        controllers[id]?.sendKeyboardBytes(data)
    }

    func submitCurrentInput(for id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let command = sessions[index].currentInput
        sessions[index].currentInput.removeAll()
        controllers[id]?.submitCommand(command, source: .user)
    }

    func resizeTerminal(columns: Int, rows: Int, for id: UUID) {
        controllers[id]?.resize(columns: columns, rows: rows)
    }

    func contextSnapshot(for id: UUID) -> SessionContextSnapshot? {
        guard let session = session(with: id) else { return nil }
        if let controller = controllers[id] {
            return controller.snapshot(
                hostAlias: session.title,
                subtitle: session.subtitle,
                connectionState: session.state,
                cwdGuess: session.cwdGuess,
                shellHint: session.shellHint,
                osHint: session.osHint,
                userRoleHint: session.userRoleHint
            )
        }

        var fallbackRecorder = SessionRecorder()
        fallbackRecorder.recordOutputLines(session.retainedLog)
        return fallbackRecorder.snapshot(
            hostAlias: session.title,
            subtitle: session.subtitle,
            connectionState: session.state,
            cwdGuess: session.cwdGuess,
            shellHint: session.shellHint,
            osHint: session.osHint,
            userRoleHint: session.userRoleHint
        )
    }

    func sendChatMessage(
        to id: UUID,
        text: String,
        provider: AIProvider,
        configuration: LLMProviderConfiguration,
        secureSecretStore: SecureSecretStore
    ) async throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        guard let snapshot = contextSnapshot(for: id) else { return }

        let apiKey = try await secureSecretStore.loadAPIKey(for: provider)
        guard let apiKey, !apiKey.isEmpty else {
            throw AIChatServiceError.missingAPIKey(provider)
        }

        let history = sessions[index].chatMessages
        sessions[index].chatDraft = ""
        sessions[index].chatError = nil
        sessions[index].isAwaitingAIResponse = true
        sessions[index].chatMessages.append(AIChatMessage(role: .user, content: trimmedText))

        do {
            let result = try await AIChatService.sendMessage(
                text: trimmedText,
                history: history,
                snapshot: snapshot,
                provider: provider,
                apiKey: apiKey,
                configuration: configuration
            )
            guard let updatedIndex = sessions.firstIndex(where: { $0.id == id }) else { return }
            sessions[updatedIndex].chatMessages.append(result.message)
            sessions[updatedIndex].isAwaitingAIResponse = false
            sessions[updatedIndex].lastActivityAt = .now
        } catch {
            guard let updatedIndex = sessions.firstIndex(where: { $0.id == id }) else { return }
            sessions[updatedIndex].chatError = error.localizedDescription
            sessions[updatedIndex].isAwaitingAIResponse = false
            throw error
        }
    }

    func pendingProposal(in id: UUID) -> CommandProposal? {
        guard let session = session(with: id) else { return nil }
        for message in session.chatMessages.reversed() {
            if let proposal = message.commandProposals.last(where: { $0.status == .pending }) {
                return proposal
            }
        }
        return nil
    }

    private func continueConversation(
        for id: UUID,
        provider: AIProvider,
        configuration: LLMProviderConfiguration,
        secureSecretStore: SecureSecretStore
    ) async throws {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        guard let snapshot = contextSnapshot(for: id) else { return }

        let apiKey = try await secureSecretStore.loadAPIKey(for: provider)
        guard let apiKey, !apiKey.isEmpty else {
            throw AIChatServiceError.missingAPIKey(provider)
        }

        sessions[index].chatError = nil
        sessions[index].isAwaitingAIResponse = true

        do {
            let result = try await AIChatService.continueConversation(
                history: sessions[index].chatMessages,
                snapshot: snapshot,
                provider: provider,
                apiKey: apiKey,
                configuration: configuration
            )
            guard let updatedIndex = sessions.firstIndex(where: { $0.id == id }) else { return }
            sessions[updatedIndex].chatMessages.append(result.message)
            sessions[updatedIndex].isAwaitingAIResponse = false
            sessions[updatedIndex].lastActivityAt = .now
        } catch {
            guard let updatedIndex = sessions.firstIndex(where: { $0.id == id }) else { return }
            sessions[updatedIndex].chatError = error.localizedDescription
            sessions[updatedIndex].isAwaitingAIResponse = false
            throw error
        }
    }

    func requestDiagnosis(
        for id: UUID,
        provider: AIProvider,
        configuration: LLMProviderConfiguration,
        secureSecretStore: SecureSecretStore
    ) async throws {
        guard let snapshot = contextSnapshot(for: id) else { return }
        try await sendChatMessage(
            to: id,
            text: AIChatService.diagnosisPrompt(for: snapshot),
            provider: provider,
            configuration: configuration,
            secureSecretStore: secureSecretStore
        )
        setMode(.chat, for: id)
    }

    func runProposal(
        _ proposalID: UUID,
        in id: UUID,
        provider: AIProvider,
        configuration: LLMProviderConfiguration,
        secureSecretStore: SecureSecretStore
    ) async throws {
        guard
            let index = sessions.firstIndex(where: { $0.id == id }),
            let proposalLocation = proposalLocation(proposalID, in: sessions[index])
        else {
            return
        }

        let proposal = sessions[index]
            .chatMessages[proposalLocation.messageIndex]
            .commandProposals[proposalLocation.proposalIndex]
        var approved = LLMExecutionBridge.approve(proposal)
        approved.proposal.status = .approved
        sessions[index]
            .chatMessages[proposalLocation.messageIndex]
            .commandProposals[proposalLocation.proposalIndex] = approved.proposal

        let transcriptBaseline = sessions[index].retainedLog.count
        controllers[id]?.submitCommand(approved.proposal.command, source: .aiApproved)
        sessions[index].isAwaitingAIResponse = true

        try? await Task.sleep(for: .seconds(Self.executionTranscriptWindow))

        guard let updatedIndex = sessions.firstIndex(where: { $0.id == id }) else { return }
        let transcript = executionTranscript(at: updatedIndex, baseline: transcriptBaseline)
        sessions[updatedIndex]
            .chatMessages[proposalLocation.messageIndex]
            .commandProposals[proposalLocation.proposalIndex]
            .executionTranscript = transcript

        var metadata = approved.metadata
        metadata.transcriptSummary = transcript.isEmpty
            ? "Command submitted. No output captured within the transcript window."
            : transcript
        metadata.finishedAt = .now
        sessions[updatedIndex].chatMessages.append(
            AIChatMessage(
                role: .execution,
                content: metadata.transcriptSummary,
                executionResults: [metadata]
            )
        )

        do {
            try await continueConversation(
                for: id,
                provider: provider,
                configuration: configuration,
                secureSecretStore: secureSecretStore
            )
        } catch {
            if let stuckIndex = sessions.firstIndex(where: { $0.id == id }) {
                sessions[stuckIndex].isAwaitingAIResponse = false
            }
            throw error
        }
    }

    func rejectProposal(
        _ proposalID: UUID,
        in id: UUID,
        feedback: String?,
        provider: AIProvider,
        configuration: LLMProviderConfiguration,
        secureSecretStore: SecureSecretStore
    ) async throws {
        guard
            let index = sessions.firstIndex(where: { $0.id == id }),
            let proposalLocation = proposalLocation(proposalID, in: sessions[index])
        else {
            return
        }

        let trimmedFeedback = feedback?.trimmingCharacters(in: .whitespacesAndNewlines)
        sessions[index]
            .chatMessages[proposalLocation.messageIndex]
            .commandProposals[proposalLocation.proposalIndex]
            .status = .rejected
        sessions[index]
            .chatMessages[proposalLocation.messageIndex]
            .commandProposals[proposalLocation.proposalIndex]
            .userFeedback = (trimmedFeedback?.isEmpty == false) ? trimmedFeedback : nil
        sessions[index].lastActivityAt = .now

        if trimmedFeedback?.isEmpty == false {
            try await continueConversation(
                for: id,
                provider: provider,
                configuration: configuration,
                secureSecretStore: secureSecretStore
            )
        }
    }

    private static let executionTranscriptWindow: Double = 2.5
    private static let executionTranscriptLineLimit = 40

    private func executionTranscript(at index: Int, baseline: Int) -> String {
        let log = sessions[index].retainedLog
        guard log.count > baseline else { return "" }
        var lines = Array(log.suffix(log.count - baseline))
        if lines.count > Self.executionTranscriptLineLimit {
            let dropped = lines.count - Self.executionTranscriptLineLimit
            lines = ["[... \(dropped) earlier lines omitted ...]"] + lines.suffix(Self.executionTranscriptLineLimit)
        }
        return RedactionService.redact(lines.joined(separator: "\n"))
    }

    func editProposal(_ proposalID: UUID, in id: UUID) {
        guard
            let index = sessions.firstIndex(where: { $0.id == id }),
            let proposalLocation = proposalLocation(proposalID, in: sessions[index])
        else {
            return
        }

        let proposal = sessions[index]
            .chatMessages[proposalLocation.messageIndex]
            .commandProposals[proposalLocation.proposalIndex]
        sessions[index].currentInput = proposal.command
        controllers[id]?.replaceCurrentInputLine(proposal.command)
        sessions[index].terminalMode = .raw
    }

    private func trimRetainedLog(at index: Int) {
        let overflow = sessions[index].retainedLog.count - Self.retainedLogLineLimit
        guard overflow > 0 else { return }
        sessions[index].retainedLog.removeFirst(overflow)
    }

    private func scheduleConnectingWatchdog(for id: UUID) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard
                let self,
                let index = sessions.firstIndex(where: { $0.id == id }),
                sessions[index].state == .connecting
            else {
                return
            }

            let lastStatus = sessions[index].retainedLog.last
            let message = lastStatus.map { "Connection timed out. Last status: \($0)" } ?? "Connection timed out."
            apply(.failed(.unknown(message)), to: id)
            controllers[id]?.disconnect()
        }
    }

    private func makeController(
        sessionID: UUID,
        driver: any SSHSessionDriver
    ) -> TerminalSessionController {
        TerminalSessionController(
            sessionID: sessionID,
            driver: driver,
            eventHandler: { [weak self] id, event in
                self?.apply(event, to: id)
            },
            outputHandler: { [weak self] id, chunk, lines, recorder in
                self?.appendOutput(chunk: chunk, completedLines: lines, recorder: recorder, to: id)
            },
            inputHandler: { [weak self] id, records, recorder in
                self?.applyInput(records: records, recorder: recorder, to: id)
            }
        )
    }

    private func makeProductionDriver() -> any SSHSessionDriver {
        #if canImport(Citadel)
        CitadelSSHSessionDriver()
        #else
        MockSSHDriver()
        #endif
    }

    private func apply(_ event: SSHSessionEvent, to id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }

        switch event {
        case .status(let message):
            sessions[index].retainedLog.append(message)
            trimRetainedLog(at: index)
        case .connecting, .authenticating:
            sessions[index].state = .connecting
        case .connected, .ptyStarted:
            sessions[index].state = .connected
        case .resized:
            break
        case .disconnected(let reason):
            guard sessions[index].state != .failed, sessions[index].state != .closed else {
                return
            }
            sessions[index].state = .disconnected
            if let reason, !reason.isEmpty {
                sessions[index].retainedLog.append("Disconnected: \(reason)")
                trimRetainedLog(at: index)
            }
        case .failed(let error):
            sessions[index].state = .failed
            sessions[index].retainedLog.append(error.localizedDescription)
            trimRetainedLog(at: index)
        case .output:
            break
        }
        sessions[index].lastActivityAt = .now
    }

    private func appendOutput(
        chunk: TerminalOutputChunk,
        completedLines: [String],
        recorder: SessionRecorder,
        to id: UUID
    ) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }

        sessions[index].terminalOutputChunks.append(chunk)
        sessions[index].retainedLog.append(contentsOf: completedLines)
        sessions[index].lastCommand = recorder.lastCommand
        trimOutputChunks(at: index)
        trimRetainedLog(at: index)
        sessions[index].lastActivityAt = .now
    }

    private func applyInput(
        records: [SessionCommandRecord],
        recorder: SessionRecorder,
        to id: UUID
    ) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].currentInput = recorder.currentInputLine
        if let lastCommand = records.last?.command {
            sessions[index].lastCommand = lastCommand
        }
        sessions[index].lastActivityAt = .now
    }

    private func updateSessionState(_ state: TerminalSessionState, for id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].state = state
        sessions[index].lastActivityAt = .now
    }

    private func trimOutputChunks(at index: Int) {
        let overflow = sessions[index].terminalOutputChunks.count - 2_000
        guard overflow > 0 else { return }
        sessions[index].terminalOutputChunks.removeFirst(overflow)
    }

    private func proposalLocation(_ proposalID: UUID, in session: TerminalSession) -> (messageIndex: Int, proposalIndex: Int)? {
        for messageIndex in session.chatMessages.indices {
            if let proposalIndex = session.chatMessages[messageIndex].commandProposals.firstIndex(where: { $0.id == proposalID }) {
                return (messageIndex, proposalIndex)
            }
        }
        return nil
    }
}

protocol VaultSecretStoring {
    func saveVaultSecret(_ secret: String, account: String) async throws
    func loadVaultSecret(account: String) async throws -> String?
    func deleteVaultSecret(account: String) async throws
}

@Observable
final class SecureSecretStore: VaultSecretStoring {
    private let service = "ttest.TermPilot.secrets"

    func saveAPIKey(_ key: String, for provider: AIProvider) async throws {
        try await save(key, account: provider.keychainAccount)
    }

    func loadAPIKey(for provider: AIProvider) async throws -> String? {
        try await load(account: provider.keychainAccount)
    }

    func deleteAPIKey(for provider: AIProvider) async throws {
        try await delete(account: provider.keychainAccount)
    }

    func hasAPIKey(for provider: AIProvider) async -> Bool {
        guard let key = try? await loadAPIKey(for: provider) else { return false }
        return !key.isEmpty
    }

    func saveVaultSecret(_ secret: String, account: String) async throws {
        try await save(secret, account: account)
    }

    func loadVaultSecret(account: String) async throws -> String? {
        try await load(account: account)
    }

    func deleteVaultSecret(account: String) async throws {
        try await delete(account: account)
    }

    func deleteAll() async throws {
        let service = service
        try await Task.detached {
            try KeychainClient.deleteAll(service: service)
        }.value
    }

    private func save(_ value: String, account: String) async throws {
        let service = service
        let data = Data(value.utf8)
        try await Task.detached {
            try KeychainClient.save(data, service: service, account: account)
        }.value
    }

    private func load(account: String) async throws -> String? {
        let service = service
        return try await Task.detached {
            guard let data = try KeychainClient.load(service: service, account: account) else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }.value
    }

    private func delete(account: String) async throws {
        let service = service
        try await Task.detached {
            try KeychainClient.delete(service: service, account: account)
        }.value
    }
}

enum KeychainClient {
    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)
        case decodingFailed

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                "Keychain operation failed with status \(status)."
            case .decodingFailed:
                "Keychain returned data in an unexpected format."
            }
        }
    }

    nonisolated static func save(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    nonisolated static func load(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainError.decodingFailed
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    nonisolated static func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    nonisolated static func deleteAll(service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

enum LocalDataWipeService {
    @MainActor
    static func wipeVaultMetadata(in modelContext: ModelContext) throws {
        do {
            for host in try modelContext.fetch(FetchDescriptor<HostProfile>()) {
                modelContext.delete(host)
            }
            for item in try modelContext.fetch(FetchDescriptor<KeychainItemProfile>()) {
                modelContext.delete(item)
            }
            for snippet in try modelContext.fetch(FetchDescriptor<SnippetProfile>()) {
                modelContext.delete(snippet)
            }
            for vault in try modelContext.fetch(FetchDescriptor<VaultProfile>()) {
                modelContext.delete(vault)
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}
