import Foundation

/// 把模型原始输出解析为候选列表：优先 JSON 字符串数组，失败则按行兜底（去编号/项目符号）。
/// parse 的实际行为：逐项 trim → 去空 → 去掉「表情提示行」（行首 `表情:`/`表情：`）→ 保序去重 → 截断到 max 条。
///
/// 解析契约由 PromptBuilder 的 system prompt 约定（"只返回一个 JSON 数组" / 表情提示行另起一行写「表情: 关键词」）：
/// 改这里的 JSON 解析或 stickerPrefix 前缀，必须同步检查 PromptBuilder 的对应文案。
public enum CandidateParser {
    public static func parse(_ raw: String, max: Int) -> [String] {
        var items = parseJSONArray(raw) ?? parseLines(raw)
        // 逐项 trim → 去空 → 去掉「表情提示行」(行首 表情:/表情：) → 保序去重（截断在 return 处取 prefix(max)）
        var seen = Set<String>()
        items = items
            // 这里 trim 的是「整条候选项」（内部可能含 \n 作为多气泡分隔），故用 whitespacesAndNewlines 去掉首尾换行；
            // 切勿与 parseLines / BubbleSplitter 的逐行 .whitespaces trim 合并——后者已按行切分，语义不同。
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { $0.range(of: stickerPrefix, options: .regularExpression) == nil }
            .filter { seen.insert($0).inserted }
        return Array(items.prefix(max))
    }

    /// 匹配行首"表情: "前缀的共享子模式（半/全角冒号）：兜底过滤与 parseSticker 共用。
    private static let stickerPrefix = "^\\s*表情\\s*[:：]"

    /// parseSticker 的捕获正则（多行模式 + 捕获组取关键词），预编译为静态常量避免每次调用重建。
    private static let stickerKeywordRegex = try? NSRegularExpression(
        pattern: "(?m)" + stickerPrefix + "\\s*(.+)$"
    )

    /// 否定词集合：命中即视为「不建议表情」，parseSticker 返回 nil（比较前先 lowercased）。
    private static let negativeStickerKeywords: Set<String> = ["无", "没有", "none", "n/a", "不需要"]

    /// 解析可选的"表情关键词"：匹配独立的一行 `表情: 关键词` / `表情：关键词`（半/全角冒号）。
    /// 去掉引号/方括号/书名号；否定词「无 / 没有 / none / n/a / 不需要」视为不建议表情，返回 nil。
    public static func parseSticker(_ raw: String) -> String? {
        // 多行模式下复用 stickerPrefix，并用捕获组直接取关键词。
        guard let re = stickerKeywordRegex,
              let m = re.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let keywordRange = Range(m.range(at: 1), in: raw) else {
            return nil
        }
        var s = String(raw[keywordRange])
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'「」『』【】[]()（）"))
        let lowered = s.lowercased()
        if s.isEmpty || negativeStickerKeywords.contains(lowered) { return nil }
        return s
    }

    /// 解析 JSON 字符串数组。
    /// 先对整串直接试解码（处理候选文本含 `]`「[图片]」等会让粗暴切片切错的情况），
    /// 失败再从第一个 `[` 起做中括号配平（忽略字符串字面量内部的括号）取到匹配收尾的 `]` 再解码。
    private static func parseJSONArray(_ raw: String) -> [String]? {
        // 1) 整串直接试：合法输入（无包裹文本）一步到位，且不会被内容里的 ] 误切。
        if let arr = decodeStringArray(raw) { return arr }
        // 2) 配平提取最外层 [...]，对字符串字面量内的括号免疫。
        guard let slice = balancedArraySlice(raw), let arr = decodeStringArray(slice) else {
            NSLog("[ZhiYu][CandidateParser] parseJSONArray decode failed, falling back to line parsing")
            return nil
        }
        return arr
    }

    /// 尝试把一段文本按 `[String]` JSON 解码，失败返回 nil。
    private static func decodeStringArray(_ s: String) -> [String]? {
        guard let data = s.data(using: .utf8) else { return nil }
        if let arr = try? JSONDecoder().decode([String].self, from: data) { return arr }
        // 契约违例区分（不改控制流，仍返回 nil 走 parseLines 兜底）：
        // 是合法 JSON 数组、但元素不是字符串（如 [1,2] / [{...}]）→ 模型违反「只返回字符串数组」约定，单独记一条便于排查。
        if (try? JSONSerialization.jsonObject(with: data)) is [Any] {
            NSLog("[ZhiYu][CandidateParser] JSON 数组元素非字符串，违反字符串数组约定，降级按行解析")
        }
        return nil
    }

    /// 从第一个 `[` 起做中括号配平，返回包含匹配收尾 `]` 的子串；忽略 JSON 字符串字面量内部的括号与转义。
    private static func balancedArraySlice(_ raw: String) -> String? {
        guard let start = raw.firstIndex(of: "[") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var idx = start
        while idx < raw.endIndex {
            let ch = raw[idx]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                switch ch {
                case "\"": inString = true
                case "[": depth += 1
                case "]":
                    depth -= 1
                    if depth == 0 {
                        return String(raw[start...idx])
                    }
                default: break
                }
            }
            idx = raw.index(after: idx)
        }
        return nil
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
