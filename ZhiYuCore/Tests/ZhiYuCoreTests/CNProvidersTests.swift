import Testing
import Foundation
@testable import ZhiYuCore

/// 国内三家 OpenAI 兼容 Provider（智谱GLM / Kimi / MiniMax）的接入测试。
/// 用独立的 URLProtocol（不复用 OpenAIProviderTests 里的 MockURLProtocol），
/// 避免与其它套件共享全局 handler 时串扰。
final class CNMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = CNMockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let (resp, data) = handler(request)
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func cnMockSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [CNMockURLProtocol.self]
    return URLSession(configuration: cfg)
}

// 共享全局 handler，并行会互相覆盖，故放进 .serialized 套件按序执行。
@Suite(.serialized)
struct CNProvidersTests {
    /// 给定一个 ProviderConfig，断言 complete 打到 baseURL + /chat/completions、带 Bearer、能解析响应。
    private func assertHitsEndpoint(config: ProviderConfig, expectedURL: String) async throws {
        nonisolated(unsafe) var captured: URLRequest?
        CNMockURLProtocol.handler = { req in
            captured = req
            let body = """
            {"choices":[{"message":{"role":"assistant","content":"你好呀"}}]}
            """.data(using: .utf8)!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, body)
        }
        let provider = OpenAICompatibleProvider(config: config, apiKey: "sk-test", session: cnMockSession())
        let text = try await provider.complete(messages: [LLMMessage(role: .user, content: "hi")])
        #expect(text == "你好呀")
        #expect(captured?.url?.absoluteString == expectedURL)
        #expect(captured?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
    }

    @Test func glmHitsBigModelEndpointWithBearer() async throws {
        try await assertHitsEndpoint(
            config: .glm(model: "glm-4-flash"),
            expectedURL: "https://open.bigmodel.cn/api/paas/v4/chat/completions")
    }

    @Test func kimiHitsMoonshotEndpointWithBearer() async throws {
        try await assertHitsEndpoint(
            config: .kimi(model: "moonshot-v1-8k"),
            expectedURL: "https://api.moonshot.cn/v1/chat/completions")
    }

    @Test func minimaxHitsMiniMaxEndpointWithBearer() async throws {
        try await assertHitsEndpoint(
            config: .minimax(model: "MiniMax-M2"),
            expectedURL: "https://api.minimaxi.com/v1/chat/completions")
    }
}
