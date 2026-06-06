import Foundation

/// 与 PromptBuilder 的「\n 分隔小消息」契约对应：模型按 system prompt 要求在候选内用换行分隔多条小消息，
/// 这里据此把单条候选拆成多条气泡发送。改换行分隔约定时，须同步 PromptBuilder 的对应文案。
public enum BubbleSplitter {
    /// 把一条候选（可能含换行）拆成多条气泡：按换行分、trim、去空。全空时退回整段(已 trim)。
    public static func split(_ text: String) -> [String] {
        let parts = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? [text.trimmingCharacters(in: .whitespacesAndNewlines)] : parts
    }
}
