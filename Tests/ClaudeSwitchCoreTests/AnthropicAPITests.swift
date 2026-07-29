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

@Test func decodificaRenovacionSinRefreshNuevo() throws {
    let json = Data("{\"access_token\": \"nuevo\"}".utf8)
    let r = try JSONDecoder().decode(TokenRefreshResponse.self, from: json)
    #expect(r.accessToken == "nuevo")
    #expect(r.refreshToken == nil)
    #expect(r.expiresIn == nil)
}
