import Testing
import Foundation
@testable import ZhiYuCore

@Test func promptBuilderAttachesImagesToUserMessage() {
    let ctx = ChatContext(contactName: "张婷",
                          messages: [ChatMessage(speaker: .other, text: "[图片]")],
                          draft: "",
                          imageDataURLs: ["data:image/png;base64,AAA"])
    let msgs = PromptBuilder.build(context: ctx, style: .concise, candidateCount: 3)
    let user = msgs.last
    #expect(user?.role == .user)
    #expect(user?.imageDataURLs == ["data:image/png;base64,AAA"])
    #expect((user?.content ?? "").contains("图片"))   // 文本里提到对方发了图片
}

@Test func codexResponsesBodyIncludesInputImageWhenPresent() async throws {
    final class Mock: URLProtocol {
        nonisolated(unsafe) static var body: Data = Data()
        override class func canInit(with r: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {
            Mock.body = request.httpBodyStream.flatMap { s -> Data in
                s.open(); defer { s.close() }
                var d = Data(); let n = 4096; var buf = [UInt8](repeating: 0, count: n)
                while s.hasBytesAvailable { let r = s.read(&buf, maxLength: n); if r <= 0 { break }; d.append(buf, count: r) }
                return d
            } ?? request.httpBody ?? Data()
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"ok\"}\n\ndata: {\"type\":\"response.completed\"}\n\n".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [Mock.self]
    let session = URLSession(configuration: cfg)
    let p = CodexResponsesProvider(accessToken: "t", accountId: "a", model: "gpt-5.5", session: session)
    let text = try await p.complete(messages: [
        LLMMessage(role: .user, content: "看这张图", imageDataURLs: ["data:image/png;base64,AAA"]),
    ])
    #expect(text == "ok")
    let bodyStr = String(data: Mock.body, encoding: .utf8) ?? ""
    #expect(bodyStr.contains("input_image"))
    #expect(bodyStr.contains("data:image/png;base64,AAA"))
}
