import Testing
import Foundation
@testable import ZhiYuCore

@Test func chatContextIsValueEquatable() {
    let a = ChatContext(
        contactName: "张三",
        messages: [ChatMessage(speaker: .other, text: "在吗"),
                   ChatMessage(speaker: .me, text: "在")],
        draft: "稍等"
    )
    let b = ChatContext(
        contactName: "张三",
        messages: [ChatMessage(speaker: .other, text: "在吗"),
                   ChatMessage(speaker: .me, text: "在")],
        draft: "稍等"
    )
    #expect(a == b)
    #expect(a.messages.first?.speaker == .other)
}

@Test func chatContextRoundTripsThroughCodable() throws {
    let original = ChatContext(
        contactName: "李四",
        messages: [ChatMessage(speaker: .me, text: "你好")],
        draft: ""
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ChatContext.self, from: data)
    #expect(decoded == original)
}
