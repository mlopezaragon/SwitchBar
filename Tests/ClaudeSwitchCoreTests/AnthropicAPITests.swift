import Foundation
import Testing
@testable import ClaudeSwitchCore

private final class UsageSuccessProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var observedRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.observedRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self,
            didLoad: Data(#"{"five_hour":{"utilization":12}}"#.utf8)
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class RateLimitProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "123"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Test
func consultaDeUsoEsSoloLecturaYUsaElAccessToken() async throws {
    UsageSuccessProtocol.observedRequest = nil
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [UsageSuccessProtocol.self]
    let api = AnthropicAPI(session: URLSession(configuration: configuration))

    let usage = try await api.fetchUsage(accessToken: "access-uno")
    #expect(usage.fiveHour?.utilization == 12)
    #expect(UsageSuccessProtocol.observedRequest?.httpMethod == "GET")
    #expect(
        UsageSuccessProtocol.observedRequest?.value(
            forHTTPHeaderField: "Authorization"
        ) == "Bearer access-uno"
    )
    #expect(UsageSuccessProtocol.observedRequest?.httpBody == nil)
}

private final class TokenRefreshSuccessProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var observedRequest: URLRequest?
    nonisolated(unsafe) static var observedBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.observedRequest = request
        Self.observedBody = request.httpBody
            ?? request.httpBodyStream.map { stream in
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 1_024)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    guard read > 0 else { break }
                    data.append(buffer, count: read)
                }
                return data
            }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self,
            didLoad: Data(
                #"{"access_token":"nuevo-access","refresh_token":"nuevo-refresh","expires_in":28800}"#.utf8
            )
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class TokenInvalidGrantProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 400,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self,
            didLoad: Data(#"{"error":"invalid_grant"}"#.utf8)
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Test
func renovarSesionUsaElFlujoEstandarDeRefreshToken() async throws {
    TokenRefreshSuccessProtocol.observedRequest = nil
    TokenRefreshSuccessProtocol.observedBody = nil
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TokenRefreshSuccessProtocol.self]
    let api = AnthropicAPI(session: URLSession(configuration: configuration))

    let refreshed = try await api.refreshAccessToken(
        refreshToken: "refresh-uno"
    )
    #expect(refreshed.accessToken == "nuevo-access")
    #expect(refreshed.refreshToken == "nuevo-refresh")
    #expect(refreshed.expiresIn == 28_800)
    #expect(TokenRefreshSuccessProtocol.observedRequest?.httpMethod == "POST")
    #expect(
        TokenRefreshSuccessProtocol.observedRequest?.url?.absoluteString
            == "https://console.anthropic.com/v1/oauth/token"
    )
    let body = try JSONSerialization.jsonObject(
        with: TokenRefreshSuccessProtocol.observedBody ?? Data()
    ) as? [String: String]
    #expect(body?["grant_type"] == "refresh_token")
    #expect(body?["refresh_token"] == "refresh-uno")
    #expect(body?["client_id"] == "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
}

@Test
func refreshTokenRevocadoSeDistingueDeOtrosErrores() async {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TokenInvalidGrantProtocol.self]
    let api = AnthropicAPI(session: URLSession(configuration: configuration))

    await #expect(throws: AnthropicAPIError.invalidGrant) {
        _ = try await api.refreshAccessToken(refreshToken: "revocado")
    }
}

@Test
func limiteDePeticionesSePropagaSinRenovarTokens() async {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RateLimitProtocol.self]
    let api = AnthropicAPI(session: URLSession(configuration: configuration))

    await #expect(
        throws: AnthropicAPIError.rateLimited(retryAfter: 123)
    ) {
        _ = try await api.fetchUsage(accessToken: "access")
    }
}
