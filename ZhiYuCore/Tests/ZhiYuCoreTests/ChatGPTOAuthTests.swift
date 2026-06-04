import Testing
import Foundation
@testable import ZhiYuCore

@Test func authorizeURLContainsRequiredParams() {
    let pkce = PKCE(verifier: "abc")
    let url = ChatGPTOAuth.authorizeURL(pkce: pkce, state: "st123")
    let s = url.absoluteString
    #expect(s.hasPrefix("https://auth.openai.com/oauth/authorize?"))
    #expect(s.contains("client_id=app_EMoamEEZ73f0CkXaXp7hrann"))
    #expect(s.contains("code_challenge_method=S256"))
    #expect(s.contains("code_challenge=\(pkce.challenge)"))
    #expect(s.contains("codex_cli_simplified_flow=true"))
    #expect(s.contains("originator=openclaw"))
    #expect(s.contains("state=st123"))
}

@Test func accountIDExtractedFromJWTAuthClaim() {
    // 构造 JWT：header.payload.sig，payload 含 https://api.openai.com/auth.chatgpt_account_id
    func b64url(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    let payload = "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct-xyz\"}}"
    let jwt = "h." + b64url(payload) + ".s"
    #expect(ChatGPTOAuth.accountID(fromJWT: jwt) == "acct-xyz")
    #expect(ChatGPTOAuth.accountID(fromJWT: "not-a-jwt") == nil)
}

@Test func tokenExchangeRequestIsFormEncoded() {
    let req = ChatGPTOAuth.tokenExchangeRequest(code: "C1", verifier: "V1")
    #expect(req.url?.absoluteString == "https://auth.openai.com/oauth/token")
    #expect(req.httpMethod == "POST")
    #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    let body = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
    #expect(body.contains("grant_type=authorization_code"))
    #expect(body.contains("code=C1"))
    #expect(body.contains("code_verifier=V1"))
    #expect(body.contains("client_id=app_EMoamEEZ73f0CkXaXp7hrann"))
}

@Test func parseTokenResponseBuildsTokens() throws {
    func b64url(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    let access = "h." + b64url("{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct-1\"}}") + ".s"
    let json = "{\"access_token\":\"\(access)\",\"refresh_token\":\"R1\",\"id_token\":\"x.y.z\",\"expires_in\":3600}"
    let tokens = try ChatGPTOAuth.parseTokenResponse(Data(json.utf8))
    #expect(tokens.accessToken == access)
    #expect(tokens.refreshToken == "R1")
    #expect(tokens.accountId == "acct-1")
    #expect(tokens.isExpired(now: Date()) == false)
    #expect(tokens.isExpired(now: Date().addingTimeInterval(4000)) == true)
}
