import Testing
@testable import ZhiYuCore

/// 记录调用次数的假 provider。
final class CountingProvider: LLMProvider, @unchecked Sendable {
    private(set) var calls = 0
    let canned: String
    init(canned: String) { self.canned = canned }
    func complete(messages: [LLMMessage]) async throws -> String {
        calls += 1
        return canned
    }
}

private func ctx() -> ChatContext {
    ChatContext(contactName: "张婷",
                messages: [ChatMessage(speaker: .other, text: "在吗")],
                draft: "")
}

@Test func generatesParsedCandidates() async throws {
    let provider = CountingProvider(canned: "[\"在\",\"在的\",\"怎么了\"]")
    let gen = ReplyGenerator(provider: provider, cache: CandidateCache(), candidateCount: 3)
    let result = try await gen.generate(context: ctx(), style: .concise)
    #expect(result.candidates == ["在", "在的", "怎么了"])
    #expect(provider.calls == 1)
}

@Test func sameContextAndStyleHitsCacheNoSecondCall() async throws {
    let provider = CountingProvider(canned: "[\"在\"]")
    let cache = CandidateCache()
    let gen = ReplyGenerator(provider: provider, cache: cache, candidateCount: 3)
    _ = try await gen.generate(context: ctx(), style: .concise)
    _ = try await gen.generate(context: ctx(), style: .concise)
    #expect(provider.calls == 1)   // 第二次命中缓存
}

@Test func differentStyleMissesCache() async throws {
    let provider = CountingProvider(canned: "[\"在\"]")
    let gen = ReplyGenerator(provider: provider, cache: CandidateCache(), candidateCount: 3)
    _ = try await gen.generate(context: ctx(), style: .concise)
    _ = try await gen.generate(context: ctx(), style: .humorous)
    #expect(provider.calls == 2)   // 风格变 -> 重新生成
}

@Test func differentModelTagMissesCache() async throws {
    let provider = CountingProvider(canned: "[\"x\"]")
    let cache = CandidateCache()
    let g1 = ReplyGenerator(provider: provider, cache: cache, candidateCount: 3, modelTag: "deepseek/deepseek-v4-flash")
    _ = try await g1.generate(context: ctx(), style: .concise)
    let g2 = ReplyGenerator(provider: provider, cache: cache, candidateCount: 3, modelTag: "chatgpt/gpt-5.5")
    _ = try await g2.generate(context: ctx(), style: .concise)
    #expect(provider.calls == 2)   // 不同 modelTag -> 不命中缓存
}

@Test func sameModelTagHitsCache() async throws {
    let provider = CountingProvider(canned: "[\"x\"]")
    let cache = CandidateCache()
    let g1 = ReplyGenerator(provider: provider, cache: cache, candidateCount: 3, modelTag: "openai/gpt-4o")
    _ = try await g1.generate(context: ctx(), style: .concise)
    let g2 = ReplyGenerator(provider: provider, cache: cache, candidateCount: 3, modelTag: "openai/gpt-4o")
    _ = try await g2.generate(context: ctx(), style: .concise)
    #expect(provider.calls == 1)   // 同 modelTag -> 命中缓存
}
