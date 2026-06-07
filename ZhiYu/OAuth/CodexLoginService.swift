import AppKit
import Network
import ZhiYuCore

/// ChatGPT 登录：起 ChatGPTOAuth.callbackHost:callbackPort（127.0.0.1:1455）回环服务接 OAuth 回调，开浏览器授权，换 token 存 Keychain；按需刷新。
@MainActor
final class CodexLoginService {
    static let shared = CodexLoginService()

    /// 登录超时（秒）：用户打开浏览器后若一直不完成授权，到点自动收尾，释放端口 callbackPort(1455)。
    private static let loginTimeout: TimeInterval = 300

    private var listener: NWListener?
    private var pkce: PKCE?
    private var state: String = ""
    private var completion: ((Result<OAuthTokens, Error>) -> Void)?
    private var timeoutTask: Task<Void, Never>?

    enum LoginError: Error, CustomStringConvertible {
        case serverFailed, stateMismatch, noCode, exchangeFailed(String), cancelled, timedOut
        var description: String {
            switch self {
            case .serverFailed: return "本地回环服务启动失败（端口 \(ChatGPTOAuth.callbackPort) 可能被占用）"
            case .stateMismatch: return "state 校验失败"
            case .noCode: return "回调里没有授权码"
            case .exchangeFailed(let m): return "换 token 失败：\(m)"
            case .cancelled: return "登录已取消"
            case .timedOut: return "登录超时，请重试"
            }
        }
    }

    /// 启动登录流程：起服务 → 开浏览器 → 等回调 → 换 token。
    /// 重入保护：若已有进行中的登录，先收尾旧流程（cancel listener + 旧 completion 报 cancelled），保证同一时刻只有一个会话。
    func login(completion: @escaping (Result<OAuthTokens, Error>) -> Void) {
        finish(.failure(LoginError.cancelled))  // 清理上一轮（若有）：cancel 旧 listener、触发旧 completion、停掉旧超时
        self.completion = completion
        let pkce = PKCE.generate()
        self.pkce = pkce
        self.state = UUID().uuidString

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: ChatGPTOAuth.callbackPort)!)
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor [weak self] in self?.handle(conn) }
            }
            l.stateUpdateHandler = { [weak self] st in
                if case .failed = st {
                    Task { @MainActor [weak self] in self?.finish(.failure(LoginError.serverFailed)) }
                }
            }
            l.start(queue: .main)
            self.listener = l
        } catch {
            finish(.failure(LoginError.serverFailed)); return
        }

        // 超时收尾：到点若仍在 listening（用户未完成授权），自动 finish 释放端口、触发 completion。
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.loginTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.listener != nil else { return }
                self.finish(.failure(LoginError.timedOut))
            }
        }

        NSWorkspace.shared.open(ChatGPTOAuth.authorizeURL(pkce: pkce, state: state))
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            let reqText = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            // 形如 "GET /auth/callback?code=...&state=... HTTP/1.1"
            let firstLine = reqText.split(separator: "\r\n").first.map(String.init) ?? ""
            let path = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let html = "<html><body><h3>知语：登录完成，可关闭此页面返回 App。</h3></body></html>"
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
            Task { @MainActor [weak self] in self?.onCallback(path: path) }
        }
    }

    private func onCallback(path: String) {
        guard let comps = URLComponents(string: "http://\(ChatGPTOAuth.callbackHost):\(ChatGPTOAuth.callbackPort)\(path)"),
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
                guard let http = resp as? HTTPURLResponse, HTTPResponseValidator.successRange.contains(http.statusCode) else {
                    // 换 token 非 2xx：诊断串只含状态码，绝不含响应体（避免泄露 token）。
                    let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? -1
                    self.finish(.failure(LoginError.exchangeFailed("HTTP \(statusCode)"))); return
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
        timeoutTask?.cancel(); timeoutTask = nil
        listener?.cancel(); listener = nil
        pkce = nil; state = ""
        let c = completion; completion = nil
        c?(result)  // completion 为 nil 时（无进行中会话）整体为安全 no-op
    }

    /// 取有效 access token（过期则用 refresh_token 刷新并回存）。
    func validTokens() async -> OAuthTokens? {
        guard let tokens = KeychainStore.loadChatGPTTokens() else { return nil }
        if !tokens.isExpired() { return tokens }
        guard !tokens.refreshToken.isEmpty else { return nil }
        do {
            let (data, resp) = try await URLSession.shared.data(
                for: ChatGPTOAuth.refreshRequest(refreshToken: tokens.refreshToken))
            guard let http = resp as? HTTPURLResponse, HTTPResponseValidator.successRange.contains(http.statusCode) else {
                // 刷新非 2xx：只记状态码，绝不打印响应体（避免泄露 token）；行为不变，照常返回 nil。
                let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
                NSLog("[ZhiYu][CodexLogin] token 刷新失败 status=%d", status)
                return nil
            }
            let refreshed = try ChatGPTOAuth.parseTokenResponse(data, fallbackRefresh: tokens.refreshToken)
            KeychainStore.saveChatGPTTokens(refreshed)
            return refreshed
        } catch {
            // 刷新请求抛错（网络/解码等）：记录 error 助排查（行为不变，照常返回 nil）。
            NSLog("[ZhiYu][CodexLogin] token 刷新抛错 error=%@", String(describing: error))
            return nil
        }
    }
}
