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

    /// 把捕获到的请求体解析成 JSON 字典（断言编码等价用）。
    /// URLProtocol 拦截时 httpBody 可能落在 httpBodyStream，两处都兜一下。
    func bodyJSON(_ req: URLRequest?) -> [String: Any]? {
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

    /// 锁死请求体编码：Encodable 改造后编码出的 JSON 必须与原 [String:Any] 等价。
    /// 断言顶层标量键（model/store/stream/instructions/tool_choice/parallel_tool_calls）、
    /// text/include 嵌套，以及 input 含文本项与图片项（input_image/image_url）。
    @Test func encodesRequestBodyEquivalentToOriginal() async throws {
        SSEMock.status = 200
        SSEMock.sse = """
        data: {"type":"response.completed"}

        data: [DONE]

        """
        let p = CodexResponsesProvider(accessToken: "tok", accountId: "acct-1",
                                       model: "gpt-5.5", session: mockSession())
        let dataURL = "data:image/png;base64,AAA/BBB"
        _ = try await p.complete(messages: [
            LLMMessage(role: .system, content: "be nice"),
            LLMMessage(role: .user, content: "hi", imageDataURLs: [dataURL]),
            LLMMessage(role: .assistant, content: "prev"),
        ])
        let body = try #require(bodyJSON(SSEMock.captured))
        // 顶层标量键与原 [String:Any] 取值一致。
        #expect(body["model"] as? String == "gpt-5.5")
        #expect(body["store"] as? Bool == false)
        #expect(body["stream"] as? Bool == true)
        #expect(body["instructions"] as? String == "be nice")
        #expect(body["tool_choice"] as? String == "auto")
        #expect(body["parallel_tool_calls"] as? Bool == true)
        // 嵌套：text.verbosity 与 include 数组。
        #expect((body["text"] as? [String: Any])?["verbosity"] as? String == "low")
        #expect(body["include"] as? [String] == ["reasoning.encrypted_content"])
        // input：system 被滤掉，保留 user/assistant 两条，role 与 content 项结构正确。
        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.count == 2)
        // user 条：role=user，文本项 type=input_text，并追加 input_image 图片项。
        let userMsg = input[0]
        #expect(userMsg["role"] as? String == "user")
        let userContent = try #require(userMsg["content"] as? [[String: Any]])
        #expect(userContent.count == 2)
        #expect(userContent[0]["type"] as? String == "input_text")
        #expect(userContent[0]["text"] as? String == "hi")
        #expect(userContent[1]["type"] as? String == "input_image")
        #expect(userContent[1]["image_url"] as? String == dataURL)
        // assistant 条：role=assistant，文本项 type=output_text，无图。
        let asstMsg = input[1]
        #expect(asstMsg["role"] as? String == "assistant")
        let asstContent = try #require(asstMsg["content"] as? [[String: Any]])
        #expect(asstContent.count == 1)
        #expect(asstContent[0]["type"] as? String == "output_text")
        #expect(asstContent[0]["text"] as? String == "prev")
    }

    /// 缺省 system：无 .system 消息时 instructions 落到默认值（与原行为一致）。
    @Test func encodesDefaultInstructionsWhenNoSystem() async throws {
        SSEMock.status = 200
        SSEMock.sse = """
        data: {"type":"response.completed"}

        data: [DONE]

        """
        let p = CodexResponsesProvider(accessToken: "tok", accountId: "a",
                                       model: "m", session: mockSession())
        _ = try await p.complete(messages: [LLMMessage(role: .user, content: "hi")])
        let body = try #require(bodyJSON(SSEMock.captured))
        #expect(body["instructions"] as? String == "You are a helpful assistant.")
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
