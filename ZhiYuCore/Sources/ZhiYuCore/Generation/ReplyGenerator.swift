import Foundation

/// 编排一次候选生成：去重缓存命中则复用，否则组 prompt→调模型→解析→存缓存。
public struct ReplyGenerator: Sendable {
    private let provider: any LLMProvider
    private let cache: CandidateCache
    private let candidateCount: Int

    public init(provider: any LLMProvider, cache: CandidateCache, candidateCount: Int = 3) {
        self.provider = provider
        self.cache = cache
        self.candidateCount = candidateCount
    }

    public func generate(context: ChatContext, style: ReplyStyle) async throws -> [String] {
        let key = ContextHasher.key(for: context) + "|style:" + style.name
            + "|n:\(candidateCount)|instr:" + style.instruction
        if let cached = cache.candidates(forKey: key) { return cached }
        let messages = PromptBuilder.build(context: context, style: style, candidateCount: candidateCount)
        let raw = try await provider.complete(messages: messages)
        let candidates = CandidateParser.parse(raw, max: candidateCount)
        cache.store(candidates, forKey: key)
        return candidates
    }
}
