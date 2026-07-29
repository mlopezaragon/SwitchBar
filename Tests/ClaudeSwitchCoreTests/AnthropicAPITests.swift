import Foundation
import Testing
@testable import ClaudeSwitchCore

@Test func decodificaRespuestaDeRenovacion() throws {
    let json = Data("""
    {"access_token": "nuevo", "refresh_token": "nuevoRef", "expires_in": 3600, "token_type": "Bearer"}
    """.utf8)
    let r = try JSONDecoder().decode(TokenRefreshResponse.self, from: json)
    #expect(r.accessToken == "nuevo")
    #expect(r.refreshToken == "nuevoRef")
    #expect(r.expiresIn == 3600)
}

@Test func laSesionDeLoginGeneraURLCorrecta() {
    let session = AnthropicAPI.makeLoginSession()
    let comps = URLComponents(url: session.url, resolvingAgainstBaseURL: false)!
    #expect(comps.host == "claude.ai")
    let items = Dictionary(uniqueKeysWithValues: comps.queryItems!.map { ($0.name, $0.value ?? "") })
    #expect(items["code"] == "true")
    #expect(items["response_type"] == "code")
    #expect(items["code_challenge_method"] == "S256")
    #expect(items["state"] == session.state)
    #expect(items["code_challenge"]?.isEmpty == false)
    #expect(items["scope"]?.contains("user:inference") == true)
    // El verifier no viaja en la URL.
    #expect(!session.url.absoluteString.contains(session.codeVerifier))
}

@Test func parseaLaRespuestaDelCanjeDeCodigo() throws {
    let json = Data("""
    {"access_token": "at", "refresh_token": "rt", "expires_in": 3600,
     "scope": "user:profile user:inference",
     "account": {"uuid": "u-1", "email_address": "papa@gmail.com", "display_name": "Papá"},
     "organization": {"uuid": "org-1", "name": "Personal"}}
    """.utf8)
    let (creds, identity) = try AnthropicAPI.parseExchangeResponse(json)
    #expect(creds.accessToken == "at")
    #expect(creds.refreshToken == "rt")
    #expect(!creds.isAccessTokenExpired())
    #expect(identity.accountUuid == "u-1")
    #expect(identity.emailAddress == "papa@gmail.com")
    #expect(identity.displayName == "Papá")
    let oauthDict = try creds.asDictionary()
    #expect((oauthDict["scopes"] as? [String])?.contains("user:inference") == true)
}

@Test func canjeSinCuentaFalla() {
    let json = Data("{\"access_token\": \"at\", \"refresh_token\": \"rt\"}".utf8)
    #expect(throws: AnthropicAPIError.self) {
        _ = try AnthropicAPI.parseExchangeResponse(json)
    }
}

@Test func decodificaRenovacionSinRefreshNuevo() throws {
    let json = Data("{\"access_token\": \"nuevo\"}".utf8)
    let r = try JSONDecoder().decode(TokenRefreshResponse.self, from: json)
    #expect(r.accessToken == "nuevo")
    #expect(r.refreshToken == nil)
    #expect(r.expiresIn == nil)
}
