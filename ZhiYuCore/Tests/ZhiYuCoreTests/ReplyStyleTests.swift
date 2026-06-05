import Testing
@testable import ZhiYuCore

@Test func presetsAreFiveAndNonEmptyWithNaturalDefaultFirst() {
    #expect(ReplyStyle.presets.count == 5)
    #expect(ReplyStyle.presets.first?.name == "自然")        // 默认在第一位
    #expect(ReplyStyle.default.name == "自然")
    #expect(ReplyStyle.presets.contains { $0.name == "简短" })
    #expect(ReplyStyle.presets.allSatisfy { !$0.instruction.isEmpty })
}

@Test func presetNamedFallsBackToNaturalForUnknownName() {
    #expect(ReplyStyle.preset(named: "简短").name == "简短")
    #expect(ReplyStyle.preset(named: "友好").name == "自然")   // 旧名/未知名 -> 兜底自然
    #expect(ReplyStyle.preset(named: "").name == "自然")
}

@Test func customStyleCarriesInstruction() {
    let s = ReplyStyle.custom("像东北老铁那样说话")
    #expect(s.name == "自定义")
    #expect(s.instruction == "像东北老铁那样说话")
}
