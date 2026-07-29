import CryptoKit
import Foundation

public enum AnthropicAPIError: Error, Equatable {
    case refreshTokenInvalid
    case rateLimited
    case httpError(Int)
    case malformedResponse
    /// El código de autorización pegado no es válido o ya se usó.
    case invalidAuthorizationCode
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
                // Rechazo definitivo (invalid_grant): no reintentar en el
                // endpoint alternativo — un refresh token ya consumido no va
                // a revivir y el reintento solo empeora las cosas.
                throw AnthropicAPIError.refreshTokenInvalid
            } catch {
                // Error de red o del servidor: probar el endpoint alternativo.
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
            // Sin expires_in, asumir 1 h: dejar el expiresAt viejo provocaría
            // renovaciones (y rotaciones de refresh token) en cada sondeo.
            let lifetime = parsed.expiresIn ?? 3600
            let expiresAt = Int(Date().timeIntervalSince1970 * 1000) + lifetime * 1000
            return try creds.updating(
                accessToken: parsed.accessToken,
                refreshToken: parsed.refreshToken,
                expiresAt: expiresAt
            )
        case 400:
            // Solo invalid_grant es un rechazo definitivo del refresh token;
            // otros 400 (invalid_request, errores transitorios) no deben
            // condenar la cuenta a "requiere sesión".
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if body?["error"] as? String == "invalid_grant" {
                throw AnthropicAPIError.refreshTokenInvalid
            }
            throw AnthropicAPIError.httpError(400)
        case 401:
            throw AnthropicAPIError.refreshTokenInvalid
        case 429:
            throw AnthropicAPIError.rateLimited
        default:
            throw AnthropicAPIError.httpError(http.statusCode)
        }
    }

    // MARK: Alta de cuenta (OAuth con PKCE, flujo de código copiado)

    /// Sesión de login en curso: URL que abrir en el navegador y secretos PKCE.
    public struct LoginSession: Sendable {
        public let codeVerifier: String
        public let state: String
        public let url: URL
    }

    static let authorizeEndpoint = URL(string: "https://claude.ai/oauth/authorize")!
    static let redirectURI = "https://platform.claude.com/oauth/code/callback"
    /// Scopes que pide Claude Code 2.x (verificados en una sesión real).
    static let scopes = "user:file_upload user:inference user:mcp_servers user:profile user:sessions:claude_code"

    /// Prepara el flujo: el usuario abre `url`, inicia sesión con la cuenta
    /// nueva y la página le muestra un código para pegar en la app.
    public static func makeLoginSession() -> LoginSession {
        func randomURLSafe(_ bytes: Int) -> String {
            var data = Data(count: bytes)
            _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let verifier = randomURLSafe(48)
        let state = randomURLSafe(24)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var comps = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        return LoginSession(codeVerifier: verifier, state: state, url: comps.url!)
    }

    /// Canjea el código pegado (formato `código#estado`) por credenciales e
    /// identidad, listas para guardarse como perfil.
    public func exchangeAuthorizationCode(_ pasted: String, session: LoginSession) async throws -> (OAuthCredentials, AccountIdentity) {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "#", maxSplits: 1).map(String.init)
        guard let code = parts.first, !code.isEmpty else { throw AnthropicAPIError.invalidAuthorizationCode }
        let returnedState = parts.count > 1 ? parts[1] : session.state

        var lastError: Error = AnthropicAPIError.malformedResponse
        for endpoint in Self.tokenEndpoints.reversed() { // platform.claude.com primero
            do {
                return try await exchange(code: code, state: returnedState, verifier: session.codeVerifier, endpoint: endpoint)
            } catch AnthropicAPIError.invalidAuthorizationCode {
                throw AnthropicAPIError.invalidAuthorizationCode
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func exchange(code: String, state: String, verifier: String, endpoint: URL) async throws -> (OAuthCredentials, AccountIdentity) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "client_id": Self.clientId,
            "redirect_uri": Self.redirectURI,
            "code_verifier": verifier
        ])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AnthropicAPIError.malformedResponse }
        switch http.statusCode {
        case 200:
            return try Self.parseExchangeResponse(data)
        case 400, 401, 403:
            throw AnthropicAPIError.invalidAuthorizationCode
        case 429:
            throw AnthropicAPIError.rateLimited
        default:
            throw AnthropicAPIError.httpError(http.statusCode)
        }
    }

    /// Construye `claudeAiOauth` y `oauthAccount` con la misma forma que deja
    /// Claude Code, a partir de la respuesta del canje.
    static func parseExchangeResponse(_ data: Data) throws -> (OAuthCredentials, AccountIdentity) {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = dict["access_token"] as? String,
              let refreshToken = dict["refresh_token"] as? String else {
            throw AnthropicAPIError.malformedResponse
        }
        let expiresIn = (dict["expires_in"] as? NSNumber)?.intValue ?? 3600
        var oauth: [String: Any] = [
            "accessToken": accessToken,
            "refreshToken": refreshToken,
            "expiresAt": Int(Date().timeIntervalSince1970 * 1000) + expiresIn * 1000
        ]
        if let scope = dict["scope"] as? String { oauth["scopes"] = scope.split(separator: " ").map(String.init) }
        let account = dict["account"] as? [String: Any] ?? [:]
        if let subscription = (dict["subscription_type"] ?? account["subscription_type"]) as? String {
            oauth["subscriptionType"] = subscription
        }
        guard let uuid = (account["uuid"] ?? account["account_uuid"]) as? String,
              let email = (account["email_address"] ?? account["email"]) as? String else {
            throw AnthropicAPIError.malformedResponse
        }
        var identity: [String: Any] = ["accountUuid": uuid, "emailAddress": email]
        if let name = (account["display_name"] ?? account["full_name"]) as? String { identity["displayName"] = name }
        if let org = dict["organization"] as? [String: Any] {
            if let orgUuid = org["uuid"] as? String { identity["organizationUuid"] = orgUuid }
            if let orgName = org["name"] as? String { identity["organizationName"] = orgName }
        }
        let creds = try OAuthCredentials(claudeAiOauthJSON: JSONSerialization.data(withJSONObject: oauth, options: [.sortedKeys]))
        let id = try AccountIdentity(oauthAccountJSON: JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys]))
        return (creds, id)
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
