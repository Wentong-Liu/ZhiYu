import Foundation

/// 候选文本的轻量「去机器味」后处理：只做最安全的一项，避免误伤。
/// 规则：把候选按换行拆成小消息，对每条小消息只去掉**结尾恰好一个**中文句号「。」；
/// 若结尾是两个及以上句号（省略号「。。」「。。。」）则保留；其它标点（！？…）一律不动。
/// 再用换行拼回。表情关键词那条不会走到这里（CandidateParser 已过滤）。
public enum HumanizeFilter {
    public static func clean(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { cleanLine(String($0)) }
            .joined(separator: "\n")
    }

    /// 单条小消息：仅当结尾正好一个「。」时去掉；连续两个及以上保留（视为省略号）。
    private static func cleanLine(_ line: String) -> String {
        guard line.hasSuffix("。") else { return line }
        let dropped = String(line.dropLast())
        // 去掉一个后若仍以「。」结尾，说明原本是两个及以上句号 -> 还原不动。
        if dropped.hasSuffix("。") { return line }
        return dropped
    }
}
