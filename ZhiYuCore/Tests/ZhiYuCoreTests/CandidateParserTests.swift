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
