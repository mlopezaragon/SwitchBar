import Foundation
import Testing
@testable import SwitchBarCore

// Una misma cuenta (mismo accountUuid y correo) en su organización personal,
// con plan Max, y en la de un equipo, con plan Team.

private func identidad(org: String?, type: String) throws -> AccountIdentity {
    let organization = org.map { #", "organizationUuid": "\#($0)""# } ?? ""
    return try AccountIdentity(oauthAccountJSON: Data("""
    {"accountUuid": "persona", "emailAddress": "p@empresa.com", "organizationType": "\(type)"\(organization)}
    """.utf8))
}

private func credenciales(_ token: String) throws -> OAuthCredentials {
    try OAuthCredentials(claudeAiOauthJSON: Data("""
    {"accessToken": "\(token)", "refreshToken": "ref-\(token)", "expiresAt": 1}
    """.utf8))
}

private func makeStore() -> (ProfileStore, FakeKeychain, URL) {
    let keychain = FakeKeychain()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return (ProfileStore(keychain: keychain, directoryURL: dir), keychain, dir)
}

@Test func elIdentificadorDePerfilIncluyeLaOrganizacion() throws {
    let max = try identidad(org: "org-max", type: "claude_max")
    let team = try identidad(org: "org-team", type: "claude_team")
    #expect(max.id == "persona/org-max")
    #expect(team.id == "persona/org-team")
    #expect(max.id != team.id)
    #expect(try identidad(org: nil, type: "claude_max").id == "persona")
    #expect(Diagnostics.tag("persona-123456/org-team") == "persona-/org-")
    #expect(Diagnostics.tag("persona-123456") == "persona-")
}

@Test func laMismaCuentaEnDosOrganizacionesConvive() throws {
    let (store, _, _) = makeStore()
    try store.saveProfile(identity: identidad(org: "org-max", type: "claude_max"), credentials: credenciales("max"))
    try store.saveProfile(identity: identidad(org: "org-team", type: "claude_team"), credentials: credenciales("team"))

    let profiles = try store.loadProfiles()
    #expect(profiles.map(\.id) == ["persona/org-max", "persona/org-team"])
    #expect(profiles.map(\.plan) == [.max, .team])
    #expect(try store.credentials(for: "persona/org-max")?.accessToken == "max")
    #expect(try store.credentials(for: "persona/org-team")?.accessToken == "team")

    // Repetir el login de una organización solo renueva la suya.
    try store.saveProfile(identity: identidad(org: "org-max", type: "claude_max"), credentials: credenciales("max-2"))
    #expect(try store.loadProfiles().count == 2)
    #expect(try store.credentials(for: "persona/org-max")?.accessToken == "max-2")
    #expect(try store.credentials(for: "persona/org-team")?.accessToken == "team")

    try store.removeProfile("persona/org-team")
    #expect(try store.loadProfiles().map(\.id) == ["persona/org-max"])
    #expect(try store.credentials(for: "persona/org-max")?.accessToken == "max-2")
}

@Test func lasCredencialesGuardadasPorAccountUuidSeMigran() throws {
    let (store, keychain, dir) = makeStore()
    // Estado de la 1.0.3: perfil sin `organizationUuid` aparte y credenciales
    // bajo el accountUuid.
    let identity = try identidad(org: "org-max", type: "claude_max")
    let legacyProfile = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
        AccountProfile(identity: identity, subscriptionType: "max")
    )) as! [String: Any]
    var stored = legacyProfile
    stored["organizationUuid"] = nil
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: [stored]).write(to: dir.appendingPathComponent("profiles.json"))
    try keychain.writeString(
        String(data: JSONSerialization.data(withJSONObject: ["persona": try credenciales("max").asDictionary()]), encoding: .utf8)!,
        service: ProfileStore.vaultService
    )

    #expect(try store.loadProfiles().map(\.id) == ["persona/org-max"])
    #expect(try store.credentials(for: "persona/org-max") == nil)

    #expect(try store.migrateProfileKeysIfNeeded())
    #expect(try store.credentials(for: "persona/org-max")?.accessToken == "max")
    #expect(try store.credentials(for: "persona") == nil)
    // Una segunda pasada no vuelve a escribir el Llavero.
    keychain.resetCounters()
    #expect(try !store.migrateProfileKeysIfNeeded())
    #expect(keychain.accesses(to: ProfileStore.vaultService) == 1)

    // Si la sesión ya se guardó con la clave nueva, la antigua se retira sin
    // pisarla.
    try keychain.writeString(
        String(data: JSONSerialization.data(withJSONObject: [
            "persona": try credenciales("vieja").asDictionary(),
            "persona/org-max": try credenciales("max").asDictionary()
        ]), encoding: .utf8)!,
        service: ProfileStore.vaultService
    )
    #expect(try store.migrateProfileKeysIfNeeded())
    #expect(try store.credentials(for: "persona/org-max")?.accessToken == "max")
    #expect(try store.credentials(for: "persona") == nil)

    // Ahora sí puede añadirse la otra organización sin pisar la primera.
    try store.saveProfile(identity: identidad(org: "org-team", type: "claude_team"), credentials: credenciales("team"))
    #expect(try store.credentials(for: "persona/org-max")?.accessToken == "max")
}

