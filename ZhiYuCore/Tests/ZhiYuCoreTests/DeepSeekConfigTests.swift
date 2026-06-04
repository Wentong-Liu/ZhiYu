import Testing
@testable import ZhiYuCore

@Test func deepSeekPresetHasExpectedBaseURL() {
    let c = ProviderConfig.deepSeek(model: "deepseek-v4-flash")
    #expect(c.name == "DeepSeek")
    #expect(c.baseURL == "https://api.deepseek.com")
    #expect(c.model == "deepseek-v4-flash")
}
