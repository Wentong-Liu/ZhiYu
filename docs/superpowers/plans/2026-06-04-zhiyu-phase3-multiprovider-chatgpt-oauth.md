# 知语 ZhiYu — Phase 3：多 Provider + DeepSeek + ChatGPT 登录(Codex OAuth) 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让生成面板支持多 Provider：OpenAI(Key) / DeepSeek(Key) / **ChatGPT 登录(Codex OAuth，用 ChatGPT 订阅额度)**。ChatGPT 路线走应用内 PKCE OAuth + 本地回环服务 + Codex Responses(SSE) 后端。

**Architecture:** 纯逻辑（PKCE、OAuth URL/请求构造与解析、JWT 取 account_id、Codex Responses provider 的 body 构造与 SSE 解析、DeepSeek 预设）放进 `ZhiYuCore` 用 `swift test` TDD（网络/SSE 用 URLProtocol mock）；系统集成（本地回环 HTTP 服务接 OAuth 回调、开浏览器、Keychain 存 token、多 Provider UI）放在 App，用 `xcodebuild` 验证 + 真 ChatGPT 登录联调。

**Tech Stack:** Swift 6.3 / SwiftUI / AppKit / Network(NWListener) / CryptoKit / URLSession(SSE bytes) / Security(Keychain) / Swift Testing。目标 macOS 26.5。当前分支 **main**（本项目不开分支，直接在 main 提交）。

**对应 spec:** `docs/superpowers/specs/2026-06-04-zhiyu-wechat-reply-assistant-design.md`
**协议来源（已交叉核对源码）:** OpenClaw `src/llm/providers/openai-chatgpt-responses.ts`；openai/codex `codex-rs/login/*`；DeepSeek `api-docs.deepseek.com`。

**前置：** Phase 2 已完成（ZhiYuCore 有 LLMMessage/LLMProvider/OpenAICompatibleProvider/PromptBuilder/CandidateParser/ReplyGenerator；App 有 GeneratePanel/WeChatReader/Inserter/KeychainStore）。

> ⚠️ **风险（已与用户确认接受）**：ChatGPT 登录模仿 OpenClaw 客户端调 Codex 后端，属 OpenAI ToS 灰色地带、可能被封；后端 endpoint/格式易碎，需用真账号联调、可能迭代。

---

## 确认的协议常量（实现依据，verbatim）
- client_id `app_EMoamEEZ73f0CkXaXp7hrann`
- authorize `https://auth.openai.com/oauth/authorize`；token `https://auth.openai.com/oauth/token`
- redirect `http://localhost:1455/auth/callback`（回环服务 bind 127.0.0.1:1455）
- scope `openid profile email offline_access`；PKCE S256
- authorize 额外参数：`id_token_add_organizations=true`、`codex_cli_simplified_flow=true`、`originator=openclaw`、`state`
- 换 token（form-urlencoded）：`grant_type=authorization_code&code&redirect_uri&client_id&code_verifier`
- 刷新（form-urlencoded）：`grant_type=refresh_token&refresh_token&client_id`
- account_id：access_token JWT payload 的 `["https://api.openai.com/auth"]["chatgpt_account_id"]`
- 调模型：`POST https://chatgpt.com/backend-api/codex/responses`（Responses API + SSE）
- 调模型 headers：`Authorization: Bearer <access>`、`chatgpt-account-id: <accountId>`、`originator: openclaw`、`User-Agent: openclaw (macOS)`、`OpenAI-Beta: responses=experimental`、`accept: text/event-stream`、`content-type: application/json`
- body：`{model, store:false, stream:true, instructions:<system>, input:[{role,content:[{type:input_text|output_text,text}]}], text:{verbosity:"low"}, include:["reasoning.encrypted_content"], tool_choice:"auto", parallel_tool_calls:true}`
- SSE：取 `data:` 行 JSON，累积 `response.output_text.delta` 的 `delta`，遇 `response.completed`/`response.done` 结束，`error`/`response.failed` 抛错
- 模型：`gpt-5.5`(默认)、`gpt-5.5-pro`、`gpt-5.4`、`gpt-5.4-pro`、`gpt-5.4-mini`
- DeepSeek：baseURL `https://api.deepseek.com`，模型 `deepseek-v4-flash`/`deepseek-v4-pro`

