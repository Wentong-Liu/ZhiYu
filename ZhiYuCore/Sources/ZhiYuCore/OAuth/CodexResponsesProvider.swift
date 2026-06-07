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
    /// SSE 行的数据前缀（判前缀与剥前缀共用，避免同串写两遍）。
    private static let dataPrefix = "data:"

    public init(accessToken: String, accountId: String, model: String,
                userAgent: String = ChatGPTOAuth.defaultUserAgent, session: URLSession = .shared) {
        self.accessToken = accessToken
        self.accountId = accountId
        self.model = model
        self.userAgent = userAgent
        self.session = session
    }

    /// input[].content 里的一项：文本项（input_text/output_text）或图片项（input_image）。
    /// 用自定义 Encodable 表达这种多态——编码出的键与旧 [String:Any] 等价：
    /// 文本项 {type,text}，图片项 {type,image_url}。
    private enum ContentItem: Encodable {
        case text(type: String, text: String)
        case image(url: String)

        private enum CodingKeys: String, CodingKey { case type, text, image_url }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .text(type, text):
                try c.encode(type, forKey: .type)
                try c.encode(text, forKey: .text)
            case let .image(url):
                try c.encode("input_image", forKey: .type)
                try c.encode(url, forKey: .image_url)
            }
        }
    }

    /// 一条 input 消息：role + content 项数组。
    private struct InputMessage: Encodable {
        let role: String
        let content: [ContentItem]
    }

    /// text 字段：{"verbosity":"low"}。
    private struct TextOption: Encodable { let verbosity: String }

    /// Responses 请求体（镜像 OpenAICompatibleProvider.RequestBody 写法，键类型安全）。
    private struct RequestBody: Encodable {
        let model: String
        let store: Bool
        let stream: Bool
        let instructions: String
        let input: [InputMessage]
        let text: TextOption
        let include: [String]
        let tool_choice: String
        let parallel_tool_calls: Bool
    }

    public func complete(messages: [LLMMessage]) async throws -> String {
        guard !accessToken.isEmpty else { throw ProviderError.missingAPIKey }
        let system = messages.first(where: { $0.role == .system })?.content ?? "You are a helpful assistant."
        let input: [InputMessage] = messages.filter { $0.role != .system }.map { message in
            let type = (message.role == .assistant) ? "output_text" : "input_text"
            var content: [ContentItem] = [.text(type: type, text: message.content)]
            for url in message.imageDataURLs {
                content.append(.image(url: url))
            }
            return InputMessage(role: message.role.rawValue, content: content)
        }
        let body = RequestBody(
            model: model,
            store: false,
            stream: true,
            instructions: system,
            input: input,
            text: TextOption(verbosity: "low"),
            include: ["reasoning.encrypted_content"],
            tool_choice: "auto",
            parallel_tool_calls: true)
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
        // 配置 .withoutEscapingSlashes 保留原 JSONSerialization 的输出行为（image_url 里的 dataURL 含 /，不转义）。
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        req.httpBody = try encoder.encode(body)

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
            guard line.hasPrefix(Self.dataPrefix) else { continue }
            let payload = line.dropFirst(Self.dataPrefix.count).trimmingCharacters(in: .whitespaces)
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
        // 流自然结束却没收到 response.completed/done/incomplete 终止事件：记录助排查（行为不变，仍返回已累积文本）。
        NSLog("[ZhiYu][CodexResponses] SSE 流结束但未收到终止事件，返回已累积文本 长度=%d", text.count)
        return text
    }
}
