import Testing
@testable import ZhiYuCore

@Test func trailingOtherCountCountsConsecutiveTailOther() {
    let m: [ChatMessage] = [
        .init(speaker: .me, text: "在"),
        .init(speaker: .other, text: "a"),
        .init(speaker: .other, text: "b"),
        .init(speaker: .other, text: "c"),
    ]
    #expect(MessageRhythm.trailingOtherCount(m) == 3)
}

@Test func trailingOtherCountZeroWhenLastIsMe() {
    let m: [ChatMessage] = [.init(speaker: .other, text: "a"), .init(speaker: .me, text: "在")]
    #expect(MessageRhythm.trailingOtherCount(m) == 0)
    #expect(MessageRhythm.trailingOtherCount([]) == 0)
}

@Test func bubbleSplitterSplitsOnNewlinesTrimmedNonEmpty() {
    #expect(BubbleSplitter.split("在的\n咋了\n哈哈") == ["在的", "咋了", "哈哈"])
    #expect(BubbleSplitter.split("  好的  ") == ["好的"])
    #expect(BubbleSplitter.split("a\n\n  b ") == ["a", "b"])
}
