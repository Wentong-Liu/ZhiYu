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
