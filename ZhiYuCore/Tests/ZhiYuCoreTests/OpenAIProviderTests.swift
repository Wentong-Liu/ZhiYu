import Testing
import Foundation
@testable import ZhiYuCore

/// 拦截网络请求的 mock（测试用）。
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
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
    cfg.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: cfg)
}

// 这些用例共享全局 MockURLProtocol.handler，并行执行会互相覆盖，故放进 .serialized 套件按序执行。
@Suite(.serialized)
struct OpenAIProviderTests {
    @Test func completeSendsBearerAndModelAndParsesContent() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        MockURLProtocol.handler = { req in
            captured = req
            let body = """
            {"choices":[{"message":{"role":"assistant","content":"你好呀"}}]}
            """.data(using: .utf8)!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, body)
        }
        let provider = OpenAICompatibleProvider(
            config: .openAI(model: "gpt-4o"), apiKey: "sk-test", session: mockSession())
        let text = try await provider.complete(messages: [LLMMessage(role: .user, content: "hi")])
        #expect(text == "你好呀")
        #expect(captured?.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(captured?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
    }

    @Test func completeThrowsOnHTTPError() async {
        MockURLProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (resp, Data("unauthorized".utf8))
        }
        let provider = OpenAICompatibleProvider(
            config: .openAI(model: "gpt-4o"), apiKey: "bad", session: mockSession())
        await #expect(throws: ProviderError.self) {
            _ = try await provider.complete(messages: [LLMMessage(role: .user, content: "hi")])
        }
    }

    @Test func completeThrowsMissingAPIKey() async {
        let provider = OpenAICompatibleProvider(
            config: .openAI(model: "gpt-4o"), apiKey: "", session: mockSession())
        await #expect(throws: ProviderError.missingAPIKey) {
            _ = try await provider.complete(messages: [LLMMessage(role: .user, content: "hi")])
        }
    }
}
