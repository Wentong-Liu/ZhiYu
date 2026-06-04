import Testing
@testable import ZhiYuCore

@Test func chatContextCarriesImageDataURLs() {
    let c = ChatContext(contactName: "张婷",
                        messages: [ChatMessage(speaker: .other, text: "[图片]")],
                        draft: "",
                        imageDataURLs: ["data:image/png;base64,AAA"])
    #expect(c.imageDataURLs == ["data:image/png;base64,AAA"])
}

@Test func chatContextDefaultsToNoImages() {
    let c = ChatContext(contactName: "x", messages: [], draft: "")
    #expect(c.imageDataURLs.isEmpty)
}

@Test func llmMessageCarriesImages() {
    let m = LLMMessage(role: .user, content: "hi", imageDataURLs: ["data:img"])
    #expect(m.imageDataURLs == ["data:img"])
    #expect(LLMMessage(role: .user, content: "hi").imageDataURLs.isEmpty)
}

@Test func voiceTextMarksImageAndSticker() {
    #expect(VoiceText.clean("发送了一个图片") == "[图片]")
    #expect(VoiceText.clean("发送了一个表情") == "[表情]")
    #expect(VoiceText.clean("我感冒了[流泪]") == "我感冒了[流泪]")   // 内联 emoji 不动
}
