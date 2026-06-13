//
//  TermPilotTests.swift
//  TermPilotTests
//
//  Created by Lin Yu Xiang on 2026/6/11.
//

import Testing
import SwiftUI
@testable import TermPilot

struct TermPilotTests {
    @Test func aiProviderValidationAcceptsExpectedPrefixes() {
        #expect(AIProvider.openAI.validationMessage(for: "sk-proj-example") == nil)
        #expect(AIProvider.openAI.validationMessage(for: "sk-example") == nil)
        #expect(AIProvider.anthropic.validationMessage(for: "sk-ant-example") == nil)
        #expect(AIProvider.gemini.validationMessage(for: "gemini-valid-test-key") == nil)
    }

    @Test func aiProviderValidationRejectsWrongProviderFormats() {
        #expect(AIProvider.openAI.validationMessage(for: "sk-ant-example") == "Invalid OpenAI API Key format.")
        #expect(AIProvider.anthropic.validationMessage(for: "sk-proj-example") == "Invalid Anthropic API Key format.")
        #expect(AIProvider.gemini.validationMessage(for: "bad key with spaces") == "Invalid Gemini API Key format.")
    }

    @Test func aiProviderConfiguredKeyDescriptionMasksSecretBody() {
        #expect(AIProvider.openAI.configuredKeyDescription(for: "") == nil)
        #expect(AIProvider.openAI.configuredKeyDescription(for: "  sk-proj-abcdef123456  ") == "Configured • ...3456")
        #expect(AIProvider.anthropic.configuredKeyDescription(for: "sk-ant-super-secret") == "Configured • ...cret")
    }

    @Test func aiProviderNormalizesPastedKeyWhitespace() {
        #expect(AIProvider.openAI.normalizedKey(" \nsk-proj-example\t ") == "sk-proj-example")
        #expect(AIProvider.anthropic.validationMessage(for: "\nsk-ant-example\n") == nil)
        #expect(AIProvider.gemini.configuredKeyDescription(for: "\tgemini-valid-test-key\n") == "Configured • ...-key")
    }

    @MainActor
    @Test func tabRouterCanOpenProviderSpecificAPIKeySettings() {
        let router = TabRouter()
        router.openSettingsAPIKey(for: .anthropic)

        #expect(router.selectedTab == .settings)
        #expect(router.settingsPath.count == 1)
        #expect(router.lastOpenedSettingsRoute == .apiKey(.anthropic))

        router.popToRoot(.settings)
        #expect(router.settingsPath.count == 0)
        #expect(router.lastOpenedSettingsRoute == nil)
    }
}
