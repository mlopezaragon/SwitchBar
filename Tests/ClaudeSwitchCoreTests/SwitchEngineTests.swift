import Foundation
import Testing
@testable import ClaudeSwitchCore

private struct Entorno {
    let engine: SwitchEngine
    let store: ClaudeCodeStore
    let profiles: ProfileStore
    let keychain: FakeKeychain
    let jsonURL: URL
}

private func makeEntorno() throws -> Entorno {
    let keychain = FakeKeychain()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let jsonURL = dir.appendingPathComponent(".claude.json")
    let store = ClaudeCodeStore(keychain: keychain, claudeJsonURL: jsonURL)
    let profiles = ProfileStore(keychain: keychain, directoryURL: dir)
    let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
    return Entorno(
        engine: SwitchEngine(store: store, profiles: profiles, defaults: defaults),
        store: store, profiles: profiles, keychain: keychain, jsonURL: jsonURL
    )
}

private func activarCuenta(_ e: Entorno, uuid: String, email: String, token: String, extraLlavero: String = "") throws {
    try e.keychain.writeString("""
    {"claudeAiOauth": {"accessToken": "\(token)", "refreshToken": "ref-\(token)", "expiresAt": 1, "subscriptionType": "max"}\(extraLlavero)}
    """, service: ClaudeCodeStore.credentialsService)
    try Data("""
    {"otherSetting": true, "oauthAccount": {"accountUuid": "\(uuid)", "emailAddress": "\(email)"}}
    """.utf8).write(to: e.jsonURL)
}

@Test func capturaLaCuentaActivaComoPerfil() throws {
    let e = try makeEntorno()
    try activarCuenta(e, uuid: "u1", email: "a@a.com", token: "t1")
    let perfil = try e.engine.captureActiveAsProfile()
    #expect(perfil.emailAddress == "a@a.com")
    #expect(try e.profiles.credentials(for: "u1")?.accessToken == "t1")
}

@Test func cambiarConservaTokensRenovadosDelOrigen() throws {
    let e = try makeEntorno()
    // Cuenta A activa con perfil guardado (tokens viejos en el perfil).
    try activarCuenta(e, uuid: "uA", email: "a@a.com", token: "viejoA")
    try e.engine.captureActiveAsProfile()
    // Perfil B guardado.
    let idB = try AccountIdentity(oauthAccountJSON: Data("{\"accountUuid\": \"uB\", \"emailAddress\": \"b@b.com\"}".utf8))
    let credsB = try OAuthCredentials(claudeAiOauthJSON: Data("{\"accessToken\": \"tB\", \"refreshToken\": \"refB\", \"expiresAt\": 2}".utf8))
    try e.profiles.saveProfile(identity: idB, credentials: credsB)
    // Claude Code renueva los tokens de A mientras tanto.
    try activarCuenta(e, uuid: "uA", email: "a@a.com", token: "renovadoA", extraLlavero: ", \"mcpOAuth\": {\"srv\": {\"accessToken\": \"m1\"}}")

    try e.engine.switchTo("uB")

    // El perfil de A recogió el token renovado antes del cambio.
    #expect(try e.profiles.credentials(for: "uA")?.accessToken == "renovadoA")
    // La cuenta activa ahora es B y mcpOAuth sobrevive.
    #expect(try e.store.readActiveCredentials()?.accessToken == "tB")
    #expect(try e.store.readActiveIdentity()?.emailAddress == "b@b.com")
    let llavero = try JSONSerialization.jsonObject(with: Data(e.keychain.readString(service: ClaudeCodeStore.credentialsService)!.utf8)) as! [String: Any]
    #expect(((llavero["mcpOAuth"] as? [String: Any])?["srv"] as? [String: Any])?["accessToken"] as? String == "m1")
}

@Test func deshacerVuelveALaCuentaAnterior() throws {
    let e = try makeEntorno()
    try activarCuenta(e, uuid: "uA", email: "a@a.com", token: "tA")
    try e.engine.captureActiveAsProfile()
    let idB = try AccountIdentity(oauthAccountJSON: Data("{\"accountUuid\": \"uB\", \"emailAddress\": \"b@b.com\"}".utf8))
    let credsB = try OAuthCredentials(claudeAiOauthJSON: Data("{\"accessToken\": \"tB\", \"refreshToken\": \"refB\", \"expiresAt\": 2}".utf8))
    try e.profiles.saveProfile(identity: idB, credentials: credsB)

    try e.engine.switchTo("uB")
    #expect(e.engine.canUndo)
    try e.engine.undoLastSwitch()
    #expect(try e.store.readActiveIdentity()?.accountUuid == "uA")
    #expect(!e.engine.canUndo)
}

@Test func cambiarAPerfilInexistenteFalla() throws {
    let e = try makeEntorno()
    #expect(throws: SwitchError.profileNotFound("uX")) {
        try e.engine.switchTo("uX")
    }
}

@Test func cambiarAPerfilSinSesionFalla() throws {
    let e = try makeEntorno()
    let idB = try AccountIdentity(oauthAccountJSON: Data("{\"accountUuid\": \"uB\", \"emailAddress\": \"b@b.com\"}".utf8))
    let credsB = try OAuthCredentials(claudeAiOauthJSON: Data("{\"accessToken\": \"tB\", \"refreshToken\": \"refB\", \"expiresAt\": 2}".utf8))
    try e.profiles.saveProfile(identity: idB, credentials: credsB)
    e.profiles.markNeedsLogin("uB", true)
    #expect(throws: SwitchError.profileNeedsLogin("uB")) {
        try e.engine.switchTo("uB")
    }
}
