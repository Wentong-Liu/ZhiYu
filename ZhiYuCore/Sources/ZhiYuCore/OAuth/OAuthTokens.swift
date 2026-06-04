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