@Test func lasClavesAntiguasSeTrasladanSoloSinAmbiguedad() throws {
    let max = AccountProfile(identity: try identidad(org: "org-max", type: "claude_max"), subscriptionType: nil)
    let team = AccountProfile(identity: try identidad(org: "org-team", type: "claude_team"), subscriptionType: nil)
    let other = AccountProfile(
        identity: try AccountIdentity(oauthAccountJSON: Data(
            #"{"accountUuid": "otra", "emailAddress": "o@o.com", "organizationUuid": "org-o"}"#.utf8
        )),
        subscriptionType: nil
    )
    let values = ["otra": 1, "persona": 2, "persona/org-max": 3]

    // Con un solo dueño, la clave antigua pasa a la actual.
    #expect(ProfileID.adoptingLegacyKeys(values, profiles: [other, max]) == ["otra/org-o": 1, "persona/org-max": 3])
    // Con dos organizaciones de la misma cuenta no se adivina.
    #expect(ProfileID.currentKey(for: "persona", profiles: [max, team]) == "persona")
    #expect(ProfileID.currentKey(for: "persona/org-team", profiles: [max, team]) == "persona/org-team")
}

@Test func cambiarEntreOrganizacionesDeLaMismaCuenta() throws {
    let keychain = FakeKeychain()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let jsonURL = dir.appendingPathComponent(".claude.json")
    let store = ClaudeCodeStore(keychain: keychain, claudeJsonURL: jsonURL)
    let profiles = ProfileStore(keychain: keychain, directoryURL: dir)
    let engine = SwitchEngine(
        store: store, profiles: profiles,
        defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!
    )

    // Claude Code tiene activa la organización Max.
    try keychain.writeString("""
    {"claudeAiOauth": {"accessToken": "max", "refreshToken": "ref-max", "expiresAt": 1}}
    """, service: ClaudeCodeStore.credentialsService)
    try Data("""
    {"oauthAccount": {"accountUuid": "persona", "emailAddress": "p@empresa.com", "organizationUuid": "org-max", "organizationType": "claude_max"}}
    """.utf8).write(to: jsonURL)
    try engine.captureActiveAsProfile()
    try profiles.saveProfile(identity: identidad(org: "org-team", type: "claude_team"), credentials: credenciales("team"))
    #expect(engine.activeProfileID() == "persona/org-max")

    // Claude Code renueva la sesión Max antes del cambio.
    try keychain.writeString("""
    {"claudeAiOauth": {"accessToken": "max-renovado", "refreshToken": "ref-max-renovado", "expiresAt": 2}}
    """, service: ClaudeCodeStore.credentialsService)

    let identity = try engine.switchTo("persona/org-team")
    #expect(identity.id == "persona/org-team")
    #expect(engine.activeProfileID() == "persona/org-team")
    #expect(try store.readActiveCredentials()?.accessToken == "team")
    // La sesión saliente se guarda en su propia organización, no en la otra.
    #expect(try profiles.credentials(for: "persona/org-max")?.accessToken == "max-renovado")
    #expect(try profiles.credentials(for: "persona/org-team")?.accessToken == "team")

    // Y se puede deshacer hacia la organización anterior.
    #expect(try engine.undoLastSwitch().id == "persona/org-max")
    #expect(try store.readActiveCredentials()?.accessToken == "max-renovado")
}

@Test func reconectarPideLaOrganizacionDelPerfil() {
    let plain = OAuthLoginFlow(verifier: "v", state: "s")
    #expect(!plain.authorizationURL.absoluteString.contains("orgUUID"))
    let scoped = OAuthLoginFlow(verifier: "v", state: "s", organizationUuid: "org-team")
    let items = URLComponents(url: scoped.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems
    #expect(items?.first { $0.name == "orgUUID" }?.value == "org-team")
}

@Test func laEtiquetaDelPlanDistingueLasOrganizaciones() throws {
    let team = AccountProfile(identity: try AccountIdentity(oauthAccountJSON: Data("""
    {"accountUuid": "persona", "emailAddress": "p@empresa.com", "organizationUuid": "org-team", "organizationType": "claude_team", "organizationName": "Empresa"}
    """.utf8)), subscriptionType: nil)
    let max = AccountProfile(identity: try identidad(org: "org-max", type: "claude_max"), subscriptionType: nil)
    #expect(team.planLabel == "Team · Empresa")
    #expect(max.planLabel == "Max")
}
