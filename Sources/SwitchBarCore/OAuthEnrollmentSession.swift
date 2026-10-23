import Foundation

public struct EnrolledAccount: Sendable {
    public let identity: AccountIdentity
    public let credentials: OAuthCredentials
}

/// A code is single-use. Keep the successful exchange in memory if fetching
/// the profile fails, so retrying does not redeem the same code a second time.
/// Concurrent submissions share one task and therefore one network exchange.
public actor OAuthEnrollmentSession {
    private let api: AnthropicAPI
    private let flow: OAuthLoginFlow
    private var credentials: OAuthCredentials?
    /// Organización que declara el canje del código.
    private var tokenOrganizationUuid: String?
    private var result: EnrolledAccount?
    private var inFlight: Task<EnrolledAccount, Error>?

    public init(api: AnthropicAPI, flow: OAuthLoginFlow) {
        self.api = api
        self.flow = flow
    }

    public func complete(code: String) async throws -> EnrolledAccount {
        if let result { return result }
        if let inFlight { return try await inFlight.value }
        let task = Task { try await self.perform(code: code) }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    private func perform(code: String) async throws -> EnrolledAccount {
        if credentials == nil {
            let tokens = try await api.exchangeAuthorizationCode(
                code, verifier: flow.verifier, state: flow.state
            )
            credentials = try Self.credentials(from: tokens)
            tokenOrganizationUuid = tokens.organizationUuid
        }
        guard let credentials else { throw AnthropicAPIError.malformedResponse }
        let identity = try await api.fetchProfile(accessToken: credentials.accessToken)
        // Rastro para diagnosticar altas de cuentas con varias
        // organizaciones: qué organización se pidió, cuál declara el token y
        // cuál devuelve el perfil. Solo prefijos de identificadores.
        Diagnostics.usage.log(
            "alta: pedida \(Self.tag(self.flow.organizationUuid), privacy: .public), token \(Self.tag(self.tokenOrganizationUuid), privacy: .public), perfil \(Self.tag(identity.organizationUuid), privacy: .public)"
        )
        let account = EnrolledAccount(identity: identity, credentials: credentials)
        result = account
        return account
    }

    private static func tag(_ organizationUuid: String?) -> String {
        organizationUuid.map { String($0.prefix(8)) } ?? "—"
    }

    static func credentials(from tokens: RefreshedTokens, now: Date = Date()) throws -> OAuthCredentials {
        guard !tokens.accessToken.isEmpty,
              let refreshToken = tokens.refreshToken, !refreshToken.isEmpty,
              let lifetime = tokens.expiresIn, lifetime.isFinite, lifetime > 0,
              lifetime < 365 * 24 * 3_600
        else { throw AnthropicAPIError.malformedResponse }
        var credentials: [String: Any] = [
            "accessToken": tokens.accessToken,
            "refreshToken": refreshToken,
            "expiresAt": Int(now.addingTimeInterval(lifetime).timeIntervalSince1970 * 1000),
            "scopes": OAuthLoginFlow.scopes
        ]
        if let refreshLifetime = tokens.refreshTokenExpiresIn,
           refreshLifetime.isFinite, refreshLifetime > 0 {
            credentials["refreshTokenExpiresAt"] =
                Int(now.addingTimeInterval(refreshLifetime).timeIntervalSince1970 * 1000)
        }
        let data = try JSONSerialization.data(withJSONObject: credentials, options: [.sortedKeys])
        return try OAuthCredentials(claudeAiOauthJSON: data)
    }
}
