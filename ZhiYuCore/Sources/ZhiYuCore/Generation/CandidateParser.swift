import Foundation

/// 把模型原始输出解析为候选列表：优先 JSON 字符串数组，失败则按行兜底（去编号/项目符号）。
/// parse 的实际行为：逐项 trim → 去空 → 去掉「表情提示行」（行首 `表情:`/`表情：`）→ 保序去重 → 截断到 max 条。
public enum CandidateParser {
    public static func parse(_ raw: String, max: Int) -> [String] {
        var items = parseJSONArray(raw) ?? parseLines(raw)
        // 逐项 trim → 去空 → 去掉「表情提示行」(行首 表情:/表情：) → 保序去重（截断在 return 处取 prefix(max)）
        var seen = Set<String>()
        items = items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { $0.range(of: stickerPrefix, options: .regularExpression) == nil }
            .filter { seen.insert($0).inserted }
        return Array(items.prefix(max))
    }

    /// 匹配行首"表情: "前缀的共享子模式（半/全角冒号）：兜底过滤与 parseSticker 共用。
    private static let stickerPrefix = "^\\s*表情\\s*[:：]"

    /// 解析可选的"表情关键词"：匹配独立的一行 `表情: 关键词` / `表情：关键词`（半/全角冒号）。
    /// 去掉引号/方括号/书名号；否定词「无 / 没有 / none / n/a / 不需要」视为不建议表情，返回 nil。
    public static func parseSticker(_ raw: String) -> String? {
        // 多行模式下复用 stickerPrefix，并用捕获组直接取关键词。
        guard let re = try? NSRegularExpression(pattern: "(?m)" + stickerPrefix + "\\s*(.+)$"),
              let m = re.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let keywordRange = Range(m.range(at: 1), in: raw) else {
            return nil
        }
        var s = String(raw[keywordRange])
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'「」『』【】[]()（）"))
        let lowered = s.lowercased()
        if s.isEmpty || ["无", "没有", "none", "n/a", "不需要"].contains(lowered) { return nil }
        return s
    }

    /// 截取第一个 [ ... ] 区间按 JSON 字符串数组解析。
    private static func parseJSONArray(_ raw: String) -> [String]? {
        guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"), start < end else {
            return nil
        }
        let slice = String(raw[start...end])
        guard let data = slice.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return arr
    }

    /// 兜底：按行拆，去掉前导编号/项目符号/引号。
    private static func parseLines(_ raw: String) -> [String] {
        raw.split(whereSeparator: \.isNewline).map { line in
            var s = line.trimmingCharacters(in: .whitespaces)
            // 去前导 "1." / "2、" / "3)" / "-" / "•"
            if let r = s.range(of: "^\\s*([0-9]+[.、)]|[-•])\\s*", options: .regularExpression) {
                s.removeSubrange(r)
            }
            return s.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
    }
}
