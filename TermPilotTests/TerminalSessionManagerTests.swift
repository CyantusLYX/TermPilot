import Foundation
import Testing
@testable import TermPilot

struct TerminalSessionManagerTests {
    @Test func activeBadgeLabelHidesZeroAndCapsLargeCounts() {
        let manager = TerminalSessionManager()
        #expect(manager.activeBadgeLabel == nil)

        manager.sessions = [
            TerminalSession(title: "One", subtitle: "root@example", state: .connected),
            TerminalSession(title: "Closed", subtitle: "root@example", state: .closed)
        ]
        #expect(manager.activeBadgeLabel == "1")

        manager.sessions = (0..<120).map {
            TerminalSession(title: "Session \($0)", subtitle: "root@example", state: .connected)
        }
        #expect(manager.activeBadgeLabel == "99+")
    }

    @Test func closeVisibleSessionsMarksOnlyOpenSessionsClosed() {
        let manager = TerminalSessionManager()
        let openID = UUID()
        let disconnectedID = UUID()
        let alreadyClosedID = UUID()
        manager.sessions = [
            TerminalSession(id: openID, title: "Open", subtitle: "root@example", state: .connected),
            TerminalSession(id: disconnectedID, title: "Disconnected", subtitle: "root@example", state: .disconnected),
            TerminalSession(id: alreadyClosedID, title: "Closed", subtitle: "root@example", state: .closed)
        ]

        manager.closeVisibleSessions()

        #expect(manager.activeCount == 0)
        #expect(manager.visibleSessions.isEmpty)
        #expect(manager.session(with: openID)?.state == .closed)
        #expect(manager.session(with: disconnectedID)?.state == .closed)
        #expect(manager.session(with: alreadyClosedID)?.state == .closed)
    }

    @Test func clearRetainedLogsOnlyMutatesVisibleSessions() {
        let manager = TerminalSessionManager()
        let visibleID = UUID()
        let closedID = UUID()
        manager.sessions = [
            TerminalSession(
                id: visibleID,
                title: "Visible",
                subtitle: "root@example",
                state: .connected,
                retainedLog: ["one", "two"]
            ),
            TerminalSession(
                id: closedID,
                title: "Closed",
                subtitle: "root@example",
                state: .closed,
                retainedLog: ["closed line"]
            )
        ]

        manager.clearRetainedLogs()

        #expect(manager.session(with: visibleID)?.retainedLog == [])
        #expect(manager.session(with: closedID)?.retainedLog == ["closed line"])
    }

    @Test func clearSingleRetainedLogLeavesSessionVisible() {
        let manager = TerminalSessionManager()
        let sessionID = UUID()
        manager.sessions = [
            TerminalSession(
                id: sessionID,
                title: "Visible",
                subtitle: "root@example",
                state: .connected,
                retainedLog: ["one"]
            )
        ]

        manager.clearRetainedLog(sessionID)

        #expect(manager.session(with: sessionID)?.state == .connected)
        #expect(manager.session(with: sessionID)?.retainedLog == [])
        #expect(manager.visibleSessions.map(\.id) == [sessionID])
    }

    @Test func closeSessionsForHostClosesOnlyMatchingHostSessions() {
        let manager = TerminalSessionManager()
        let deletedHostID = UUID()
        let remainingHostID = UUID()
        let deletedHostSessionID = UUID()
        let otherHostSessionID = UUID()
        let detachedSessionID = UUID()
        manager.sessions = [
            TerminalSession(
                id: deletedHostSessionID,
                hostID: deletedHostID,
                title: "Deleted Host",
                subtitle: "root@deleted",
                state: .connected
            ),
            TerminalSession(
                id: otherHostSessionID,
                hostID: remainingHostID,
                title: "Other Host",
                subtitle: "root@other",
                state: .connected
            ),
            TerminalSession(
                id: detachedSessionID,
                title: "Detached",
                subtitle: "local",
                state: .connected
            )
        ]

        manager.closeSessions(forHostID: deletedHostID)

        #expect(manager.session(with: deletedHostSessionID)?.state == .closed)
        #expect(manager.session(with: otherHostSessionID)?.state == .connected)
        #expect(manager.session(with: detachedSessionID)?.state == .connected)
        #expect(manager.activeCount == 2)
    }

    @Test func appendingRetainedLogKeepsNewestLinesWithinLimit() {
        let manager = TerminalSessionManager()
        let sessionID = UUID()
        manager.sessions = [
            TerminalSession(id: sessionID, title: "Visible", subtitle: "root@example", state: .connected)
        ]

        let lines = (0..<(TerminalSessionManager.retainedLogLineLimit + 5)).map { "line-\($0)" }
        manager.appendRetainedLog(lines, to: sessionID)

        let retainedLog = manager.session(with: sessionID)?.retainedLog
        #expect(retainedLog?.count == TerminalSessionManager.retainedLogLineLimit)
        #expect(retainedLog?.first == "line-5")
        #expect(retainedLog?.last == "line-\(TerminalSessionManager.retainedLogLineLimit + 4)")
    }

    @Test func pendingProposalReturnsNewestPendingProposal() {
        let manager = TerminalSessionManager()
        let sessionID = UUID()
        let rejected = CommandProposal(
            command: "rm file",
            explanation: "",
            expectedEffect: "",
            riskLevel: .low,
            requiresSudo: false,
            destructive: false,
            provider: .openAI,
            status: .rejected
        )
        let pending = CommandProposal(
            command: "ls",
            explanation: "",
            expectedEffect: "",
            riskLevel: .low,
            requiresSudo: false,
            destructive: false,
            provider: .openAI
        )
        manager.sessions = [
            TerminalSession(
                id: sessionID,
                title: "Host",
                subtitle: "root@example",
                state: .connected,
                chatMessages: [
                    AIChatMessage(role: .assistant, content: "", commandProposals: [rejected]),
                    AIChatMessage(role: .assistant, content: "", commandProposals: [pending])
                ]
            )
        ]

        #expect(manager.pendingProposal(in: sessionID)?.id == pending.id)
    }
}
