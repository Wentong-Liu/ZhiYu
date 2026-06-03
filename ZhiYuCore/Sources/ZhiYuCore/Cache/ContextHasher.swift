import Foundation
import CryptoKit

/// 由对话上下文计算稳定、可测的缓存 key。
///
/// key 纳入 (联系人 + 规整化消息 + 草稿)。草稿必须纳入：它是回复生成的 prompt 输入，
/// 若不计入则改了草稿会命中过时候选。
public enum ContextHasher {
    public static func key(for context: ChatContext) -> String {
        var parts: [String] = []
        parts.append("contact:" + normalize(context.contactName))
        for m in context.messages {
            parts.append(m.speaker.rawValue + ":" + normalize(m.text))
        }
        parts.append("draft:" + normalize(context.draft))
        let joined = parts.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 去掉首尾空白、把内部连续空白折叠为单空格，消除无意义抖动。
    private static func normalize(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = trimmed.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed
    }
}
