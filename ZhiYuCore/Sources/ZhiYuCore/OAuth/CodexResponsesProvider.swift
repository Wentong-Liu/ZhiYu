import Foundation

/// 用 ChatGPT(Codex) OAuth token 调 codex/responses（Responses API + SSE）。
/// 把 [LLMMessage] 映射为 instructions(系统) + input(其余)，流式累积 output_text.delta。
public struct CodexResponsesProvider: LLMProvider {
    private let accessToken: String
    private let accountId: String
    private let model: String
    private let userAgent: String
    private let session: URLSession

    /// 单次请求的连接/响应超时（秒）。
    private static let requestTimeout = LLMDefaults.requestTimeout
    /// SSE 读取循环的整体上限（秒）：超过则判定流卡死并失败，避免无限挂起。
    private static let maxStreamSeconds: TimeInterval = 90

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
        let input: [[String: Any]] = messages.filter { $0.role != .system }.map { message in
            let type = (message.role == .assistant) ? "output_text" : "input_text"
            var content: [[String: Any]] = [["type": type, "text": message.content]]
            for url in message.imageDataURLs {
                content.append(["type": "input_image", "image_url": url])
            }
            return ["role": message.role.rawValue, "content": content]
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
        guard let url = URL(string: ChatGPTOAuth.responsesEndpoint) else {
            throw ProviderError.invalidResponse
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = Self.requestTimeout
        req.setBearerAuthorization(accessToken)
        req.setValue(accountId, forHTTPHeaderField: "chatgpt-account-id")
        req.setValue(ChatGPTOAuth.originator, forHTTPHeaderField: "originator")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        req.setValue("text/event-stream", forHTTPHeaderField: HTTPConstants.acceptHeader)
        req.setValue(HTTPConstants.applicationJSON, forHTTPHeaderField: HTTPConstants.contentTypeHeader)
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: req)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
        let http = try HTTPResponseValidator.httpResponse(from: response)
        if !HTTPResponseValidator.successRange.contains(http.statusCode) {
            // 读尽剩余 body 供报错（按换行 join，保留各行边界）。
            var errLines: [String] = []
            for try await line in bytes.lines { errLines.append(line) }
            try HTTPResponseValidator.throwIfHTTPError(http, body: errLines.joined(separator: "\n"))
        }

        var text = ""
        let start = ProcessInfo.processInfo.systemUptime
        for try await line in bytes.lines {
            if ProcessInfo.processInfo.systemUptime - start > Self.maxStreamSeconds {
                throw ProviderError.streamFailed(body: "stream timed out after \(Int(Self.maxStreamSeconds))s")
            }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty || payload == "[DONE]" { continue }
            guard let payloadData = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
                  let type = event["type"] as? String else { continue }
            switch type {
            case "response.output_text.delta":
                if let delta = event["delta"] as? String { text += delta }
            case "response.completed", "response.done", "response.incomplete":
                return text
            case "error", "response.failed":
                throw ProviderError.streamFailed(body: payload)
            default:
                continue
            }
        }
        return text
    }
}
