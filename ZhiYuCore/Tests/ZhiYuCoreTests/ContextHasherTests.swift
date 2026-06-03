import Testing
@testable import ZhiYuCore

private func ctx(contact: String = "张三",
                 msgs: [ChatMessage] = [ChatMessage(speaker: .other, text: "在吗")],
                 draft: String = "") -> ChatContext {
    ChatContext(contactName: contact, messages: msgs, draft: draft)
}

@Test func sameContextProducesSameKey() {
    #expect(ContextHasher.key(for: ctx()) == ContextHasher.key(for: ctx()))
}

@Test func keyIsStableHexOfFixedLength() {
    let key = ContextHasher.key(for: ctx())
    #expect(key.count == 64)                          // SHA256 hex
    #expect(key.allSatisfy { $0.isHexDigit })
}

@Test func differentDraftProducesDifferentKey() {
    let a = ContextHasher.key(for: ctx(draft: "稍等"))
    let b = ContextHasher.key(for: ctx(draft: "马上到"))
    #expect(a != b)                                   // 这是修正的核心：草稿影响 key
}

@Test func differentContactProducesDifferentKey() {
    #expect(ContextHasher.key(for: ctx(contact: "张三")) != ContextHasher.key(for: ctx(contact: "李四")))
}

@Test func whitespaceNoiseInMessagesIsNormalizedAway() {
    let clean = ctx(msgs: [ChatMessage(speaker: .other, text: "在吗")])
    let noisy = ctx(msgs: [ChatMessage(speaker: .other, text: "  在吗  ")])
    #expect(ContextHasher.key(for: clean) == ContextHasher.key(for: noisy))
}
