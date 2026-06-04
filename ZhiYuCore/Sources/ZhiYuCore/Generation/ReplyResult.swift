import Foundation

/// 一次生成的结果：文字候选 + 可选的"表情关键词"（模型觉得适合配表情时给）。
public struct ReplyResult: Sendable, Equatable {
    public let candidates: [String]
    public let stickerKeyword: String?
    public init(candidates: [String], stickerKeyword: String?) {
        self.candidates = candidates
        self.stickerKeyword = stickerKeyword
    }
}
