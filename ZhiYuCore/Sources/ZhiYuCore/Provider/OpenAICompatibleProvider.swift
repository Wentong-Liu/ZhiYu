import Foundation

/// 调用 OpenAI 兼容的 /chat/completions。Key 由调用方传入（不读 Keychain，保持可测）。
public struct OpenAICompatibleProvider: LLMProvider {
    private let config: ProviderConfig
    private let apiKey: String
    private let session: URLSession
    private let extraHeaders: [String: String]

    public init(config: ProviderConfig, apiKey: String, session: URLSession = .shared,
                extraHeaders: [String: String] = [:]) {
        self.config = config
        self.apiKey = apiKey
        self.session = session
        self.extraHeaders = extraHeaders
    }

    private struct RequestBody: Encodable {
        let model: String
        let messages: [LLMMessage]
        let temperature: Double
    }
    private struct ResponseBody: Decodable {
        struct Choice: Decodable { struct Msg: Decodable { let content: String }; let message: Msg }
        let choices: [Choice]
    }

    public func complete(messages: [LLMMessage]) async throws -> String {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey }
        guard let url = URL(string: config.baseURL + "/chat/completions") else {
            throw ProviderError.invalidResponse
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONEncoder().encode(
            RequestBody(model: config.model, messages: messages, temperature: 0.8))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.httpError(status: http.statusCode,
                                          body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let parsed = try? JSONDecoder().decode(ResponseBody.self, from: data),
              let content = parsed.choices.first?.message.content else {
            throw ProviderError.invalidResponse
        }
        return content
    }
}
