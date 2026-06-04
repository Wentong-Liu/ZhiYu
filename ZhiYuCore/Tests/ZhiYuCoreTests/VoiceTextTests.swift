import Testing
@testable import ZhiYuCore

@Test func voiceTextReturnsTranscriptAfterFullWidthColon() {
    #expect(VoiceText.clean("发送了一个语音,时长:21秒,已读,已转文字：对一个地方不一样") == "对一个地方不一样")
}

@Test func voiceTextReturnsTranscriptAfterHalfWidthColon() {
    #expect(VoiceText.clean("发送了一个语音,时长:5秒,已读,已转文字:半角冒号转写") == "半角冒号转写")
}

@Test func voiceTextReturnsPlaceholderWhenNoTranscript() {
    #expect(VoiceText.clean("发送了一个语音,时长:14秒,已读") == "[语音]")
}

@Test func voiceTextReturnsTextUnchangedWhenNotVoice() {
    #expect(VoiceText.clean("好的呀") == "好的呀")
}
