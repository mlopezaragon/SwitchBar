import Foundation

public enum AnthropicAPIError: Error, Equatable {
    case refreshTokenInvalid
    case rateLimited
    case httpError(Int)
    case malformedResponse
}

struct TokenRefreshResponse: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

/// Cliente de los endpoints OAuth de Anthropic que usa Claude Code:
/// renovación de tokens y consulta de uso. Sin estado.
public final class AnthropicAPI: Sendable {
    /// client_id público de Claude Code (el mismo que usa la CLI oficial).
    static let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let userAgent = "claude-code/2.0.0"
    static let tokenEndpoints = [
        URL(string: "https://console.anthropic.com/v1/oauth/token")!,
        URL(string: "https://platform.claude.com/v1/oauth/token")!
    ]
    static let usageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: Renovación de tokens

    public func refresh(_ creds: OAuthCredentials) async throws -> OAuthCredentials {
        var lastError: Error = AnthropicAPIError.malformedResponse
        for endpoint in Self.tokenEndpoints {
            do {
                return try await refresh(creds, endpoint: endpoint)
            } catch AnthropicAPIError.refreshTokenInvalid {
                // Rechazo definitivo del refresh token: probar el endpoint
                // alternativo por si el primario ha migrado; si también lo
                // rechaza, propagar.
                lastError = AnthropicAPIError.refreshTokenInvalid
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func refresh(_ creds: OAuthCredentials, endpoint: URL) async throws -> OAuthCredentials {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": creds.refreshToken,
            "client_id": Self.clientId
        ])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AnthropicAPIError.malformedResponse }
        switch http.statusCode {
        case 200:
            guard let parsed = try? JSONDecoder().decode(TokenRefreshResponse.self, from: data) else {
                throw AnthropicAPIError.malformedResponse
            }
            let expiresAt = parsed.expiresIn.map { Int(Date().timeIntervalSince1970 * 1000) + $0 * 1000 }
            return try creds.updating(
                accessToken: parsed.accessToken,
                refreshToken: parsed.refreshToken,
                expiresAt: expiresAt
            )
        case 400, 401:
            throw AnthropicAPIError.refreshTokenInvalid
        case 429:
            throw AnthropicAPIError.rateLimited
        default:
            throw AnthropicAPIError.httpError(http.statusCode)
        }
    }

    // MARK: Uso

    public func fetchUsage(accessToken: String) async throws -> UsageSnapshot {
        var request = URLRequest(url: Self.usageEndpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AnthropicAPIError.malformedResponse }
        switch http.statusCode {
        case 200:
            return try UsageSnapshot.parse(data, fetchedAt: Date())
        case 401:
            throw AnthropicAPIError.httpError(401)
        case 429:
            throw AnthropicAPIError.rateLimited
        default:
            throw AnthropicAPIError.httpError(http.statusCode)
        }
    }
}
