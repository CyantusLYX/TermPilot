import SwiftUI
import TipKit

struct TerminalsView: View {
    @Environment(TerminalSessionManager.self) private var terminalSessionManager
    @State private var isConfirmingCloseAll = false
    @AppStorage("terminalsSortOption") private var sortOptionRawValue = TerminalSessionSortOption.recentActivity.rawValue

    private var sortOption: TerminalSessionSortOption {
        SortOptionStorage.value(from: sortOptionRawValue, default: .recentActivity)
    }

    private var visibleSessions: [TerminalSession] {
        ProfileSorting.sortTerminalSessions(terminalSessionManager.visibleSessions, by: sortOption)
    }

    var body: some View {
        List {
            if visibleSessions.isEmpty {
                ContentUnavailableView(
                    "No Active Terminals",
                    systemImage: "terminal",
                    description: Text("Start a host from Vaults to create a terminal session.")
                )
            } else {
                ForEach(visibleSessions) { session in
                    NavigationLink(value: TerminalsRoute.session(session.id)) {
                        TerminalSessionRow(session: session)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            terminalSessionManager.close(session.id)
                        } label: {
                            Label("Close", systemImage: "xmark")
                        }

                        Button {
                            terminalSessionManager.clearRetainedLog(session.id)
                        } label: {
                            Label("Clear Log", systemImage: "text.badge.minus")
                        }
                        .tint(.orange)

                        Button {
                            terminalSessionManager.reconnect(session.id)
                        } label: {
                            Label("Reconnect", systemImage: "arrow.clockwise")
                        }
                        .tint(.blue)
                    }
                }
            }
        }
        .navigationTitle("Terminals")
        .toolbar {
            if !visibleSessions.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort By", selection: $sortOptionRawValue.sortOption(TerminalSessionSortOption.self, default: .recentActivity)) {
                            ForEach(Array(TerminalSessionSortOption.allCases), id: \.id) { option in
                                Label(option.title, systemImage: option.systemImage)
                                    .tag(option)
                            }
                        }

                        Button {
                            terminalSessionManager.clearRetainedLogs()
                        } label: {
                            Label("Clear Retained Logs", systemImage: "text.badge.minus")
                        }