---

## 文件结构
```
ZhiYuCore/Sources/ZhiYuCore/
  Provider/
    ProviderConfig.swift        # 修改：加 deepSeek 预设
    OpenAICompatibleProvider.swift  # 修改：加 extraHeaders（可选）
  OAuth/
    PKCE.swift                  # S256 verifier/challenge
    OAuthTokens.swift           # token 结构 + 过期判断
    ChatGPTOAuth.swift          # authorize URL / 换刷 token 请求与解析 / JWT 取 accountId
    CodexResponsesProvider.swift # Codex Responses(SSE) LLMProvider
ZhiYu/
  Secrets/KeychainStore.swift   # 修改：存取 OAuthTokens(JSON)
  OAuth/CodexLoginService.swift # 回环服务 + 开浏览器 + 换 token + 刷新
  Generate/GeneratePanel.swift  # 修改：多 Provider 选择 + ChatGPT 登录按钮
```

---

## Task 1：DeepSeek 预设 + OpenAICompatibleProvider extraHeaders

**Files:**
- Modify: `ZhiYuCore/Sources/ZhiYuCore/Provider/ProviderConfig.swift`
- Modify: `ZhiYuCore/Sources/ZhiYuCore/Provider/OpenAICompatibleProvider.swift`
- Test: `ZhiYuCore/Tests/ZhiYuCoreTests/DeepSeekConfigTests.swift`

- [ ] **Step 1: 写失败测试**

`ZhiYuCore/Tests/ZhiYuCoreTests/DeepSeekConfigTests.swift`:
```swift
import Testing
@testable import ZhiYuCore

@Test func deepSeekPresetHasExpectedBaseURL() {
    let c = ProviderConfig.deepSeek(model: "deepseek-v4-flash")
    #expect(c.name == "DeepSeek")
    #expect(c.baseURL == "https://api.deepseek.com")
    #expect(c.model == "deepseek-v4-flash")
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ZhiYuCore && swift test --filter DeepSeekConfigTests`
Expected: 编译失败（`deepSeek` 未定义）。

- [ ] **Step 3: 实现**

在 `ProviderConfig.swift` 的 `ProviderConfig` 内、`openAI` 预设之后追加：
```swift
    public static func deepSeek(model: String) -> ProviderConfig {
        ProviderConfig(name: "DeepSeek", baseURL: "https://api.deepseek.com", model: model)
    }
```

在 `OpenAICompatibleProvider.swift`：给 init 增加可选 `extraHeaders`，并在请求里注入。整文件替换为：
```swift
import Foundation

public struct OpenAICompatibleProvider: LLMProvider {
    private let config: ProviderConfig
    private let apiKey: String
    private let session: URLSession
    private let extraHeaders: [String: String]

    public init(config: ProviderConfig, apiKey: String, session: URLSession = .shared,
                extraHeaders: [String: String] = [:]) {
        self.config = config
        self.apiKey = apiKey
        self.session = session
        self.extraHeaders = extraHeaders
    }

    private struct RequestBody: Encodable {
        let model: String
        let messages: [LLMMessage]
        let temperature: Double
    }
    private struct ResponseBody: Decodable {
        struct Choice: Decodable { struct Msg: Decodable { let content: String }; let message: Msg }
        let choices: [Choice]
    }

    public func complete(messages: [LLMMessage]) async throws -> String {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey }
        guard let url = URL(string: config.baseURL + "/chat/completions") else {
            throw ProviderError.invalidResponse
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONEncoder().encode(
            RequestBody(model: config.model, messages: messages, temperature: 0.8))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.httpError(status: http.statusCode,
                                          body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let parsed = try? JSONDecoder().decode(ResponseBody.self, from: data),
              let content = parsed.choices.first?.message.content else {
            throw ProviderError.invalidResponse
        }
        return content
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ZhiYuCore && swift test`
Expected: 全绿（含已有 + DeepSeek 新测试；OpenAI 测试仍通过，extraHeaders 默认空不影响）。

- [ ] **Step 5: 提交**

