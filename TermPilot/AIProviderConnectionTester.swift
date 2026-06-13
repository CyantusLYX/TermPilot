import Foundation

enum AIProviderConnectionTestError: LocalizedError {
    case invalidBaseURL(String)
    case invalidResponse
    case httpError(provider: AIProvider, statusCode: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let value):
            "Invalid provider base URL: \(value)"
        case .invalidResponse:
            "The provider returned an unexpected response."
        case .httpError(let provider, let statusCode, let message):
            if let message, !message.isEmpty {
                "\(provider.title) returned HTTP \(statusCode): \(message)"
            } else {
                "\(provider.title) returned HTTP \(statusCode)."
            }
        }
    }
}

enum AIProviderConnectionTester {
    static func testConnection(
        for provider: AIProvider,
        apiKey: String,
        configuration: LLMProviderConfiguration? = nil
    ) async throws {
        let request = try makeRequest(for: provider, apiKey: apiKey, configuration: configuration)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderConnectionTestError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AIProviderConnectionTestError.httpError(
                provider: provider,
                statusCode: httpResponse.statusCode,
                message: providerErrorMessage(from: data)
            )
        }
    }

    private static func makeRequest(
        for provider: AIProvider,
        apiKey: String,
        configuration: LLMProviderConfiguration?
    ) throws -> URLRequest {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL

        switch provider {
        case .openAI:
            if let configuration {
                guard let configuredURL = configuration.modelsURL else {
                    throw AIProviderConnectionTestError.invalidBaseURL(configuration.baseURLString)
                }
                url = configuredURL
            } else {
                url = URL(string: "https://api.openai.com/v1/models")!
            }
        case .anthropic:
            url = URL(string: "https://api.anthropic.com/v1/models")!
        case .gemini:
            if let configuration {
                guard let configuredURL = configuration.modelsURL else {
                    throw AIProviderConnectionTestError.invalidBaseURL(configuration.baseURLString)
                }
                url = configuredURL
            } else {
                url = URL(string: "\(LLMProviderConfiguration.defaultGeminiBaseURLString)/models")!
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData

        switch provider {
        case .openAI:
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            request.setValue(trimmedKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini:
            request.setValue(trimmedKey, forHTTPHeaderField: "x-goog-api-key")
        }

        return request
    }

    private static func providerErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }

        if let envelope = try? JSONDecoder().decode(ProviderErrorEnvelope.self, from: data) {
            return envelope.error?.message ?? envelope.message
        }

        return String(data: data, encoding: .utf8)
    }
}

private struct ProviderErrorEnvelope: Decodable {
    var error: ProviderErrorBody?
    var message: String?
}

private struct ProviderErrorBody: Decodable {
    var message: String?
}
