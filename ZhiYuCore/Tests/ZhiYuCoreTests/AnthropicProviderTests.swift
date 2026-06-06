import Testing
import Foundation
@testable import ZhiYuCore

// 用独立的 mock 协议（不复用 OpenAIProviderTests 的 MockURLProtocol）：
// .serialized 只串行化套件内部用例，套件之间仍并行，共享同一个全局 handler 会互相覆盖。
private final class AnthropicMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = AnthropicMockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let (resp, data) = handler(request)
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func mockSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [AnthropicMockURLProtocol.self]
    return URLSession(configuration: cfg)
}

/// 把请求体解析成 JSON 字典（测试断言用）。
private func bodyJSON(_ req: URLRequest) -> [String: Any]? {
    // URLProtocol 拦截时 httpBody 可能落在 httpBodyStream，两处都兜一下。
    let data: Data?
    if let b = req.httpBody { data = b }
    else if let s = req.httpBodyStream {
        s.open(); defer { s.close() }
        var buf = Data(); var tmp = [UInt8](repeating: 0, count: 4096)
        while s.hasBytesAvailable {
            let n = s.read(&tmp, maxLength: tmp.count)
            if n <= 0 { break }
            buf.append(tmp, count: n)
        }
        data = buf
    } else { data = nil }
    guard let d = data else { return nil }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}

// 这些用例共享 AnthropicMockURLProtocol.handler，并行执行会互相覆盖，故放进 .serialized 套件按序执行。
@Suite(.serialized)
struct AnthropicProviderTests {
    @Test func completeSendsURLHeadersAndParsesContent() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        AnthropicMockURLProtocol.handler = { req in
            captured = req
            let body = """
            {"content":[{"type":"text","text":"你好"},{"type":"text","text":"呀"}]}
            """.data(using: .utf8)!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, body)
        }
        let provider = AnthropicProvider(
            config: .anthropic(model: "claude-sonnet-4-6"), apiKey: "sk-ant-test", session: mockSession())
        let text = try await provider.complete(messages: [LLMMessage(role: .user, content: "hi")])
        #expect(text == "你好呀")
        #expect(captured?.url?.absoluteString.hasSuffix("/v1/messages") == true)
        #expect(captured?.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(captured?.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    }

    @Test func systemMessageGoesToTopLevelSystemNotMessages() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        AnthropicMockURLProtocol.handler = { req in
            captured = req
            let body = #"{"content":[{"type":"text","text":"ok"}]}"#.data(using: .utf8)!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, body)
        }
        let provider = AnthropicProvider(
            config: .anthropic(model: "claude-sonnet-4-6"), apiKey: "k", session: mockSession())
        _ = try await provider.complete(messages: [
            LLMMessage(role: .system, content: "你是助手"),
            LLMMessage(role: .user, content: "hi"),
        ])
        let json = bodyJSON(captured!)
        #expect(json?["system"] as? String == "你是助手")
        let messages = json?["messages"] as? [[String: Any]]
        #expect(messages?.count == 1)
        #expect(messages?.first?["role"] as? String == "user")
        // system 不应出现在 messages 数组里。
        #expect(messages?.contains { ($0["role"] as? String) == "system" } == false)
    }

    @Test func imageMessageEncodesImageBlock() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        AnthropicMockURLProtocol.handler = { req in
            captured = req
            let body = #"{"content":[{"type":"text","text":"ok"}]}"#.data(using: .utf8)!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, body)
        }
        let provider = AnthropicProvider(
            config: .anthropic(model: "claude-sonnet-4-6"), apiKey: "k", session: mockSession())
        _ = try await provider.complete(messages: [
            LLMMessage(role: .user, content: "看图",
                       imageDataURLs: ["data:image/png;base64,QQ=="]),
        ])
        let json = bodyJSON(captured!)
        let messages = json?["messages"] as? [[String: Any]]
        let content = messages?.first?["content"] as? [[String: Any]]
        #expect(content?.count == 2)
        #expect(content?.first?["type"] as? String == "text")
        #expect(content?.first?["text"] as? String == "看图")
        let imageBlock = content?.first { ($0["type"] as? String) == "image" }
        let source = imageBlock?["source"] as? [String: Any]
        #expect(source?["type"] as? String == "base64")
        #expect(source?["media_type"] as? String == "image/png")
        #expect(source?["data"] as? String == "QQ==")
    }

    @Test func completeThrowsOnHTTPError() async {
        AnthropicMockURLProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (resp, Data("unauthorized".utf8))
        }
        let provider = AnthropicProvider(
            config: .anthropic(model: "claude-sonnet-4-6"), apiKey: "bad", session: mockSession())
        await #expect(throws: ProviderError.self) {
            _ = try await provider.complete(messages: [LLMMessage(role: .user, content: "hi")])
        }
    }

    @Test func completeThrowsMissingAPIKey() async {
        let provider = AnthropicProvider(
            config: .anthropic(model: "claude-sonnet-4-6"), apiKey: "", session: mockSession())
        await #expect(throws: ProviderError.missingAPIKey) {
            _ = try await provider.complete(messages: [LLMMessage(role: .user, content: "hi")])
        }
    }
}
