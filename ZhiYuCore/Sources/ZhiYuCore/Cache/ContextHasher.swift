import Foundation
import CryptoKit

/// 由对话上下文计算稳定、可测的缓存 key。
///
/// key 纳入 (联系人 + 规整化消息 + 草稿 + 图片)。草稿必须纳入：它是回复生成的 prompt 输入，
/// 若不计入则改了草稿会命中过时候选。图片同理纳入：imageDataURLs 也是视觉模型的输入，
/// 若不计入则「同文不同图」会命中过期候选；按原顺序逐个并入（追加在 messages/draft 之后，
/// 不重排既有组成，保证同文且同图仍命中）。
public enum ContextHasher {
    public static func key(for context: ChatContext) -> String {
        var parts: [String] = []
        parts.append("contact:" + normalize(context.contactName))
        for m in context.messages {
            parts.append(m.speaker.rawValue + ":" + normalize(m.text))
        }
        parts.append("draft:" + normalize(context.draft))
        // 图片以稳定方式（按原顺序、各自内容哈希）并入，区分「同文不同图」；
        // 哈希而非拼原文，避免 base64 data URL 让 key 输入膨胀。
        for url in context.imageDataURLs {
            parts.append("image:" + sha256Hex(url))
        }
        let joined = parts.joined(separator: "\n")
        return sha256Hex(joined)
    }

    /// 对字符串取 SHA256 并返回小写十六进制串。
    private static func sha256Hex(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 去掉首尾空白、把内部连续空白折叠为单空格，消除无意义抖动。
    private static func normalize(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = trimmed.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed
    }
}
