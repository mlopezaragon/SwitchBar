import Foundation

public enum AnthropicAPIError: Error, Equatable {
    /// Pausa solicitada por Anthropic. `retryAfter` procede de la cabecera
    /// estándar y evita insistir antes de tiempo.
    case rateLimited(retryAfter: TimeInterval?)
    /// El refresh token fue revocado o rotado por otro cliente: la cuenta
    /// necesita un login por navegador.
    case invalidGrant
    case httpError(Int)
    case malformedResponse
}

/// Tokens devueltos por el endpoint OAuth al renovar una sesión.
public struct RefreshedTokens: Sendable, Equatable {
    public var accessToken: String
    /// Anthropic rota el refresh token en cada renovación; si falta en la
    /// respuesta se conserva el anterior.
    public var refreshToken: String?
    /// Vigencia del access token en segundos.
    public var expiresIn: TimeInterval?
}

/// Cliente del uso y de la renovación de sesiones de perfiles inactivos.
///
/// SwitchBar no canjea códigos de autorización: `claude auth login
/// --claudeai` y `/login` siguen siendo los dueños del alta. La renovación
/// solo se aplica a cuentas cuyo perfil vive en el almacén privado y que no
/// son la sesión activa de Claude Code, de modo que ninguna terminal abierta
/// puede quedar invalidada por una rotación en segundo plano.
public final class AnthropicAPI: Sendable {
    static let userAgent = "claude-code/2.1.0"
    static let usageEndpoint = URL(
        string: "https://api.anthropic.com/api/oauth/usage"
    )!
    /// Mismo endpoint y client_id públicos que emplea el propio Claude Code.
    static let tokenEndpoint = URL(
        string: "https://console.anthropic.com/v1/oauth/token"
    )!
    static let oauthClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchUsage(accessToken: String) async throws -> UsageSnapshot {
        var request = URLRequest(url: Self.usageEndpoint)
        request.httpMethod = "GET"
        request.setValue(
            "Bearer \(accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            "oauth-2025-04-20",
            forHTTPHeaderField: "anthropic-beta"
        )
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AnthropicAPIError.malformedResponse
        }
        switch http.statusCode {
        case 200:
            return try UsageSnapshot.parse(data, fetchedAt: Date())
        case 429:
            throw AnthropicAPIError.rateLimited(
                retryAfter: Self.retryAfter(from: http)
            )
        default:
            throw AnthropicAPIError.httpError(http.statusCode)
        }
    }

    /// Renueva un access token caducado con el flujo estándar
    /// `grant_type=refresh_token`, idéntico al que ejecuta Claude Code.
    public func refreshAccessToken(
        refreshToken: String
    ) async throws -> RefreshedTokens {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.oauthClientId
        ], options: [.sortedKeys])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AnthropicAPIError.malformedResponse
        }
        switch http.statusCode {
        case 200:
            guard let dict = try? JSONSerialization.jsonObject(
                with: data
            ) as? [String: Any],
            let accessToken = dict["access_token"] as? String else {
                throw AnthropicAPIError.malformedResponse
            }
            return RefreshedTokens(
                accessToken: accessToken,
                refreshToken: dict["refresh_token"] as? String,
                expiresIn: (dict["expires_in"] as? NSNumber)?.doubleValue
            )
        case 400, 401, 403:
            throw AnthropicAPIError.invalidGrant
        case 429:
            throw AnthropicAPIError.rateLimited(
                retryAfter: Self.retryAfter(from: http)
            )
        default:
            throw AnthropicAPIError.httpError(http.statusCode)
        }
    }

    private static func retryAfter(
        from response: HTTPURLResponse
    ) -> TimeInterval? {
        guard let raw = response.value(
            forHTTPHeaderField: "Retry-After"
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
        !raw.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(raw), seconds.isFinite {
            return max(0, seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }
}
