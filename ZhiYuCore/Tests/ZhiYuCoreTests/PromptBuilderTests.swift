import Testing
@testable import ZhiYuCore

private func sampleContext(draft: String = "") -> ChatContext {
    ChatContext(
        contactName: "张婷",
        messages: [
            ChatMessage(speaker: .other, text: "你咋不看我给你发的抖音"),
            ChatMessage(speaker: .me, text: "我好像感冒了"),
            ChatMessage(speaker: .other, text: "那你早点睡"),
        ],
        draft: draft)
}

@Test func systemMessageContainsStyleAndCountAndLanguageRule() {
    let msgs = PromptBuilder.build(context: sampleContext(), style: .humorous, candidateCount: 3)
    #expect(msgs.first?.role == .system)
    let sys = msgs.first?.content ?? ""
    #expect(sys.contains("适度幽默"))      // 风格 instruction
    #expect(sys.contains("3"))             // 候选数量
    #expect(sys.contains("对话所用语言"))   // 语言规则
}

@Test func userMessageRendersConversationWithSpeakers() {
    let msgs = PromptBuilder.build(context: sampleContext(), style: .concise, candidateCount: 3)
    let user = msgs.last?.content ?? ""
    #expect(msgs.last?.role == .user)
    #expect(user.contains("对方: 你咋不看我给你发的抖音"))
    #expect(user.contains("我: 我好像感冒了"))
}

@Test func draftIsIncludedWhenPresent() {
    let withDraft = PromptBuilder.build(context: sampleContext(draft: "我在想"), style: .concise, candidateCount: 3)
    let withDraftUser = withDraft.last?.content ?? ""
    #expect(withDraftUser.contains("我在想"))
    let without = PromptBuilder.build(context: sampleContext(draft: ""), style: .concise, candidateCount: 3)
    let withoutUser = without.last?.content ?? ""
    let mentionsDraft = withoutUser.contains("草稿")
    #expect(mentionsDraft == false)
}

@Test func systemMentionsMultiBubbleWhenOtherSentSeveral() {
    let ctx = ChatContext(
        contactName: "张婷",
        messages: [
            ChatMessage(speaker: .me, text: "在"),
            ChatMessage(speaker: .other, text: "在吗"),
            ChatMessage(speaker: .other, text: "出来玩不"),
            ChatMessage(speaker: .other, text: "就现在"),
        ],
        draft: "")
    let sys = PromptBuilder.build(context: ctx, style: .concise, candidateCount: 3).first?.content ?? ""
    #expect(sys.contains("连发"))      // 提到对方连发
    #expect(sys.contains("3"))         // 连发条数(也=候选数，均为3)
    #expect(sys.contains("换行"))      // 多气泡用换行分隔
}
