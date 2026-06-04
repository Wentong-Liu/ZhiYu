import Testing
@testable import ZhiYuCore

@Suite struct MessageSignalTests {
    private func ctx(_ msgs: [ChatMessage]) -> ChatContext {
        ChatContext(contactName: "x", messages: msgs, draft: "")
    }
    @Test func lastIsIncomingTrueWhenOtherSpokeLast() {
        #expect(MessageSignal.lastIsIncoming(ctx([ChatMessage(speaker: .me, text: "在"), ChatMessage(speaker: .other, text: "你好")])))
    }
    @Test func lastIsIncomingFalseWhenIWroteLast() {
        #expect(!MessageSignal.lastIsIncoming(ctx([ChatMessage(speaker: .other, text: "你好"), ChatMessage(speaker: .me, text: "在")])))
    }
    @Test func lastIsIncomingFalseWhenEmpty() {
        #expect(!MessageSignal.lastIsIncoming(ctx([])))
    }
    @Test func signatureChangesWhenNewMessageArrives() {
        let a = MessageSignal.signature(ctx([ChatMessage(speaker: .other, text: "你好")]))
        let b = MessageSignal.signature(ctx([ChatMessage(speaker: .other, text: "你好"), ChatMessage(speaker: .other, text: "在吗")]))
        #expect(a != b)
    }
    @Test func signatureStableForSameContent() {
        let m = [ChatMessage(speaker: .other, text: "你好")]
        #expect(MessageSignal.signature(ctx(m)) == MessageSignal.signature(ctx(m)))
    }
}
