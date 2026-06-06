import Testing
@testable import ZhiYuCore

@Suite struct StickerReplyTests {
    @Test func parseStickerExtractsKeyword() {
        let raw = "[\"在的\",\"咋了\"]\n表情: 报警"
        #expect(CandidateParser.parseSticker(raw) == "报警")
    }
    @Test func parseStickerFullWidthColonAndQuotes() {
        #expect(CandidateParser.parseSticker("[]\n表情：「笑死」") == "笑死")
    }
    @Test func parseStickerNilWhenAbsent() {
        #expect(CandidateParser.parseSticker("[\"好的\"]") == nil)
    }
    @Test func parseStickerNilWhenNone() {
        #expect(CandidateParser.parseSticker("[\"好的\"]\n表情: 无") == nil)
    }
    @Test func parseCandidatesIgnoresStickerLineInLineFallback() {
        // 非 JSON 兜底路径也不能把"表情:xxx"当候选
        let raw = "好的\n在的\n表情: 报警"
        let items = CandidateParser.parse(raw, max: 5)
        #expect(items == ["好的", "在的"])
    }
    @Test func generateReturnsResultWithSticker() async throws {
        let provider = StubProvider(raw: "[\"哈哈\",\"笑死\"]\n表情: 笑死")
        let cache = CandidateCache()
        let gen = ReplyGenerator(provider: provider, cache: cache, candidateCount: 2, modelTag: "t")
        let ctx = ChatContext(contactName: "x", messages: [ChatMessage(speaker: .other, text: "你看这个")], draft: "")
        let r = try await gen.generate(context: ctx, style: .natural)
        #expect(r.candidates == ["哈哈", "笑死"])
        #expect(r.stickerKeyword == "笑死")
        // 缓存命中也应保留关键词
        let r2 = try await gen.generate(context: ctx, style: .natural)
        #expect(r2.stickerKeyword == "笑死")
    }
}

private struct StubProvider: LLMProvider {
    let raw: String
    func complete(messages: [LLMMessage]) async throws -> String { raw }
}