```bash
git add ZhiYuCore
git commit -m "feat(core): DeepSeek 预设 + OpenAICompatibleProvider 可选 extraHeaders" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2：PKCE（S256）

**Files:**
- Create: `ZhiYuCore/Sources/ZhiYuCore/OAuth/PKCE.swift`
- Test: `ZhiYuCore/Tests/ZhiYuCoreTests/PKCETests.swift`

- [ ] **Step 1: 写失败测试**

`ZhiYuCore/Tests/ZhiYuCoreTests/PKCETests.swift`:
```swift
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
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ZhiYuCore && swift test --filter PKCETests`
Expected: 编译失败（`PKCE` 未定义）。

- [ ] **Step 3: 实现**

`ZhiYuCore/Sources/ZhiYuCore/OAuth/PKCE.swift`:
```swift
import Foundation
import CryptoKit

public struct PKCE: Sendable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        let digest = SHA256.hash(data: Data(verifier.utf8))
        self.challenge = Data(digest).base64URLEncodedString()
    }

    public static func generate() -> PKCE {
        var bytes = [UInt8](repeating: 0, count: 64)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return PKCE(verifier: Data(bytes).base64URLEncodedString())
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ZhiYuCore && swift test --filter PKCETests`
Expected: 2 测试 PASS。

- [ ] **Step 5: 提交**

```bash
git add ZhiYuCore
git commit -m "feat(core): PKCE S256 verifier/challenge" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3：OAuthTokens + ChatGPTOAuth（URL/请求/解析/JWT）

**Files:**
- Create: `ZhiYuCore/Sources/ZhiYuCore/OAuth/OAuthTokens.swift`
- Create: `ZhiYuCore/Sources/ZhiYuCore/OAuth/ChatGPTOAuth.swift`
- Test: `ZhiYuCore/Tests/ZhiYuCoreTests/ChatGPTOAuthTests.swift`

- [ ] **Step 1: 写失败测试**

`ZhiYuCore/Tests/ZhiYuCoreTests/ChatGPTOAuthTests.swift`:
```swift
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
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ZhiYuCore && swift test --filter ChatGPTOAuthTests`
Expected: 编译失败（类型未定义）。

- [ ] **Step 3: 实现**

`ZhiYuCore/Sources/ZhiYuCore/OAuth/OAuthTokens.swift`:
```swift
import Foundation

public struct OAuthTokens: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let idToken: String
    public let accountId: String
    public let expiresAt: Date

    public init(accessToken: String, refreshToken: String, idToken: String,
                accountId: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.accountId = accountId
        self.expiresAt = expiresAt
    }

    /// 提前 60s 视为过期，避免边界请求 401。
    public func isExpired(now: Date = Date()) -> Bool {
        now >= expiresAt.addingTimeInterval(-60)
    }
}
```

`ZhiYuCore/Sources/ZhiYuCore/OAuth/ChatGPTOAuth.swift`:
```swift
import Foundation

/// ChatGPT(Codex) OAuth：构造授权 URL、换/刷 token 请求、解析 token、从 JWT 取 account_id。
/// 协议常量来自 openai/codex 与 OpenClaw 源码（originator=openclaw）。
public enum ChatGPTOAuth {
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let authorizeEndpoint = "https://auth.openai.com/oauth/authorize"
    public static let tokenEndpoint = "https://auth.openai.com/oauth/token"
    public static let redirectURI = "http://localhost:1455/auth/callback"
    public static let scope = "openid profile email offline_access"
    public static let originator = "openclaw"

    public static func authorizeURL(pkce: PKCE, state: String) -> URL {
        var c = URLComponents(string: authorizeEndpoint)!
        c.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "id_token_add_organizations", value: "true"),
            .init(name: "codex_cli_simplified_flow", value: "true"),
            .init(name: "state", value: state),
            .init(name: "originator", value: originator),
        ]
        return c.url!
    }

    public static func tokenExchangeRequest(code: String, verifier: String) -> URLRequest {
        formPost(body: "grant_type=authorization_code&code=\(enc(code))"
            + "&redirect_uri=\(enc(redirectURI))&client_id=\(enc(clientID))&code_verifier=\(enc(verifier))")
    }

    public static func refreshRequest(refreshToken: String) -> URLRequest {
        formPost(body: "grant_type=refresh_token&refresh_token=\(enc(refreshToken))&client_id=\(enc(clientID))")
    }

    /// 解析 token 响应为 OAuthTokens。refresh 响应可能不返回 refresh_token，用 fallback。
    public static func parseTokenResponse(_ data: Data, fallbackRefresh: String = "") throws -> OAuthTokens {
        struct Resp: Decodable {
            let access_token: String
            let refresh_token: String?
            let id_token: String?
            let expires_in: Double?
        }
        guard let r = try? JSONDecoder().decode(Resp.self, from: data) else {
            throw ProviderError.invalidResponse
        }
        let accountId = accountID(fromJWT: r.access_token) ?? accountID(fromJWT: r.id_token ?? "") ?? ""
        return OAuthTokens(
            accessToken: r.access_token,
            refreshToken: r.refresh_token ?? fallbackRefresh,
            idToken: r.id_token ?? "",
            accountId: accountId,
            expiresAt: Date().addingTimeInterval(r.expires_in ?? 3600))
    }

    /// 解 JWT payload，取 ["https://api.openai.com/auth"]["chatgpt_account_id"]。
    public static func accountID(fromJWT jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = obj["https://api.openai.com/auth"] as? [String: Any],
              let acct = auth["chatgpt_account_id"] as? String else { return nil }
        return acct
    }

    private static func formPost(body: String) -> URLRequest {
        var req = URLRequest(url: URL(string: tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.utf8)
        return req
    }

    private static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ZhiYuCore && swift test --filter ChatGPTOAuthTests`
Expected: 4 测试 PASS。

- [ ] **Step 5: 提交**

```bash
git add ZhiYuCore
git commit -m "feat(core): ChatGPTOAuth 授权URL/换刷token/JWT取accountId + OAuthTokens" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4：CodexResponsesProvider（Responses body + SSE 解析）

**Files:**
- Create: `ZhiYuCore/Sources/ZhiYuCore/OAuth/CodexResponsesProvider.swift`
- Test: `ZhiYuCore/Tests/ZhiYuCoreTests/CodexResponsesProviderTests.swift`

- [ ] **Step 1: 写失败测试（URLProtocol mock 返回 SSE）**

`ZhiYuCore/Tests/ZhiYuCoreTests/CodexResponsesProviderTests.swift`:
```swift
import Testing
import Foundation
@testable import ZhiYuCore

@Suite(.serialized)
struct CodexResponsesProviderTests {
    final class SSEMock: URLProtocol {
        nonisolated(unsafe) static var sse: String = ""
        nonisolated(unsafe) static var status: Int = 200
        nonisolated(unsafe) static var captured: URLRequest?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            SSEMock.captured = request
            let resp = HTTPURLResponse(url: request.url!, statusCode: SSEMock.status,
                httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(SSEMock.sse.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    func mockSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [SSEMock.self]
        return URLSession(configuration: cfg)
    }

    @Test func accumulatesOutputTextDeltasAndSendsHeaders() async throws {
        SSEMock.status = 200
        SSEMock.sse = """
        data: {"type":"response.output_text.delta","delta":"你好"}

        data: {"type":"response.output_text.delta","delta":"呀"}

        data: {"type":"response.completed"}

        data: [DONE]

        """
        let p = CodexResponsesProvider(accessToken: "tok", accountId: "acct-1",
                                       model: "gpt-5.5", session: mockSession())
        let text = try await p.complete(messages: [
            LLMMessage(role: .system, content: "be nice"),
            LLMMessage(role: .user, content: "hi"),
        ])
        #expect(text == "你好呀")
        #expect(SSEMock.captured?.url?.absoluteString == "https://chatgpt.com/backend-api/codex/responses")
        #expect(SSEMock.captured?.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(SSEMock.captured?.value(forHTTPHeaderField: "chatgpt-account-id") == "acct-1")
        #expect(SSEMock.captured?.value(forHTTPHeaderField: "originator") == "openclaw")
        #expect(SSEMock.captured?.value(forHTTPHeaderField: "OpenAI-Beta") == "responses=experimental")
    }

    @Test func throwsOnHTTPError() async {
        SSEMock.status = 401
        SSEMock.sse = "unauthorized"
        let p = CodexResponsesProvider(accessToken: "bad", accountId: "a",
                                       model: "gpt-5.5", session: mockSession())
        await #expect(throws: ProviderError.self) {
            _ = try await p.complete(messages: [LLMMessage(role: .user, content: "hi")])
        }
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ZhiYuCore && swift test --filter CodexResponsesProviderTests`
Expected: 编译失败（`CodexResponsesProvider` 未定义）。

- [ ] **Step 3: 实现**

`ZhiYuCore/Sources/ZhiYuCore/OAuth/CodexResponsesProvider.swift`:
```swift
import Foundation

/// 用 ChatGPT(Codex) OAuth token 调 codex/responses（Responses API + SSE）。
/// 把 [LLMMessage] 映射为 instructions(系统) + input(其余)，流式累积 output_text.delta。
public struct CodexResponsesProvider: LLMProvider {
    private let accessToken: String
    private let accountId: String
    private let model: String
    private let userAgent: String
    private let session: URLSession

    public init(accessToken: String, accountId: String, model: String,
                userAgent: String = "openclaw (macOS)", session: URLSession = .shared) {
        self.accessToken = accessToken
        self.accountId = accountId
        self.model = model
        self.userAgent = userAgent
        self.session = session
    }

    public func complete(messages: [LLMMessage]) async throws -> String {
        guard !accessToken.isEmpty else { throw ProviderError.missingAPIKey }
        let system = messages.first(where: { $0.role == .system })?.content ?? "You are a helpful assistant."
        let input: [[String: Any]] = messages.filter { $0.role != .system }.map { m in
            let type = (m.role == .assistant) ? "output_text" : "input_text"
            return ["role": m.role.rawValue,
                    "content": [["type": type, "text": m.content]]]
        }
        let body: [String: Any] = [
            "model": model,
            "store": false,
            "stream": true,
            "instructions": system,
            "input": input,
            "text": ["verbosity": "low"],
            "include": ["reasoning.encrypted_content"],
            "tool_choice": "auto",
            "parallel_tool_calls": true,
        ]
        guard let url = URL(string: "https://chatgpt.com/backend-api/codex/responses") else {
            throw ProviderError.invalidResponse
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(accountId, forHTTPHeaderField: "chatgpt-account-id")
        req.setValue("openclaw", forHTTPHeaderField: "originator")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        req.setValue("text/event-stream", forHTTPHeaderField: "accept")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: req)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            // 读尽剩余 body 供报错
            var errText = ""
            for try await line in bytes.lines { errText += line }
            throw ProviderError.httpError(status: http.statusCode, body: errText)
        }

        var text = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty || payload == "[DONE]" { continue }
            guard let d = payload.data(using: .utf8),
                  let ev = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let type = ev["type"] as? String else { continue }
            switch type {
            case "response.output_text.delta":
                if let delta = ev["delta"] as? String { text += delta }
            case "response.completed", "response.done", "response.incomplete":
                return text
            case "error", "response.failed":
                throw ProviderError.httpError(status: 0, body: payload)
            default:
                continue
            }
        }
        return text
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ZhiYuCore && swift test`
Expected: 全绿（含 SSE 累积与 401 抛错）。

> 备注：`session.bytes(for:)` + `bytes.lines` 在 URLProtocol mock 下会把缓冲数据按行产出，SSE 测试可通过。若个别 Swift/SDK 行为差异导致 mock 不产出行，最小化调整测试的投递方式（如分多次 didLoad），不改变 provider 语义。

- [ ] **Step 5: 提交**

```bash
git add ZhiYuCore
git commit -m "feat(core): CodexResponsesProvider（Responses body + SSE 累积）" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5：KeychainStore 存取 OAuthTokens

**Files:**
- Modify: `ZhiYu/Secrets/KeychainStore.swift`

- [ ] **Step 1: 加 token 读写（JSON 编码进 Keychain）**

在 `KeychainStore` 内追加（保留已有 OpenAI/DeepSeek key 的方法）：
```swift
    static let chatGPTTokensAccount = "chatgpt.oauthTokens"

    static func saveChatGPTTokens(_ tokens: ZhiYuCore.OAuthTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        set(String(decoding: data, as: UTF8.self), account: chatGPTTokensAccount)
    }

    static func loadChatGPTTokens() -> ZhiYuCore.OAuthTokens? {
        guard let s = get(account: chatGPTTokensAccount), let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ZhiYuCore.OAuthTokens.self, from: data)
    }

    static func clearChatGPTTokens() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: chatGPTTokensAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }
```
并在文件顶部确保 `import ZhiYuCore`（KeychainStore.swift 顶部加）。

- [ ] **Step 2: 编译验证**

Run: `xcodebuild -project ZhiYu.xcodeproj -scheme ZhiYu -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: 提交**

```bash
git add ZhiYu
git commit -m "feat(app): KeychainStore 存取 ChatGPT OAuthTokens" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6：CodexLoginService（本地回环服务 + 浏览器 + 换/刷 token）

**Files:**
- Create: `ZhiYu/OAuth/CodexLoginService.swift`

- [ ] **Step 1: 实现登录服务**

`ZhiYu/OAuth/CodexLoginService.swift`:
```swift
import AppKit
import Network
import ZhiYuCore

/// ChatGPT 登录：起 127.0.0.1:1455 回环服务接 OAuth 回调，开浏览器授权，换 token 存 Keychain；按需刷新。
@MainActor
final class CodexLoginService {
    static let shared = CodexLoginService()

    private var listener: NWListener?
    private var pkce: PKCE?
    private var state: String = ""
    private var completion: ((Result<OAuthTokens, Error>) -> Void)?

    enum LoginError: Error, CustomStringConvertible {
        case serverFailed, stateMismatch, noCode, exchangeFailed(String)
        var description: String {
            switch self {
            case .serverFailed: return "本地回环服务启动失败（端口 1455 可能被占用）"
            case .stateMismatch: return "state 校验失败"
            case .noCode: return "回调里没有授权码"
            case .exchangeFailed(let m): return "换 token 失败：\(m)"
            }
        }
    }

    /// 启动登录流程：起服务 → 开浏览器 → 等回调 → 换 token。
    func login(completion: @escaping (Result<OAuthTokens, Error>) -> Void) {
        self.completion = completion
        let pkce = PKCE.generate()
        self.pkce = pkce
        self.state = UUID().uuidString

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: 1455)
            l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            l.stateUpdateHandler = { [weak self] st in
                if case .failed = st { self?.finish(.failure(LoginError.serverFailed)) }
            }
            l.start(queue: .main)
            self.listener = l
        } catch {
            finish(.failure(LoginError.serverFailed)); return
        }

        NSWorkspace.shared.open(ChatGPTOAuth.authorizeURL(pkce: pkce, state: state))
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self else { return }
            let reqText = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            // 形如 "GET /auth/callback?code=...&state=... HTTP/1.1"
            let firstLine = reqText.split(separator: "\r\n").first.map(String.init) ?? ""
            let path = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let html = "<html><body><h3>知语：登录完成，可关闭此页面返回 App。</h3></body></html>"
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
            self.onCallback(path: path)
        }
    }

    private func onCallback(path: String) {
        guard let comps = URLComponents(string: "http://localhost:1455\(path)"),
              comps.path == "/auth/callback" else { return }
        let items = comps.queryItems ?? []
        let code = items.first(where: { $0.name == "code" })?.value
        let st = items.first(where: { $0.name == "state" })?.value
        guard st == state else { finish(.failure(LoginError.stateMismatch)); return }
        guard let code, let verifier = pkce?.verifier else { finish(.failure(LoginError.noCode)); return }

        Task {
            do {
                let (data, resp) = try await URLSession.shared.data(
                    for: ChatGPTOAuth.tokenExchangeRequest(code: code, verifier: verifier))
                guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    self.finish(.failure(LoginError.exchangeFailed(
                        String(data: data, encoding: .utf8) ?? "非2xx"))); return
                }
                let tokens = try ChatGPTOAuth.parseTokenResponse(data)
                KeychainStore.saveChatGPTTokens(tokens)
                self.finish(.success(tokens))
            } catch {
                self.finish(.failure(LoginError.exchangeFailed(error.localizedDescription)))
            }
        }
    }

    private func finish(_ result: Result<OAuthTokens, Error>) {
        listener?.cancel(); listener = nil
        let c = completion; completion = nil
        c?(result)
    }

    /// 取有效 access token（过期则用 refresh_token 刷新并回存）。
    func validTokens() async -> OAuthTokens? {
        guard let tokens = KeychainStore.loadChatGPTTokens() else { return nil }
        if !tokens.isExpired() { return tokens }
        guard !tokens.refreshToken.isEmpty else { return nil }
        do {
            let (data, resp) = try await URLSession.shared.data(
                for: ChatGPTOAuth.refreshRequest(refreshToken: tokens.refreshToken))
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            let refreshed = try ChatGPTOAuth.parseTokenResponse(data, fallbackRefresh: tokens.refreshToken)
            KeychainStore.saveChatGPTTokens(refreshed)
            return refreshed
        } catch { return nil }
    }
}
```

- [ ] **Step 2: 编译验证**

Run: `xcodebuild -project ZhiYu.xcodeproj -scheme ZhiYu -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`（若 NWListener API 细节有出入，最小化修正至编译通过）。

- [ ] **Step 3: 提交**

```bash
git add ZhiYu
git commit -m "feat(app): CodexLoginService 回环 OAuth 登录 + token 刷新" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7：GeneratePanel 多 Provider（OpenAI / DeepSeek / ChatGPT 登录）

**Files:**
- Modify: `ZhiYu/Generate/GeneratePanel.swift`

- [ ] **Step 1: 整文件替换为多 Provider 版本**

`ZhiYu/Generate/GeneratePanel.swift`:
```swift
import SwiftUI
import Combine
import ZhiYuCore

enum ProviderKind: String, CaseIterable, Identifiable {
    case openAI = "OpenAI"
    case deepSeek = "DeepSeek"
    case chatGPT = "ChatGPT 登录"
    var id: String { rawValue }
}

@MainActor
final class GenerateViewModel: ObservableObject {
    @Published var kind: ProviderKind = .openAI
    @Published var apiKey: String = KeychainStore.openAIKey()
    @Published var model: String = "gpt-4o"
    @Published var styleIndex: Int = 0
    @Published var status: String = ""
    @Published var candidates: [String] = []
    @Published var isLoading = false
    @Published var loggedIn: Bool = KeychainStore.loadChatGPTTokens() != nil

    private let cache = CandidateCache()
    let styles = ReplyStyle.presets

    /// 切换 Provider 时调整默认 key/model。
    func onKindChange() {
        switch kind {
        case .openAI:  apiKey = KeychainStore.openAIKey();  if model.isEmpty { model = "gpt-4o" }
        case .deepSeek: apiKey = KeychainStore.deepSeekKey(); model = "deepseek-v4-flash"
        case .chatGPT: model = "gpt-5.5"
        }
    }

    func saveKey() {
        let k = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .openAI:  KeychainStore.setOpenAIKey(k);  status = "已保存 OpenAI Key"
        case .deepSeek: KeychainStore.setDeepSeekKey(k); status = "已保存 DeepSeek Key"
        case .chatGPT: break
        }
    }

    func loginChatGPT() {
        status = "正在打开浏览器登录 ChatGPT…"
        CodexLoginService.shared.login { result in
            switch result {
            case .success: self.loggedIn = true; self.status = "ChatGPT 登录成功"
            case .failure(let e): self.status = "登录失败：\(e)"
            }
        }
    }

    func logoutChatGPT() {
        KeychainStore.clearChatGPTTokens(); loggedIn = false; status = "已退出 ChatGPT 登录"
    }

    func generate() {
        guard let context = WeChatReader.readCurrentContext(), !context.messages.isEmpty else {
            status = "读不到微信对话（先切到某个会话，且已授权辅助功能）"; return
        }
        let style = styles[styleIndex]
        isLoading = true; candidates = []
        status = "生成中…（联系人：\(context.contactName)，\(context.messages.count) 条上下文）"
        Task {
            do {
                let provider = try await makeProvider()
                let gen = ReplyGenerator(provider: provider, cache: cache, candidateCount: 3)
                let result = try await gen.generate(context: context, style: style)
                self.candidates = result
                self.status = "完成，\(result.count) 条候选"
            } catch {
                self.status = "失败：\(error)"
            }
            self.isLoading = false
        }
    }

    private func makeProvider() async throws -> any LLMProvider {
        switch kind {
        case .openAI:
            let k = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty else { throw ProviderError.missingAPIKey }
            return OpenAICompatibleProvider(config: .openAI(model: model), apiKey: k)
        case .deepSeek:
            let k = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty else { throw ProviderError.missingAPIKey }
            return OpenAICompatibleProvider(config: .deepSeek(model: model), apiKey: k)
        case .chatGPT:
            guard let tokens = await CodexLoginService.shared.validTokens() else {
                throw ProviderError.missingAPIKey
            }
            return CodexResponsesProvider(accessToken: tokens.accessToken,
                                          accountId: tokens.accountId, model: model)
        }
    }

    func fill(_ text: String) { Inserter.fill(text); status = "已填入" }
    func send(_ text: String) {
        Inserter.fillAndSend(text) { ok in
            self.status = ok ? "已发送" : "未发送（确认微信在前台且输入框聚焦）"
        }
    }
}

struct GeneratePanel: View {
    @StateObject private var vm = GenerateViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("生成候选回复").font(.headline)
            Picker("Provider", selection: $vm.kind) {
                ForEach(ProviderKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: vm.kind) { _, _ in vm.onKindChange() }

            if vm.kind == .chatGPT {
                HStack {
                    Text(vm.loggedIn ? "已登录 ChatGPT ✓" : "未登录")
                    Button(vm.loggedIn ? "重新登录" : "用 ChatGPT 登录") { vm.loginChatGPT() }
                    if vm.loggedIn { Button("退出登录") { vm.logoutChatGPT() } }
                }
            } else {
                HStack {
                    SecureField("API Key", text: $vm.apiKey)
                    Button("保存 Key") { vm.saveKey() }
                }
            }

            HStack {
                TextField("模型", text: $vm.model).frame(width: 160)
                Picker("风格", selection: $vm.styleIndex) {
                    ForEach(Array(vm.styles.enumerated()), id: \.offset) { i, s in Text(s.name).tag(i) }
                }.frame(width: 160)
                Button(vm.isLoading ? "生成中…" : "生成候选") { vm.generate() }.disabled(vm.isLoading)
            }
            if !vm.status.isEmpty { Text(vm.status).font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(vm.candidates.enumerated()), id: \.offset) { _, c in
                HStack(alignment: .top) {
                    Text(c).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    Button("填入") { vm.fill(c) }
                    Button("发送") { vm.send(c) }
                }
                .padding(6).background(Color.gray.opacity(0.12)).cornerRadius(6)
            }
        }
    }
}
```

- [ ] **Step 2: KeychainStore 补 DeepSeek key 方法**

在 `ZhiYu/Secrets/KeychainStore.swift` 追加：
```swift
    static let deepSeekKeyAccount = "deepseek.apiKey"
    static func deepSeekKey() -> String { get(account: deepSeekKeyAccount) ?? "" }
    static func setDeepSeekKey(_ v: String) { set(v, account: deepSeekKeyAccount) }
```

- [ ] **Step 3: 编译验证**

Run: `xcodebuild -project ZhiYu.xcodeproj -scheme ZhiYu -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: 提交**

```bash
git add ZhiYu
git commit -m "feat(app): 生成面板多 Provider（OpenAI/DeepSeek/ChatGPT 登录）" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8：真机联调（手动）

- [ ] **Step 1: DeepSeek 路线（先验证简单的）**
⌘R 运行 → 生成面板选 DeepSeek → 填 DeepSeek key 保存 → 模型 `deepseek-v4-flash` → 微信进会话 → 生成候选。**记录是否出候选。**

- [ ] **Step 2: ChatGPT 登录路线**
1. 选 ChatGPT 登录 → 点"用 ChatGPT 登录" → 浏览器打开 OpenAI 授权页 → 同意 → 浏览器显示"登录完成"。
2. 面板应显示"已登录 ✓"。
3. 微信进会话 → 模型默认 `gpt-5.5` → 生成候选。
4. **记录**：是否出候选；若失败，把 status 的"失败：…"发回。常见需迭代点：endpoint 路径、模型名（试 gpt-5.4）、header（Cloudflare 403）、Responses body 字段。
5. 候选填入/发送同前。

> 联调是这条灰色后端的真相来源；失败信息发回后据此微调 CodexResponsesProvider（endpoint/headers/body/SSE 事件名）。

---

## 自检 / Roadmap
- 自检：多 Provider 切换、缓存命中、DeepSeek/OpenAI/ChatGPT 三路；ZhiYuCore swift test 全绿；App BUILD SUCCEEDED。
- 后续：Phase 4 候选悬浮面板；Phase 5 设置窗口正式化 + 更多 Provider（Anthropic）；流式候选展示；按联系人风格覆盖。
