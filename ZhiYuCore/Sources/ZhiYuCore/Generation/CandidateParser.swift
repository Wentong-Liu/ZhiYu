import Foundation

/// 把模型原始输出解析为候选列表：优先 JSON 字符串数组，失败则按行兜底（去编号/项目符号）。
public enum CandidateParser {
    public static func parse(_ raw: String, max: Int) -> [String] {
        var items = parseJSONArray(raw) ?? parseLines(raw)
        // trim + 去空 + 去重（保序）
        var seen = Set<String>()
        items = items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
        return Array(items.prefix(max))
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
