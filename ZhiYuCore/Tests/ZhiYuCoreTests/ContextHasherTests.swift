import Testing
@testable import ZhiYuCore

private func ctx(contact: String = "张三",
                 msgs: [ChatMessage] = [ChatMessage(speaker: .other, text: "在吗")],
                 draft: String = "",
                 images: [String] = []) -> ChatContext {
    ChatContext(contactName: contact, messages: msgs, draft: draft, imageDataURLs: images)
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

// (a) 同 messages/draft/contact 但 imageDataURLs 不同 → key 不同（不跨命中，修同文不同图误命中）。
@Test func differentImagesProduceDifferentKey() {
    let a = ContextHasher.key(for: ctx(images: ["data:image/png;base64,AAAA"]))
    let b = ContextHasher.key(for: ctx(images: ["data:image/png;base64,BBBB"]))
    #expect(a != b)
}

// 无图 vs 有图也应区分（图片纳入 key 输入）。
@Test func noImageVsWithImageProducesDifferentKey() {
    let none = ContextHasher.key(for: ctx(images: []))
    let one = ContextHasher.key(for: ctx(images: ["data:image/png;base64,AAAA"]))
    #expect(none != one)
}

// 图片顺序不同 → key 不同（按原顺序稳定并入，不做集合化）。
@Test func differentImageOrderProducesDifferentKey() {
    let ab = ContextHasher.key(for: ctx(images: ["data:image/png;base64,AAAA", "data:image/png;base64,BBBB"]))
    let ba = ContextHasher.key(for: ctx(images: ["data:image/png;base64,BBBB", "data:image/png;base64,AAAA"]))
    #expect(ab != ba)
}

// (b) 一切相同含相同 images → key 相同（仍命中）。
@Test func sameContextWithSameImagesProducesSameKey() {
    let imgs = ["data:image/png;base64,AAAA", "data:image/png;base64,BBBB"]
    #expect(ContextHasher.key(for: ctx(images: imgs)) == ContextHasher.key(for: ctx(images: imgs)))
}
