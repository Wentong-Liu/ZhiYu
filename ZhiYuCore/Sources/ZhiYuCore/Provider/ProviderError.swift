import Foundation

public enum ProviderError: Error, Equatable, Sendable {
    case missingAPIKey
    case httpError(status: Int, body: String)
    case invalidResponse
    case network(String)
}
