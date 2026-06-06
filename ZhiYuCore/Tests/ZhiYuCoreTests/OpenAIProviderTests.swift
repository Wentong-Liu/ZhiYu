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

/// 把请求体解析成 JSON 字典（测试断言用）。
/// URLProtocol 拦截时 httpBody 可能落在 httpBodyStream，两处都兜一下。
private func bodyJSON(_ req: URLRequest?) -> [String: Any]? {
    guard let req else { return nil }
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

    @Test func sendsImagesEncodesContentAsPartsWithImageURL() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        MockURLProtocol.handler = { req in
            captured = req
            let body = """
            {"choices":[{"message":{"role":"assistant","content":"看到啦"}}]}
            """.data(using: .utf8)!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, body)
        }
        let dataURL = "data:image/png;base64,QQ=="
        let provider = OpenAICompatibleProvider(
            config: .openAI(model: "gpt-4o"), apiKey: "sk-test", session: mockSession(), sendsImages: true)
        let text = try await provider.complete(messages: [
            LLMMessage(role: .user, content: "这是什么", imageDataURLs: [dataURL])
        ])
        #expect(text == "看到啦")

        // 解析请求体：content 应是数组，含一个 text part 和一个 image_url part，url 等于 dataURL。
        let json = try #require(bodyJSON(captured))
        let messages = json["messages"] as! [[String: Any]]
        let content = messages.first?["content"] as? [[String: Any]]
        let contentParts = try #require(content, "content 应为 parts 数组")
        #expect(contentParts.contains { ($0["type"] as? String) == "text" && ($0["text"] as? String) == "这是什么" })
        let imagePart = try #require(contentParts.first { ($0["type"] as? String) == "image_url" })
        let imageURL = imagePart["image_url"] as? [String: Any]
        #expect((imageURL?["url"] as? String) == dataURL)
    }

    @Test func sendsImagesFalseKeepsContentAsPlainString() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        MockURLProtocol.handler = { req in
            captured = req
            let body = """
            {"choices":[{"message":{"role":"assistant","content":"ok"}}]}
            """.data(using: .utf8)!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, body)
        }
        // 默认 sendsImages == false（DeepSeek/旧行为）：即便带图，content 仍是纯字符串、不含图片块。
        let provider = OpenAICompatibleProvider(
            config: .deepSeek(model: "deepseek-v4-flash"), apiKey: "sk-test", session: mockSession())
        _ = try await provider.complete(messages: [
            LLMMessage(role: .user, content: "这是什么", imageDataURLs: ["data:image/png;base64,QQ=="])
        ])
        let json = try #require(bodyJSON(captured))
        let messages = json["messages"] as! [[String: Any]]
        #expect((messages.first?["content"] as? String) == "这是什么")
        #expect((messages.first?["content"] as? [[String: Any]]) == nil)
    }

    @Test func completeThrowsMissingAPIKey() async {
        let provider = OpenAICompatibleProvider(
            config: .openAI(model: "gpt-4o"), apiKey: "", session: mockSession())
        await #expect(throws: ProviderError.missingAPIKey) {
            _ = try await provider.complete(messages: [LLMMessage(role: .user, content: "hi")])
        }
    }
}
