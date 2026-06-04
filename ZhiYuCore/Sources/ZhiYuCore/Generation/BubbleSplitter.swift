import Foundation

public enum BubbleSplitter {
    /// 把一条候选（可能含换行）拆成多条气泡：按换行分、trim、去空。全空时退回整段(已 trim)。
    public static func split(_ text: String) -> [String] {
        let parts = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? [text.trimmingCharacters(in: .whitespacesAndNewlines)] : parts
    }
}
