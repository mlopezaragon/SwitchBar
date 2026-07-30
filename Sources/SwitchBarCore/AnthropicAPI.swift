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
    static let profileEndpoint = URL(
        string: "https://api.anthropic.com/api/oauth/profile"
    )!

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

    /// Canjea el código de autorización por credenciales (`grant_type=
    /// authorization_code`). Cierra el flujo PKCE iniciado en el navegador.
    public func exchangeAuthorizationCode(
        _ code: String,
        verifier: String,
        state: String
    ) async throws -> RefreshedTokens {
        try await token(body: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": OAuthLoginFlow.redirectURI,
            "client_id": Self.oauthClientId,
            "code_verifier": verifier,
            "state": state
        ])
    }

    /// Renueva un access token caducado con el flujo estándar
    /// `grant_type=refresh_token`, idéntico al que ejecuta Claude Code.
    public func refreshAccessToken(
        refreshToken: String
    ) async throws -> RefreshedTokens {
        try await token(body: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.oauthClientId
        ])
    }

    /// Petición al endpoint de tokens, común al canje y a la renovación.
    private func token(body: [String: Any]) async throws -> RefreshedTokens {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: body,
            options: [.sortedKeys]
        )
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

    /// Identidad de la cuenta recién autorizada.
    ///
    /// La forma de la respuesta no está documentada, así que se aceptan las
    /// dos convenciones habituales (anidada con snake_case y plana con
    /// camelCase) y se conserva todo lo que se reconozca. Si faltan el
    /// identificador o el correo se informa como respuesta ilegible: sin
    /// ellos no se puede crear un perfil.
    public func fetchProfile(accessToken: String) async throws -> AccountIdentity {
        var request = URLRequest(url: Self.profileEndpoint)
        request.httpMethod = "GET"
        request.setValue(
            "Bearer \(accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AnthropicAPIError.malformedResponse
        }
        switch http.statusCode {
        case 200:
            return try Self.identity(fromProfile: data)
        case 401, 403:
            throw AnthropicAPIError.invalidGrant
        case 429:
            throw AnthropicAPIError.rateLimited(
                retryAfter: Self.retryAfter(from: http)
            )
        default:
            throw AnthropicAPIError.httpError(http.statusCode)
        }
    }

    static func identity(fromProfile data: Data) throws -> AccountIdentity {
        guard let root = try? JSONSerialization.jsonObject(
            with: data
        ) as? [String: Any] else {
            throw AnthropicAPIError.malformedResponse
        }
        let account = root["account"] as? [String: Any] ?? root
        let organization = root["organization"] as? [String: Any] ?? [:]

        func string(_ dict: [String: Any], _ keys: [String]) -> String? {
            for key in keys {
                if let value = dict[key] as? String, !value.isEmpty {
                    return value
                }
            }
            return nil
        }

        guard let uuid = string(account, ["uuid", "accountUuid", "account_uuid", "id"]),
              let email = string(account, ["email_address", "emailAddress", "email"]) else {
            throw AnthropicAPIError.malformedResponse
        }

        // El bloque se escribe con las mismas claves que usa Claude Code en
        // ~/.claude.json, para que su sesión lo entienda al cambiar de cuenta.
        var block: [String: Any] = [
            "accountUuid": uuid,
            "emailAddress": email
        ]
        if let name = string(account, ["display_name", "displayName", "full_name", "name"]) {
            block["displayName"] = name
        }
        if let organizationUuid = string(organization, ["uuid", "organizationUuid", "id"]) {
            block["organizationUuid"] = organizationUuid
        }
        if let organizationName = string(organization, ["name", "organizationName"]) {
            block["organizationName"] = organizationName
        }
        if let organizationType = string(organization, ["organization_type", "organizationType"]) {
            block["organizationType"] = organizationType
        }
        if let role = string(organization, ["role", "organizationRole"]) {
            block["organizationRole"] = role
        }
        if let billing = string(account, ["billing_type", "billingType"])
            ?? string(organization, ["billing_type", "billingType"]) {
            block["billingType"] = billing
        }
        if let seat = string(account, ["seat_tier", "seatTier"])
            ?? string(organization, ["seat_tier", "seatTier"]) {
            block["seatTier"] = seat
        }
        let json = try JSONSerialization.data(
            withJSONObject: block,
            options: [.sortedKeys]
        )
        return try AccountIdentity(oauthAccountJSON: json)
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
