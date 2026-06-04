import Testing
import Foundation
@testable import ZhiYuCore

@Suite(.serialized)
struct CodexResponsesProviderTests {
    final class SSEMock: URLProtocol {
        nonisolated(unsafe) static var sse: String = ""
        nonisolated(unsafe) static var status: Int = 200
        nonisolated(unsafe) static var captured: URLRequest?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            SSEMock.captured = request
            let resp = HTTPURLResponse(url: request.url!, statusCode: SSEMock.status,
                httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(SSEMock.sse.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    func mockSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [SSEMock.self]
        return URLSession(configuration: cfg)
    }

    @Test func accumulatesOutputTextDeltasAndSendsHeaders() async throws {
        SSEMock.status = 200
        SSEMock.sse = """
        data: {"type":"response.output_text.delta","delta":"你好"}

        data: {"type":"response.output_text.delta","delta":"呀"}

        data: {"type":"response.completed"}

        data: [DONE]

        """
        let p = CodexResponsesProvider(accessToken: "tok", accountId: "acct-1",
                                       model: "gpt-5.5", session: mockSession())
        let text = try await p.complete(messages: [
            LLMMessage(role: .system, content: "be nice"),
            LLMMessage(role: .user, content: "hi"),
        ])
        #expect(text == "你好呀")
        #expect(SSEMock.captured?.url?.absoluteString == "https://chatgpt.com/backend-api/codex/responses")
        #expect(SSEMock.captured?.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(SSEMock.captured?.value(forHTTPHeaderField: "chatgpt-account-id") == "acct-1")
        #expect(SSEMock.captured?.value(forHTTPHeaderField: "originator") == "openclaw")
        #expect(SSEMock.captured?.value(forHTTPHeaderField: "OpenAI-Beta") == "responses=experimental")
    }

    @Test func throwsOnHTTPError() async {
        SSEMock.status = 401
        SSEMock.sse = "unauthorized"
        let p = CodexResponsesProvider(accessToken: "bad", accountId: "a",
                                       model: "gpt-5.5", session: mockSession())
        await #expect(throws: ProviderError.self) {
            _ = try await p.complete(messages: [LLMMessage(role: .user, content: "hi")])
        }
    }
}
