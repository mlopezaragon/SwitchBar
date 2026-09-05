import Foundation
import Testing
@testable import SwitchBarCore

private final class EnrollmentProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var exchanges = 0
    nonisolated(unsafe) private static var profiles = 0
    nonisolated(unsafe) private static var failFirstProfile = false

    static func reset(failProfile: Bool) {
        lock.withLock { exchanges = 0; profiles = 0; failFirstProfile = failProfile }
    }
    static var counts: (Int, Int) { lock.withLock { (exchanges, profiles) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let isToken = request.url == AnthropicAPI.tokenEndpoint
        let fail = Self.lock.withLock {
            if isToken { Self.exchanges += 1; return false }
            Self.profiles += 1
            return Self.failFirstProfile && Self.profiles == 1
        }
        let body = isToken
            ? #"{"access_token":"test-access","refresh_token":"test-refresh","expires_in":3600}"#
            : #"{"account":{"uuid":"test-account","email":"test@example.com"}}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: fail ? 503 : 200,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized) struct EnrollmentTests {
    private func session() -> OAuthEnrollmentSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EnrollmentProtocol.self]
        return OAuthEnrollmentSession(api: AnthropicAPI(session: URLSession(configuration: config)),
                                      flow: OAuthLoginFlow(verifier: "test", state: "state"))
    }
    @Test func retryAfterProfileFailureDoesNotRedeemTheCodeAgain() async throws {
        EnrollmentProtocol.reset(failProfile: true)
        let enrollment = session()
        await #expect(throws: AnthropicAPIError.httpError(503)) {
            try await enrollment.complete(code: "single-use-code")
        }
        let account = try await enrollment.complete(code: "single-use-code")
        #expect(account.identity.accountUuid == "test-account")
        #expect(!account.credentials.isAccessTokenExpired())
        #expect(EnrollmentProtocol.counts.0 == 1)
        #expect(EnrollmentProtocol.counts.1 == 2)
    }
    @Test func duplicateSubmissionsShareOneExchangeAndProfileRequest() async throws {
        EnrollmentProtocol.reset(failProfile: false)
        let enrollment = session()
        async let first = enrollment.complete(code: "same-code")
        async let second = enrollment.complete(code: "same-code")
        let accounts = try await [first, second]
        #expect(accounts[0].identity == accounts[1].identity)
        #expect(EnrollmentProtocol.counts.0 == 1)
        #expect(EnrollmentProtocol.counts.1 == 1)
        // A retry after a local save error also reuses the completed login.
        _ = try await enrollment.complete(code: "same-code")
        #expect(EnrollmentProtocol.counts.0 == 1)
        #expect(EnrollmentProtocol.counts.1 == 1)
    }
    @Test func incompleteTokensCannotCreateAnUnrefreshableProfile() {
        #expect(throws: AnthropicAPIError.malformedResponse) {
            try OAuthEnrollmentSession.credentials(from: RefreshedTokens(
                accessToken: "test", refreshToken: nil, expiresIn: 3600))
        }
        #expect(throws: AnthropicAPIError.malformedResponse) {
            try OAuthEnrollmentSession.credentials(from: RefreshedTokens(
                accessToken: "test", refreshToken: "refresh", expiresIn: .infinity))
        }
    }
}
