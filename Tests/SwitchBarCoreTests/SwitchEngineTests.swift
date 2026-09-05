import Foundation
import Testing
@testable import SwitchBarCore

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

@Test func cambiarSoloTocaDosVecesElLlaveroDeClaudeCode() throws {
    // Cada acceso a "Claude Code-credentials" puede abrir un diálogo de
    // autorización, así que un cambio debe costar una lectura y una escritura.
    let e = try makeEntorno()
    try activarCuenta(e, uuid: "uA", email: "a@a.com", token: "tA")
    try e.engine.captureActiveAsProfile()
    let idB = try AccountIdentity(oauthAccountJSON: Data("{\"accountUuid\": \"uB\", \"emailAddress\": \"b@b.com\"}".utf8))
    let credsB = try OAuthCredentials(claudeAiOauthJSON: Data("{\"accessToken\": \"tB\", \"refreshToken\": \"refB\", \"expiresAt\": 2}".utf8))
    try e.profiles.saveProfile(identity: idB, credentials: credsB)

    e.keychain.resetCounters()
    try e.engine.switchTo("uB")
    #expect(e.keychain.accesses(to: ClaudeCodeStore.credentialsService) == 2)
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

@Test func estadoDescasadoNoMachacaElPerfil() throws {
    // ~/.claude.json dice cuenta A, pero el Llavero tiene las credenciales de B
    // (cambio a medias): el volcado debe negarse en vez de guardar los tokens
    // de B dentro del perfil de A.
    let e = try makeEntorno()
    try activarCuenta(e, uuid: "uA", email: "a@a.com", token: "tA")
    try e.engine.captureActiveAsProfile()
    let idB = try AccountIdentity(oauthAccountJSON: Data("{\"accountUuid\": \"uB\", \"emailAddress\": \"b@b.com\"}".utf8))
    let credsB = try OAuthCredentials(claudeAiOauthJSON: Data("{\"accessToken\": \"tB\", \"refreshToken\": \"refB\", \"expiresAt\": 2}".utf8))
    try e.profiles.saveProfile(identity: idB, credentials: credsB)

    // Llavero con credenciales de B, identidad sigue siendo A.
    try e.keychain.writeString("{\"claudeAiOauth\": {\"accessToken\": \"tB\", \"refreshToken\": \"refB\", \"expiresAt\": 2}}", service: ClaudeCodeStore.credentialsService)

    #expect(throws: SwitchError.inconsistentActiveState) {
        try e.engine.syncActiveIntoProfile()
    }
    // El perfil de A conserva sus tokens.
    #expect(try e.profiles.credentials(for: "uA")?.accessToken == "tA")
}

@Test func reparacionExplicitaRecuperaUnLlaveroTruncado() throws {
    let e = try makeEntorno()
    try activarCuenta(e, uuid: "uA", email: "a@a.com", token: "tA")
    try e.engine.captureActiveAsProfile()
    let idB = try AccountIdentity(
        oauthAccountJSON: Data(
            "{\"accountUuid\": \"uB\", \"emailAddress\": \"b@b.com\"}".utf8
        )
    )
    let credsB = try OAuthCredentials(
        claudeAiOauthJSON: Data(
            "{\"accessToken\": \"tB\", \"refreshToken\": \"refB\"}".utf8
        )
    )
    try e.profiles.saveProfile(identity: idB, credentials: credsB)
    try e.keychain.writeString(
        "{\"claudeAiOauth\":{\"accessToken\":\"cortado",
        service: ClaudeCodeStore.credentialsService
    )

    let repaired = try e.engine.repairAndSwitchTo("uB")

    #expect(repaired.accountUuid == "uB")
    #expect(try e.store.readActiveCredentials()?.accessToken == "tB")
    #expect(try e.store.readActiveIdentity()?.accountUuid == "uB")
    #expect(try e.profiles.credentials(for: "uA")?.accessToken == "tA")
}

@Test func reparacionConBlobLegibleConservaMcpOAuth() throws {
    let e = try makeEntorno()
    try activarCuenta(e, uuid: "uA", email: "a@a.com", token: "tA")
    try e.engine.captureActiveAsProfile()
    let idB = try AccountIdentity(
        oauthAccountJSON: Data(
            "{\"accountUuid\": \"uB\", \"emailAddress\": \"b@b.com\"}".utf8
        )
    )
    let credsB = try OAuthCredentials(
        claudeAiOauthJSON: Data(
            "{\"accessToken\": \"tB\", \"refreshToken\": \"refB\"}".utf8
        )
    )
    try e.profiles.saveProfile(identity: idB, credentials: credsB)
    try e.keychain.writeString(
        """
        {"claudeAiOauth":{"accessToken":"tB","refreshToken":"refB"},
         "mcpOAuth":{"srv":{"accessToken":"mcp-token"}}}
        """,
        service: ClaudeCodeStore.credentialsService
    )

    try e.engine.repairAndSwitchTo("uA")

    let stored = try e.keychain.readString(
        service: ClaudeCodeStore.credentialsService
    )
    let encoded = try #require(stored)
    let blob = try #require(
        JSONSerialization.jsonObject(
            with: Data(encoded.utf8)
        ) as? [String: Any]
    )
    let mcp = try #require(blob["mcpOAuth"] as? [String: Any])
    let server = try #require(mcp["srv"] as? [String: Any])
    #expect(server["accessToken"] as? String == "mcp-token")
    #expect(try e.store.readActiveCredentials()?.accessToken == "tA")
}

