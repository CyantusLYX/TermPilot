import Foundation
import Testing
@testable import TermPilot

struct LLMServicesTests {
    @Test func openAIResponseDecodesToolCalls() throws {
        let json = """
        {
          "choices": [
            {
              "message": {
                "content": "I can inspect recent logs.",
                "tool_calls": [
                  {
                    "id": "call_1",
                    "type": "function",
                    "function": {
                      "name": "propose_shell_command",
                      "arguments": "{\\"command\\":\\"tail -n 50 /var/log/app.log\\",\\"explanation\\":\\"Read recent application logs.\\",\\"expected_effect\\":\\"Shows recent errors without changing state.\\",\\"risk_level\\":\\"low\\",\\"requires_sudo\\":false,\\"destructive\\":false}"
                    }
                  }
                ]
              }
            }
          ]
        }
        """

        let response = try OpenAICompatibleProvider.response(from: Data(json.utf8))

        #expect(response.text == "I can inspect recent logs.")
        #expect(response.toolCalls.count == 1)
        #expect(response.toolCalls.first?.name == "propose_shell_command")
    }

    @Test func toolCallsMapToCommandProposalsWithoutExecuting() throws {
        let arguments = Data(
            """
            {
              "command": "chmod -R 777 /etc",
              "explanation": "This is intentionally risky.",
              "expected_effect": "Permissions would change.",
              "risk_level": "low",
              "requires_sudo": true,
              "destructive": false
            }
            """.utf8
        )
        let response = LLMResponse(
            text: "",
            toolCalls: [
                LLMToolCall(id: "call_1", name: "propose_shell_command", argumentsJSON: arguments),
                LLMToolCall(id: "call_2", name: "unknown_tool", argumentsJSON: arguments)
            ]
        )

        let proposals = AIChatService.commandProposals(
            from: response,
            provider: .openAI,
            sourceMessageID: UUID()
        )

        #expect(proposals.count == 1)
        #expect(proposals.first?.command == "chmod -R 777 /etc")
        #expect(proposals.first?.riskLevel == .high)
        #expect(proposals.first?.approvedAt == nil)
    }

    @Test func toolCallsKeepProviderToolCallIDAndStartPending() throws {
        let arguments = Data(
            """
            {
              "command": "uptime",
              "explanation": "Check load.",
              "expected_effect": "Shows uptime.",
              "risk_level": "low",
              "requires_sudo": false,
              "destructive": false
            }
            """.utf8
        )
        let response = LLMResponse(
            text: "",
            toolCalls: [LLMToolCall(id: "call_42", name: "propose_shell_command", argumentsJSON: arguments)]
        )

        let proposals = AIChatService.commandProposals(
            from: response,
            provider: .openAI,
            sourceMessageID: UUID()
        )

        #expect(proposals.first?.toolCallID == "call_42")
        #expect(proposals.first?.status == .pending)
    }

    @Test func proposalResolutionDescribesEachStatus() {
        var proposal = CommandProposal(
            command: "uptime",
            explanation: "Check load.",
            expectedEffect: "Shows uptime.",
            riskLevel: .low,
            requiresSudo: false,
            destructive: false,
            provider: .openAI
        )

        #expect(ProposalResolution.toolResultContent(for: proposal).contains("not approved"))

        proposal.status = .approved
        proposal.executionTranscript = "load average: 0.42"
        let approvedContent = ProposalResolution.toolResultContent(for: proposal)
        #expect(approvedContent.contains("approved"))
        #expect(approvedContent.contains("load average: 0.42"))

        proposal.status = .rejected
        proposal.userFeedback = "Use uptime -p instead"
        let rejectedContent = ProposalResolution.toolResultContent(for: proposal)
        #expect(rejectedContent.contains("rejected"))
        #expect(rejectedContent.contains("Use uptime -p instead"))

        proposal.userFeedback = nil
        #expect(ProposalResolution.toolResultContent(for: proposal).contains("Do not propose the same command"))
    }

    @Test func geminiResponseDecodesFunctionCalls() throws {
        let json = """
        {
          "candidates": [
            {
              "content": {
                "role": "model",
                "parts": [
                  {
                    "text": "I can inspect the recent log output."
                  },
                  {
                    "functionCall": {
                      "id": "gemini-call-1",
                      "name": "propose_shell_command",
                      "args": {
                        "command": "journalctl -u ssh --no-pager -n 80",
                        "explanation": "Read recent SSH service logs.",
                        "expected_effect": "Shows recent SSH service failures without changing state.",
                        "risk_level": "low",
                        "requires_sudo": true,
                        "destructive": false
                      }
                    }
                  }
                ]
              }
            }
          ]
        }
        """

        let response = try GeminiProvider.response(from: Data(json.utf8))
        let proposals = AIChatService.commandProposals(
            from: response,
            provider: .gemini,
            sourceMessageID: UUID()
        )

        #expect(response.text == "I can inspect the recent log output.")
        #expect(response.toolCalls.first?.id == "gemini-call-1")
        #expect(proposals.count == 1)
        #expect(proposals.first?.provider == .gemini)
        #expect(proposals.first?.command == "journalctl -u ssh --no-pager -n 80")
        #expect(proposals.first?.riskLevel == .low)
        #expect(proposals.first?.approvedAt == nil)
    }

    @Test func geminiRequestBodyUsesFunctionDeclarationsWithoutToolConfig() throws {
        let data = try GeminiProvider.requestData(
            systemPrompt: "system",
            history: [
                AIChatMessage(role: .user, content: "inspect ssh failures")
            ]
        )
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["toolConfig"] == nil)
        #expect(json["generationConfig"] != nil)

        let tools = try #require(json["tools"] as? [[String: Any]])
        let declarations = try #require(tools.first?["functionDeclarations"] as? [[String: Any]])
        #expect(declarations.first?["name"] as? String == "propose_shell_command")

        let systemInstruction = try #require(json["systemInstruction"] as? [String: Any])
        let systemParts = try #require(systemInstruction["parts"] as? [[String: Any]])
        #expect(systemParts.first?["text"] as? String == "system")
    }

    @Test func geminiGenerateContentURLUsesToolSupportedModelPath() {
        let configuration = LLMProviderConfiguration(
            provider: .gemini,
            baseURLString: "https://generativelanguage.googleapis.com/v1beta",
            modelID: "gemini-3.5-flash"
        )

        #expect(configuration.geminiGenerateContentURL?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent")
    }

    @Test func geminiGenerateContentURLUpgradesKnownV1DeveloperEndpointForTools() {
        let configuration = LLMProviderConfiguration(
            provider: .gemini,
            baseURLString: "https://generativelanguage.googleapis.com/v1",
            modelID: "models/gemini-3.5-flash"
        )

        #expect(configuration.geminiGenerateContentURL?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent")
    }
}
