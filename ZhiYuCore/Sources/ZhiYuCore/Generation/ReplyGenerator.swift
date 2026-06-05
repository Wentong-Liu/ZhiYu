import Foundation

/// 编排一次候选生成：去重缓存命中则复用，否则组 prompt→调模型→解析→存缓存。
/// 缓存 key 纳入 modelTag（Provider+模型），切换模型不会误命中旧缓存。
public struct ReplyGenerator: Sendable {
    /// 默认候选数：面板展示数、键盘 1/2/3 上限与生成数共用这一来源，避免各处各写 3 而漂移。
    public static let defaultCandidateCount = 3

    private let provider: any LLMProvider
    private let cache: CandidateCache
    private let candidateCount: Int
    private let modelTag: String

    public init(provider: any LLMProvider, cache: CandidateCache,
                candidateCount: Int = ReplyGenerator.defaultCandidateCount, modelTag: String = "") {
        self.provider = provider
        self.cache = cache
        self.candidateCount = candidateCount
        self.modelTag = modelTag
    }

    public func generate(context: ChatContext, style: ReplyStyle) async throws -> ReplyResult {
        let key = ContextHasher.key(for: context)
            + "|style:" + style.name
            + "|n:\(candidateCount)"
            + "|instr:" + style.instruction
            + "|model:" + modelTag
        if let cached = cache.candidates(forKey: key) {
            return ReplyResult(candidates: cached, stickerKeyword: cache.stickerKeyword(forKey: key))
        }
        let messages = PromptBuilder.build(context: context, style: style, candidateCount: candidateCount)
        let raw = try await provider.complete(messages: messages)
        let candidates = CandidateParser.parse(raw, max: candidateCount).map(HumanizeFilter.clean)
        let sticker = CandidateParser.parseSticker(raw)
        cache.store(candidates, forKey: key)
        cache.storeSticker(sticker, forKey: key)
        return ReplyResult(candidates: candidates, stickerKeyword: sticker)
    }
}
