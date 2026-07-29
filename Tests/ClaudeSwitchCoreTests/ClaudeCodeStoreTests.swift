import Foundation
import Testing
@testable import ClaudeSwitchCore

private func makeStore() throws -> (ClaudeCodeStore, FakeKeychain, URL) {
    let keychain = FakeKeychain()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let jsonURL = dir.appendingPathComponent(".claude.json")
    return (ClaudeCodeStore(keychain: keychain, claudeJsonURL: jsonURL), keychain, jsonURL)
}

private let credencialesA = """
{"accessToken": "tokA", "refreshToken": "refA", "expiresAt": 111, "scopes": ["user:inference"], "subscriptionType": "max"}
"""

@Test func escribirCredencialesPreservaMcpOAuth() throws {
    let (store, keychain, _) = try makeStore()
    try keychain.writeString("""
    {"claudeAiOauth": \(credencialesA), "mcpOAuth": {"utilia-crm|abc": {"accessToken": "mcp1", "serverUrl": "https://crm"}}}
    """, service: ClaudeCodeStore.credentialsService)

    let nuevas = try OAuthCredentials(claudeAiOauthJSON: Data("""
    {"accessToken": "tokB", "refreshToken": "refB", "expiresAt": 222}
    """.utf8))
    try store.writeActiveCredentials(nuevas)

    let final = try JSONSerialization.jsonObject(with: Data(keychain.readString(service: ClaudeCodeStore.credentialsService)!.utf8)) as! [String: Any]
    let oauth = final["claudeAiOauth"] as! [String: Any]
    #expect(oauth["accessToken"] as? String == "tokB")
    let mcp = final["mcpOAuth"] as! [String: Any]
    let crm = mcp["utilia-crm|abc"] as! [String: Any]
    #expect(crm["accessToken"] as? String == "mcp1")
    #expect(crm["serverUrl"] as? String == "https://crm")
}

@Test func leerCredencialesActivas() throws {
    let (store, keychain, _) = try makeStore()
    try keychain.writeString("{\"claudeAiOauth\": \(credencialesA)}", service: ClaudeCodeStore.credentialsService)
    let creds = try store.readActiveCredentials()
    #expect(creds?.accessToken == "tokA")
    #expect(creds?.subscriptionType == "max")
}

@Test func sinEntradaDelLlaveroDevuelveNil() throws {
    let (store, _, _) = try makeStore()
    #expect(try store.readActiveCredentials() == nil)
}

@Test func noEscribeSiLaEntradaDelLlaveroEstaCorrupta() throws {
    let (store, keychain, _) = try makeStore()
    try keychain.writeString("esto no es JSON {", service: ClaudeCodeStore.credentialsService)
    let nuevas = try OAuthCredentials(claudeAiOauthJSON: Data("{\"accessToken\": \"t\", \"refreshToken\": \"r\"}".utf8))
    #expect(throws: CoreError.self) {
        try store.writeActiveCredentials(nuevas)
    }
    // El contenido original queda intacto.
    #expect(try keychain.readString(service: ClaudeCodeStore.credentialsService) == "esto no es JSON {")
}

@Test func noEscribeSiClaudeJsonEstaCorrupto() throws {
    let (store, _, jsonURL) = try makeStore()
    try Data("{fichero a medias".utf8).write(to: jsonURL)
    let nueva = try AccountIdentity(oauthAccountJSON: Data("{\"accountUuid\": \"u\", \"emailAddress\": \"a@a.com\"}".utf8))
    #expect(throws: CoreError.self) {
        try store.writeActiveIdentity(nueva)
    }
    #expect(String(data: try Data(contentsOf: jsonURL), encoding: .utf8) == "{fichero a medias")
}

@Test func escribirIdentidadDejaCopiaDeSeguridad() throws {
    let (store, _, jsonURL) = try makeStore()
    let original = "{\"oauthAccount\": {\"accountUuid\": \"u1\", \"emailAddress\": \"a@a.com\"}, \"clave\": 1}"
    try Data(original.utf8).write(to: jsonURL)
    let nueva = try AccountIdentity(oauthAccountJSON: Data("{\"accountUuid\": \"u2\", \"emailAddress\": \"b@b.com\"}".utf8))
    try store.writeActiveIdentity(nueva)
    let backup = jsonURL.appendingPathExtension("claudeswitch-backup")
    #expect(String(data: try Data(contentsOf: backup), encoding: .utf8) == original)
}

@Test func escribirIdentidadPreservaRestoDeClaudeJson() throws {
    let (store, _, jsonURL) = try makeStore()
    try Data("""
    {"projects": {"/x": {"allowedTools": []}}, "firstStartTime": "2025-01-01",
     "oauthAccount": {"accountUuid": "uuid-a", "emailAddress": "a@a.com", "organizationRole": "admin"}}
    """.utf8).write(to: jsonURL)

    let nueva = try AccountIdentity(oauthAccountJSON: Data("""
    {"accountUuid": "uuid-b", "emailAddress": "b@b.com", "displayName": "B"}
    """.utf8))
    try store.writeActiveIdentity(nueva)

    let final = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as! [String: Any]
    let account = final["oauthAccount"] as! [String: Any]
    #expect(account["emailAddress"] as? String == "b@b.com")
    #expect(final["firstStartTime"] as? String == "2025-01-01")
    #expect((final["projects"] as? [String: Any])?.keys.contains("/x") == true)

    let activa = try store.readActiveIdentity()
    #expect(activa?.accountUuid == "uuid-b")
}