                        Button(role: .destructive) {
                            isConfirmingCloseAll = true
                        } label: {
                            Label("Close All Terminals", systemImage: "xmark.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .confirmationDialog(
            "Close all terminals?",
            isPresented: $isConfirmingCloseAll,
            titleVisibility: .visible
        ) {
            Button("Close All Terminals", role: .destructive) {
                terminalSessionManager.closeVisibleSessions()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes active and retained terminal sessions from the Terminals tab.")
        }
    }
}

private struct TerminalSessionRow: View {
    let session: TerminalSession

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(session.state.color)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.headline)
                Text(session.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(session.state.title)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if !session.retainedLog.isEmpty {
                    Text("\(session.retainedLog.count) retained log lines")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct TerminalPlaceholderView: View {
    @Environment(TerminalSessionManager.self) private var terminalSessionManager
    @Environment(TabRouter.self) private var router
    @Environment(SecureSecretStore.self) private var secureSecretStore
    @AppStorage("terminalFontSize") private var terminalFontSize = 14.0
    @AppStorage("selectedAIProvider") private var selectedAIProviderRawValue = AIProvider.openAI.rawValue
    @AppStorage("openAIBaseURL") private var openAIBaseURL = LLMProviderConfiguration.defaultOpenAIBaseURLString
    @AppStorage("openAIModelID") private var openAIModelID = LLMProviderConfiguration.defaultOpenAIModelID
    @AppStorage("geminiBaseURL") private var geminiBaseURL = LLMProviderConfiguration.defaultGeminiBaseURLString
    @AppStorage("geminiModelID") private var geminiModelID = LLMProviderConfiguration.defaultGeminiModelID

    @State private var missingAPIKeyProvider: AIProvider?
    @State private var transientError: String?

    @State private var introGuide = TipGroup(.ordered) {
        ModeSwitchTip()
        DiagnoseTip()
    }

    let sessionID: UUID

    private var selectedProvider: AIProvider {
        AIProvider(rawValue: selectedAIProviderRawValue) ?? .openAI
    }

    private var providerConfiguration: LLMProviderConfiguration {
        let baseURLString: String
        let modelID: String
        switch selectedProvider {
        case .openAI:
            baseURLString = openAIBaseURL
            modelID = openAIModelID
        case .gemini:
            baseURLString = geminiBaseURL
            modelID = geminiModelID
        case .anthropic:
            baseURLString = ""
            modelID = ""
        }

        return LLMProviderConfiguration(
            provider: selectedProvider,
            baseURLString: baseURLString,
            modelID: modelID
        )
    }

    var body: some View {
        if let session = terminalSessionManager.session(with: sessionID) {
            VStack(spacing: 0) {
                TerminalWorkspaceHeader(session: session)

                Picker("Mode", selection: Binding(
                    get: { terminalSessionManager.session(with: sessionID)?.terminalMode ?? .raw },
                    set: { mode in
                        if let modeSwitchTip = introGuide.currentTip as? ModeSwitchTip {
                            modeSwitchTip.invalidate(reason: .actionPerformed)
                        }
                        terminalSessionManager.setMode(mode, for: sessionID)
                    }
                )) {
                    ForEach(TerminalMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .popoverTip(introGuide.currentTip as? ModeSwitchTip)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)

                if let transientError {
                    Text(transientError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                        .background(.red.opacity(0.08))
                }

                Group {
                    switch session.terminalMode {
                    case .raw:
                        RawTerminalWorkspace(
                            session: session,
                            terminalFontSize: terminalFontSize,
                            input: Binding(
                                get: { terminalSessionManager.session(with: sessionID)?.currentInput ?? "" },
                                set: { terminalSessionManager.updateTerminalInput($0, for: sessionID) }
                            ),
                            onSubmit: {
                                terminalSessionManager.submitCurrentInput(for: sessionID)
                            },
                            onControlKey: { key in
                                terminalSessionManager.sendControlKey(key, to: sessionID)
                            },
                            onInputData: { data in
                                terminalSessionManager.receiveTerminalInputData(data, for: sessionID)
                            },
                            onResize: { columns, rows in
                                terminalSessionManager.resizeTerminal(columns: columns, rows: rows, for: sessionID)
                            }
                        )
                    case .chat:
                        ChatTerminalWorkspace(
                            session: session,
                            draft: Binding(
                                get: { terminalSessionManager.session(with: sessionID)?.chatDraft ?? "" },
                                set: { terminalSessionManager.updateChatDraft($0, for: sessionID) }
                            ),
                            pendingProposal: terminalSessionManager.pendingProposal(in: sessionID),
                            onSend: { text in
                                sendChatMessage(text)
                            },
                            onRunProposal: { proposalID in
                                runProposal(proposalID)
                            },
                            onEditProposal: { proposalID in
                                terminalSessionManager.editProposal(proposalID, in: sessionID)
                            },
                            onRejectProposal: { proposalID, feedback in
                                rejectProposal(proposalID, feedback: feedback)
                            }
                        )
                    }
                }
            }
            .navigationTitle(session.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        if let diagnoseTip = introGuide.currentTip as? DiagnoseTip {
                            diagnoseTip.invalidate(reason: .actionPerformed)
                        }
                        requestDiagnosis()
                    } label: {
                        Label("Diagnose", systemImage: "stethoscope")
                    }
                    .disabled(session.isAwaitingAIResponse)
                    .popoverTip(introGuide.currentTip as? DiagnoseTip)

                    Menu {
                        Button {
                            terminalSessionManager.reconnect(sessionID)
                        } label: {
                            Label("Reconnect", systemImage: "arrow.clockwise")
                        }

                        Button {
                            terminalSessionManager.clearRetainedLog(sessionID)
                        } label: {
                            Label("Clear Log", systemImage: "text.badge.minus")
                        }

                        Button(role: .destructive) {
                            terminalSessionManager.close(sessionID)
                            router.terminalsPath.removeLast(router.terminalsPath.count)
                        } label: {
                            Label("Close", systemImage: "xmark")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(item: $missingAPIKeyProvider) { provider in
                MissingAPIKeySheet(provider: provider) {
                    missingAPIKeyProvider = nil
                    router.openSettingsAPIKey(for: provider)
                }
            }
        } else {
            ContentUnavailableView("Session Not Found", systemImage: "terminal")
        }
    }

    private func sendChatMessage(_ text: String) {
        transientError = nil
        Task {
            do {
                try await terminalSessionManager.sendChatMessage(
                    to: sessionID,
                    text: text,
                    provider: selectedProvider,
                    configuration: providerConfiguration,
                    secureSecretStore: secureSecretStore
                )
            } catch AIChatServiceError.missingAPIKey(let provider) {
                missingAPIKeyProvider = provider
            } catch {
                transientError = error.localizedDescription
            }
        }
    }

    private func runProposal(_ proposalID: UUID) {
        transientError = nil
        Task {
            do {
                try await terminalSessionManager.runProposal(
                    proposalID,
                    in: sessionID,
                    provider: selectedProvider,
                    configuration: providerConfiguration,
                    secureSecretStore: secureSecretStore
                )
            } catch AIChatServiceError.missingAPIKey(let provider) {
                missingAPIKeyProvider = provider
            } catch {
                transientError = error.localizedDescription
            }
        }
    }

    private func rejectProposal(_ proposalID: UUID, feedback: String?) {
        transientError = nil
        Task {
            do {
                try await terminalSessionManager.rejectProposal(
                    proposalID,
                    in: sessionID,
                    feedback: feedback,
                    provider: selectedProvider,
                    configuration: providerConfiguration,
                    secureSecretStore: secureSecretStore
                )
            } catch AIChatServiceError.missingAPIKey(let provider) {
                missingAPIKeyProvider = provider
            } catch {
                transientError = error.localizedDescription
            }
        }
    }

    private func requestDiagnosis() {
        transientError = nil
        Task {
            do {
                try await terminalSessionManager.requestDiagnosis(
                    for: sessionID,
                    provider: selectedProvider,
                    configuration: providerConfiguration,
                    secureSecretStore: secureSecretStore
                )
            } catch AIChatServiceError.missingAPIKey(let provider) {
                missingAPIKeyProvider = provider
            } catch {
                transientError = error.localizedDescription
            }
        }
    }
}

private struct TerminalWorkspaceHeader: View {
    let session: TerminalSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(session.state.color)
                    .frame(width: 9, height: 9)
                Text(session.subtitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer()
                Text(session.state.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(session.state.color)
            }

            HStack(spacing: 12) {
                Label(session.cwdGuess, systemImage: "folder")
                Label(session.lastCommand ?? "No command", systemImage: "clock")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct RawTerminalWorkspace: View {
    let session: TerminalSession
    let terminalFontSize: Double
    @Binding var input: String
    var onSubmit: () -> Void
    var onControlKey: (TerminalControlKey) -> Void
    var onInputData: (Data) -> Void
    var onResize: (Int, Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            SwiftTermTerminalViewRepresentable(
                sessionID: session.id,
                outputChunks: session.terminalOutputChunks,
                fontSize: terminalFontSize,
                onInputData: onInputData,
                onResize: onResize
            )
            .background(Color.black)

            if let statusMessage {
                HStack(spacing: 8) {
                    Image(systemName: session.state == .failed ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
                    Text(statusMessage)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(session.state == .failed ? .yellow : .secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black)
            }

            TerminalInputBar(
                prompt: "\(session.cwdGuess)$",
                input: $input,
                fontSize: terminalFontSize,
                onSubmit: onSubmit
            )

            TerminalAccessoryBar(onControlKey: onControlKey)
        }
        .background(Color.black)
    }

    private var statusMessage: String? {
        switch session.state {
        case .failed:
            return session.retainedLog.last ?? "Connection failed."
        case .disconnected:
            guard let lastLine = session.retainedLog.last, lastLine.hasPrefix("Disconnected:") else {
                return nil
            }
            return lastLine
        case .connecting, .connected, .closed:
            return nil
        }
    }
}

private struct TerminalInputBar: View {
    let prompt: String
    @Binding var input: String
    let fontSize: Double
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(prompt)
                .font(.system(size: fontSize, design: .monospaced).weight(.semibold))
                .foregroundStyle(.green)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            TextField("Command", text: $input)
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundStyle(.white)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.return)
                .onSubmit(onSubmit)

            Button(action: onSubmit) {
                Image(systemName: "arrow.up.circle.fill")
                    .imageScale(.large)
            }
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color.black)
    }
}

private struct TerminalAccessoryBar: View {
    var onControlKey: (TerminalControlKey) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TerminalControlKey.allCases) { key in
                    Button {
                        onControlKey(key)
                    } label: {
                        Text(key.title)
                            .font(.caption.weight(.semibold))
                            .frame(minWidth: 44)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }
}

private struct ChatTerminalWorkspace: View {
    let session: TerminalSession
    @Binding var draft: String
    let pendingProposal: CommandProposal?
    var onSend: (String) -> Void
    var onRunProposal: (UUID) -> Void
    var onEditProposal: (UUID) -> Void
    var onRejectProposal: (UUID, String?) -> Void

    private let chatModeReadyTip = ChatModeReadyTip()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ChatContextStrip(session: session)

                TipView(chatModeReadyTip)
                    .padding(.horizontal)

                ForEach(session.chatMessages) { message in
                    ChatMessageView(
                        message: message,
                        onRunProposal: onRunProposal,
                        onEditProposal: onEditProposal,
                        onRejectProposal: { proposalID in
                            onRejectProposal(proposalID, nil)
                        }
                    )
                }

                if session.isAwaitingAIResponse {
                    HStack {
                        ProgressView()
                        Text("Waiting for provider")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                }

                if let chatError = session.chatError {
                    Text(chatError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .safeAreaInset(edge: .bottom) {
            ChatInputBar(
                draft: $draft,
                isBusy: session.isAwaitingAIResponse,
                pendingProposal: pendingProposal,
                onSend: onSend,
                onRequestRevision: { proposalID, feedback in
                    onRejectProposal(proposalID, feedback)
                }
            )
        }
    }
}

private struct ChatContextStrip: View {
    let session: TerminalSession

    var body: some View {
        HStack(spacing: 10) {
            Label(session.state.title, systemImage: "dot.radiowaves.left.and.right")
                .foregroundStyle(session.state.color)
            Label(session.cwdGuess, systemImage: "folder")
            Label(session.lastCommand ?? "No command", systemImage: "clock")
        }
        .font(.caption)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal)
    }
}

private struct ChatMessageView: View {
    let message: AIChatMessage
    var onRunProposal: (UUID) -> Void
    var onEditProposal: (UUID) -> Void
    var onRejectProposal: (UUID) -> Void

    private var alignment: HorizontalAlignment {
        message.role == .user ? .trailing : .leading
    }

    private var bubbleColor: Color {
        switch message.role {
        case .user:
            .blue
        case .assistant:
            Color(.secondarySystemBackground)
        case .execution:
            Color(.tertiarySystemBackground)
        }
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 8) {
            Text(message.content)
                .font(.body)
                .foregroundStyle(message.role == .user ? .white : .primary)
                .padding(10)
                .background(bubbleColor, in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)

            ForEach(message.commandProposals) { proposal in
                CommandProposalCard(
                    proposal: proposal,
                    onRun: { onRunProposal(proposal.id) },
                    onEdit: { onEditProposal(proposal.id) },
                    onReject: { onRejectProposal(proposal.id) }
                )
            }
        }
        .padding(.horizontal)
    }
}

private struct CommandProposalCard: View {
    let proposal: CommandProposal
    var onRun: () -> Void
    var onEdit: () -> Void
    var onReject: () -> Void

    @State private var isExpandedOverride: Bool?

    private static let reviewTip = ProposalReviewTip()

    private var isCollapsed: Bool {
        if let isExpandedOverride {
            return !isExpandedOverride
        }
        return proposal.status == .rejected
    }

    var body: some View {
        if isCollapsed {
            collapsedBody
        } else {
            expandedBody
        }
    }

    private var collapsedBody: some View {
        Button {
            isExpandedOverride = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "xmark.circle")
                Text(proposal.command)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("Rejected")
                    .font(.caption2.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .padding(10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Command Proposal", systemImage: "terminal")
                    .font(.headline)
                Spacer()
                statusBadge
                Text(proposal.riskLevel.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(riskColor)
            }
            .popoverTip(Self.reviewTip)

            Text(proposal.command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(.white)

            Text(proposal.explanation)
                .font(.subheadline)
            Text(proposal.expectedEffect)
                .font(.caption)
                .foregroundStyle(.secondary)

            if proposal.requiresSudo || proposal.destructive {
                Label(proposal.destructive ? "Destructive command" : "Requires sudo", systemImage: "exclamationmark.triangle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }

            if let feedback = proposal.userFeedback, !feedback.isEmpty {
                Label(feedback, systemImage: "arrow.uturn.left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            switch proposal.status {
            case .pending:
                HStack {
                    Button(role: .destructive, action: {
                        Self.reviewTip.invalidate(reason: .actionPerformed)
                        onReject()
                    }) {
                        Label("Reject", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)

                    Button(action: onEdit) {
                        Label("Edit", systemImage: "pencil")
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button(action: {
                        Self.reviewTip.invalidate(reason: .actionPerformed)
                        onRun()
                    }) {
                        Label("Run", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .approved:
                HStack {
                    Button(action: onEdit) {
                        Label("Edit", systemImage: "pencil")
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button(action: onRun) {
                        Label("Run Again", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                }
            case .rejected:
                Button {
                    isExpandedOverride = false
                } label: {
                    Label("Collapse", systemImage: "chevron.up")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        .task {
            await ProposalReviewTip.proposalShown.donate()
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch proposal.status {
        case .pending:
            EmptyView()
        case .approved:
            Label("Ran", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .rejected:
            Label("Rejected", systemImage: "xmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
        }
    }

    private var riskColor: Color {
        switch proposal.riskLevel {
        case .low:
            .green
        case .medium:
            .orange
        case .high:
            .red
        }
    }
}

private struct ChatInputBar: View {
    @Binding var draft: String
    let isBusy: Bool
    let pendingProposal: CommandProposal?
    var onSend: (String) -> Void
    var onRequestRevision: (UUID, String) -> Void

    private var isReviewingProposal: Bool {
        pendingProposal != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if let pendingProposal {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.uturn.left")
                        .font(.caption)
                    Text(pendingProposal.command)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text("Revising")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 8)
            }

            HStack(spacing: 8) {
                TextField(
                    isReviewingProposal ? "Describe how to change this command" : "Ask about this terminal",
                    text: $draft,
                    axis: .vertical
                )
                .lineLimit(1...4)
                .textInputAutocapitalization(.sentences)
                .submitLabel(.send)
                .onSubmit(send)

                Button(action: send) {
                    Image(systemName: isReviewingProposal ? "arrow.uturn.left.circle.fill" : "paperplane.fill")
                        .imageScale(.medium)
                }
                .buttonStyle(.borderedProminent)
                .tint(isReviewingProposal ? .orange : .accentColor)
                .disabled(isBusy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .background(.bar)
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let pendingProposal {
            draft = ""
            onRequestRevision(pendingProposal.id, text)
        } else {
            onSend(text)
        }
    }
}

private struct MissingAPIKeySheet: View {
    let provider: AIProvider
    var openSettings: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "key.slash")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)

                Text("No \(provider.title) API Key")
                    .font(.title3.bold())

                Text("Configure a key before using Chat Mode or TL;DR diagnosis.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    openSettings()
                } label: {
                    Label("Open Settings", systemImage: "gearshape")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("API Key Required")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
