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
        }
        guard let credentials else { throw AnthropicAPIError.malformedResponse }
        let identity = try await api.fetchProfile(accessToken: credentials.accessToken)
        let account = EnrolledAccount(identity: identity, credentials: credentials)
        result = account
        return account
    }

    static func credentials(from tokens: RefreshedTokens, now: Date = Date()) throws -> OAuthCredentials {
        guard !tokens.accessToken.isEmpty,
              let refreshToken = tokens.refreshToken, !refreshToken.isEmpty,
              let lifetime = tokens.expiresIn, lifetime.isFinite, lifetime > 0,
              lifetime < 365 * 24 * 3_600
        else { throw AnthropicAPIError.malformedResponse }
        let data = try JSONSerialization.data(withJSONObject: [
            "accessToken": tokens.accessToken,
            "refreshToken": refreshToken,
            "expiresAt": Int(now.addingTimeInterval(lifetime).timeIntervalSince1970 * 1000),
            "scopes": OAuthLoginFlow.scopes
        ], options: [.sortedKeys])
        return try OAuthCredentials(claudeAiOauthJSON: data)
    }
}
