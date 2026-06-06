import Testing
@testable import ZhiYuCore

@Test func parsesJSONArray() {
    let raw = "[\"好的\",\"稍等\",\"马上到\"]"
    #expect(CandidateParser.parse(raw, max: 3) == ["好的", "稍等", "马上到"])
}

@Test func parsesJSONArrayWrappedInText() {
    let raw = "当然可以：\n[\"嗯嗯\", \"在的\"]\n希望有用"
    #expect(CandidateParser.parse(raw, max: 3) == ["嗯嗯", "在的"])
}

@Test func fallbackParsesNumberedLines() {
    let raw = "1. 好的\n2、稍等\n3) 马上到"
    #expect(CandidateParser.parse(raw, max: 3) == ["好的", "稍等", "马上到"])
}

@Test func capsToMaxAndTrimsAndDedups() {
    let raw = "[\"a\",\"a\",\"  b  \",\"c\",\"d\"]"
    #expect(CandidateParser.parse(raw, max: 3) == ["a", "b", "c"])
}

/// 候选文本里含 `]`（旧实现用 lastIndex(']') 截最外层会切错收尾，导致整段解码失败回落）。
@Test func parsesJSONArrayWhenCandidateContainsRightBracket() {
    let raw = "[\"好的]\",\"在呢\"]"
    #expect(CandidateParser.parse(raw, max: 3) == ["好的]", "在呢"])
}

/// 候选文本含「[图片]」字样：内部既有 `[` 又有 `]`，配平提取须取到真正的收尾括号。
@Test func parsesJSONArrayWhenCandidateContainsImagePlaceholder() {
    let raw = "[\"收到[图片]\",\"嗯嗯\"]"
    #expect(CandidateParser.parse(raw, max: 3) == ["收到[图片]", "嗯嗯"])
}

/// 含 `]` 的候选 + 外层包裹解释文本：先整串解码失败，再走配平提取。
@Test func parsesJSONArrayWithRightBracketWrappedInText() {
    let raw = "这是建议：\n[\"稍等[1]\",\"马上\"]\n请参考"
    #expect(CandidateParser.parse(raw, max: 3) == ["稍等[1]", "马上"])
}
