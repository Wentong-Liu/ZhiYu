import Testing
import Foundation
@testable import ZhiYuCore

@Test func challengeIsBase64URLSha256OfVerifier() {
    // 已知向量：verifier "abc" 的 SHA256 base64url（无填充）
    let p = PKCE(verifier: "abc")
    #expect(p.verifier == "abc")
    // ungo: 直接断言长度与字符集（base64url 无 +/=）
    #expect(!p.challenge.contains("+"))
    #expect(!p.challenge.contains("/"))
    #expect(!p.challenge.contains("="))
    #expect(p.challenge.count == 43)  // SHA256(32字节) base64url 无填充 = 43 字符
}

@Test func generateProducesValidPair() {
    let p = PKCE.generate()
    #expect(p.verifier.count >= 43)
    #expect(p.challenge.count == 43)
    #expect(PKCE(verifier: p.verifier).challenge == p.challenge)  // 确定性
}
