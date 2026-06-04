import Testing
@testable import ZhiYuCore

@Test func presetsContainConciseAndAreNonEmpty() {
    #expect(ReplyStyle.presets.count == 5)
    #expect(ReplyStyle.presets.contains { $0.name == "简洁" })
    #expect(ReplyStyle.presets.allSatisfy { !$0.instruction.isEmpty })
}

@Test func customStyleCarriesInstruction() {
    let s = ReplyStyle.custom("像东北老铁那样说话")
    #expect(s.name == "自定义")
    #expect(s.instruction == "像东北老铁那样说话")
}
