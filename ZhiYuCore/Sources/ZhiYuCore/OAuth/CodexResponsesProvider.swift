import Foundation

/// 用 ChatGPT(Codex) OAuth token 调 codex/responses（Responses API + SSE）。
/// 把 [LLMMessage] 映射为 instructions(系统) + input(其余)，流式累积 output_text.delta。
public struct CodexResponsesProvider: LLMProvider {
    private let accessToken: String
    private let accountId: String
    private let model: String
    private let userAgent: String
    private let session: URLSession

    public init(accessToken: String, accountId: String, model: String,
                userAgent: String = "\(ChatGPTOAuth.originator) (macOS)", session: URLSession = .shared) {
        self.accessToken = accessToken
        self.accountId = accountId
        self.model = model
        self.userAgent = userAgent
        self.session = session
    }

    public func complete(messages: [LLMMessage]) async throws -> String {
        guard !accessToken.isEmpty else { throw ProviderError.missingAPIKey }
        let system = messages.first(where: { $0.role == .system })?.content ?? "You are a helpful assistant."
        let input: [[String: Any]] = messages.filter { $0.role != .system }.map { m in
            let type = (m.role == .assistant) ? "output_text" : "input_text"
            var content: [[String: Any]] = [["type": type, "text": m.content]]
            for url in m.imageDataURLs {
                content.append(["type": "input_image", "image_url": url])
            }
            return ["role": m.role.rawValue, "content": content]
        }
        let body: [String: Any] = [
            "model": model,
            "store": false,
            "stream": true,
            "instructions": system,
            "input": input,
            "text": ["verbosity": "low"],
            "include": ["reasoning.encrypted_content"],
            "tool_choice": "auto",
            "parallel_tool_calls": true,
        ]
        guard let url = URL(string: "https://chatgpt.com/backend-api/codex/responses") else {
            throw ProviderError.invalidResponse
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(accountId, forHTTPHeaderField: "chatgpt-account-id")
        req.setValue(ChatGPTOAuth.originator, forHTTPHeaderField: "originator")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        req.setValue("text/event-stream", forHTTPHeaderField: "accept")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: req)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            // 读尽剩余 body 供报错
            var errText = ""
            for try await line in bytes.lines { errText += line }
            throw ProviderError.httpError(status: http.statusCode, body: errText)
        }

        var text = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty || payload == "[DONE]" { continue }
            guard let d = payload.data(using: .utf8),
                  let ev = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let type = ev["type"] as? String else { continue }
            switch type {
            case "response.output_text.delta":
                if let delta = ev["delta"] as? String { text += delta }
            case "response.completed", "response.done", "response.incomplete":
                return text
            case "error", "response.failed":
                throw ProviderError.httpError(status: 0, body: payload)
            default:
                continue
            }
        }
        return text
    }
}