@Test func cambiarACuentaConRefreshTokenCaducadoFalla() throws {
    let e = try makeEntorno()
    let idB = try AccountIdentity(oauthAccountJSON: Data("{\"accountUuid\": \"uB\", \"emailAddress\": \"b@b.com\"}".utf8))
    let credsB = try OAuthCredentials(claudeAiOauthJSON: Data("{\"accessToken\": \"tB\", \"refreshToken\": \"refB\", \"expiresAt\": 2, \"refreshTokenExpiresAt\": 1000}".utf8))
    try e.profiles.saveProfile(identity: idB, credentials: credsB)
    #expect(throws: SwitchError.profileNeedsLogin("uB")) {
        try e.engine.switchTo("uB")
    }
    // Y queda marcada como pendiente de sesión.
    #expect(try e.profiles.loadProfiles().first?.needsLogin == true)
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
    try e.profiles.markNeedsLogin("uB", true)
    #expect(throws: SwitchError.profileNeedsLogin("uB")) {
        try e.engine.switchTo("uB")
    }
}

@Test func reconectarUnaCuentaNoAceptaOtraCuentaActiva() throws {
    let e = try makeEntorno()
    try activarCuenta(e, uuid: "uA", email: "a@a.com", token: "tA")
    try e.engine.captureActiveAsProfile()
    let idB = try AccountIdentity(
        oauthAccountJSON: Data(
            "{\"accountUuid\": \"uB\", \"emailAddress\": \"b@b.com\"}".utf8
        )
    )
    let credsB = try OAuthCredentials(
        claudeAiOauthJSON: Data(
            "{\"accessToken\": \"tB\", \"refreshToken\": \"refB\"}".utf8
        )
    )
    try e.profiles.saveProfile(identity: idB, credentials: credsB)
    try e.profiles.markNeedsLogin("uB", true)

    #expect(
        throws: SwitchError.unexpectedActiveAccount(
            expected: "uB",
            actual: "uA"
        )
    ) {
        try e.engine.captureActiveAsProfile(expectedAccountUuid: "uB")
    }
    #expect(try e.profiles.loadProfiles().first {
        $0.accountUuid == "uB"
    }?.needsLogin == true)
}

@Test func adoptarUnTokenRenovadoActualizaElLlaveroDeClaudeCode() throws {
    let e = try makeEntorno()
    try activarCuenta(
        e,
        uuid: "uA",
        email: "a@a.com",
        token: "viejo",
        extraLlavero: ", \"mcpOAuth\": {\"srv\": {\"accessToken\": \"m1\"}}"
    )
    try e.engine.captureActiveAsProfile()
    let renovadas = try OAuthCredentials(
        claudeAiOauthJSON: Data(
            "{\"accessToken\": \"nuevo\", \"refreshToken\": \"ref-nuevo\"}".utf8
        )
    )

    try e.engine.adoptRenewedActiveCredentials(renovadas, for: "uA")

    #expect(try e.store.readActiveCredentials()?.accessToken == "nuevo")
    #expect(
        try e.store.readActiveCredentials()?.refreshToken == "ref-nuevo"
    )
    // Las demás claves del Llavero (mcpOAuth…) siguen intactas.
    let bruto = try e.keychain.readString(
        service: ClaudeCodeStore.credentialsService
    )
    #expect(bruto?.contains("mcpOAuth") == true)
}

@Test func adoptarUnTokenRenovadoNoPisaOtraCuentaActiva() throws {
    let e = try makeEntorno()
    // El usuario cambió a otra cuenta mientras se renovaba la anterior.
    try activarCuenta(e, uuid: "uB", email: "b@b.com", token: "tB")
    let renovadas = try OAuthCredentials(
        claudeAiOauthJSON: Data(
            "{\"accessToken\": \"nuevo\", \"refreshToken\": \"ref-nuevo\"}".utf8
        )
    )

    #expect(throws: SwitchError.inconsistentActiveState) {
        try e.engine.adoptRenewedActiveCredentials(renovadas, for: "uA")
    }
    #expect(try e.store.readActiveCredentials()?.accessToken == "tB")
}

@Test func cambiarALaMismaCuentaNoRestauraTokensAntiguos() throws {
    let e = try makeEntorno()
    try activarCuenta(e, uuid: "a", email: "a@example.com", token: "old")
    try e.engine.captureActiveAsProfile()
    try activarCuenta(e, uuid: "a", email: "a@example.com", token: "renewed")
    e.keychain.resetCounters()
    try e.engine.switchTo("a")
    #expect(e.keychain.accesses(to: ClaudeCodeStore.credentialsService) == 1)
    #expect(try e.store.readActiveCredentials()?.accessToken == "renewed")
    #expect(try e.profiles.credentials(for: "a")?.accessToken == "renewed")
}
