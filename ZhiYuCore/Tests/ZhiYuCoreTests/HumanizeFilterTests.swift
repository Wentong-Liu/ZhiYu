import Testing
@testable import ZhiYuCore

@Test func stripsSingleTrailingChinesePeriod() {
    #expect(HumanizeFilter.clean("好。") == "好")
}

@Test func keepsEllipsisOfTwoOrMorePeriods() {
    #expect(HumanizeFilter.clean("哈哈哈。。。") == "哈哈哈。。。")
    #expect(HumanizeFilter.clean("嗯。。") == "嗯。。")
}

@Test func stripsPerLineLastPeriodOnly() {
    #expect(HumanizeFilter.clean("在呢\n好的。") == "在呢\n好的")
}

@Test func leavesOtherPunctuationUntouched() {
    #expect(HumanizeFilter.clean("行！") == "行！")
    #expect(HumanizeFilter.clean("真的吗？") == "真的吗？")
    #expect(HumanizeFilter.clean("等等…") == "等等…")
}

@Test func noTrailingPeriodIsUnchanged() {
    #expect(HumanizeFilter.clean("好的") == "好的")
    #expect(HumanizeFilter.clean("在呢\n咋了") == "在呢\n咋了")
}

@Test func eachLineStrippedIndependently() {
    #expect(HumanizeFilter.clean("好。\n行。") == "好\n行")
}
