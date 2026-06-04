import Testing
@testable import ZhiYuCore

@Test func openAIPresetHasExpectedBaseURL() {
    let c = ProviderConfig.openAI(model: "gpt-4o")
    #expect(c.name == "OpenAI")
    #expect(c.baseURL == "https://api.openai.com/v1")
    #expect(c.model == "gpt-4o")
}

@Test func llmMessageRoleRawValues() {
    #expect(LLMMessage.Role.system.rawValue == "system")
    #expect(LLMMessage.Role.user.rawValue == "user")
    #expect(LLMMessage.Role.assistant.rawValue == "assistant")
    let m = LLMMessage(role: .user, content: "hi")
    #expect(m.content == "hi")
}
