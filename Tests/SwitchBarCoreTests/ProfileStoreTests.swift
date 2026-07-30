import Foundation
import Testing
@testable import SwitchBarCore

private func makeProfileStore() throws -> ProfileStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return ProfileStore(keychain: FakeKeychain(), directoryURL: dir)
}

private func identidad(_ uuid: String, _ email: String) throws -> AccountIdentity {
    try AccountIdentity(oauthAccountJSON: Data("""
    {"accountUuid": "\(uuid)", "emailAddress": "\(email)", "organizationRole": "admin"}
    """.utf8))
}

private func credenciales(_ token: String) throws -> OAuthCredentials {
    try OAuthCredentials(claudeAiOauthJSON: Data("""
    {"accessToken": "\(token)", "refreshToken": "ref-\(token)", "expiresAt": 1, "subscriptionType": "max"}
    """.utf8))
}

@Test func guardaYRecuperaPerfiles() throws {
    let store = try makeProfileStore()
    try store.saveProfile(identity: identidad("u1", "a@a.com"), credentials: credenciales("t1"))
    try store.saveProfile(identity: identidad("u2", "b@b.com"), credentials: credenciales("t2"))

    let profiles = try store.loadProfiles()
    #expect(profiles.map(\.emailAddress) == ["a@a.com", "b@b.com"])
    #expect(profiles[0].subscriptionType == "max")
    #expect(try store.credentials(for: "u1")?.accessToken == "t1")
    #expect(try store.credentials(for: "u2")?.refreshToken == "ref-t2")
}

@Test func guardarDosVecesNoDuplica() throws {
    let store = try makeProfileStore()
    try store.saveProfile(identity: identidad("u1", "a@a.com"), credentials: credenciales("t1"))
    try store.saveProfile(identity: identidad("u1", "a@a.com"), credentials: credenciales("t9"))
    #expect(try store.loadProfiles().count == 1)
    #expect(try store.credentials(for: "u1")?.accessToken == "t9")
}

@Test func actualizaCredencialesYMarcaNeedsLogin() throws {
    let store = try makeProfileStore()
    try store.saveProfile(identity: identidad("u1", "a@a.com"), credentials: credenciales("t1"))
    try store.updateCredentials(credenciales("t2"), for: "u1")
    #expect(try store.credentials(for: "u1")?.accessToken == "t2")

    try store.markNeedsLogin("u1", true)
    #expect(try store.loadProfiles()[0].needsLogin)
    try store.markNeedsLogin("u1", false)
    #expect(try !store.loadProfiles()[0].needsLogin)
}

@Test func losTopesCompartidosSobrevivenAlReguardado() throws {
    let store = try makeProfileStore()
    try store.saveProfile(identity: identidad("u1", "a@a.com"), credentials: credenciales("t1"))
    try store.setSharedCaps(fiveHour: 60, weekly: 50, for: "u1")
    // Volcado periódico: re-guardar el perfil no debe borrar los topes.
    try store.saveProfile(identity: identidad("u1", "a@a.com"), credentials: credenciales("t2"))
    let p = try store.loadProfiles()[0]
    #expect(p.sharedFiveHourCap == 60)
    #expect(p.sharedWeeklyCap == 50)
    // Quitar el tope.
    try store.setSharedCaps(fiveHour: nil, weekly: nil, for: "u1")
    #expect(try store.loadProfiles()[0].sharedFiveHourCap == nil)
}

@Test func eliminaPerfilYSecretos() throws {
    let store = try makeProfileStore()
    try store.saveProfile(identity: identidad("u1", "a@a.com"), credentials: credenciales("t1"))
    try store.removeProfile("u1")
    #expect(try store.loadProfiles().isEmpty)
    #expect(try store.credentials(for: "u1") == nil)
}

@Test func unProfilesJsonCorruptoNuncaSeSobrescribe() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let profilesURL = directory.appendingPathComponent("profiles.json")
    let corrupt = Data("{cuenta incompleta".utf8)
    try corrupt.write(to: profilesURL)
    let store = ProfileStore(
        keychain: FakeKeychain(),
        directoryURL: directory
    )

    #expect(throws: CoreError.self) {
        try store.saveProfile(
            identity: identidad("u1", "a@a.com"),
            credentials: credenciales("t1")
        )
    }
    #expect(try Data(contentsOf: profilesURL) == corrupt)
}

@Test func unVaultCorruptoNuncaSeSobrescribe() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let keychain = FakeKeychain()
    let store = ProfileStore(keychain: keychain, directoryURL: directory)
    try store.saveProfile(
        identity: identidad("u1", "a@a.com"),
        credentials: credenciales("t1")
    )
    try keychain.writeString("no es JSON", service: ProfileStore.vaultService)

    #expect(throws: CoreError.self) {
        try store.updateCredentials(credenciales("t2"), for: "u1")
    }
    #expect(
        try keychain.readString(service: ProfileStore.vaultService)
            == "no es JSON"
    )
}

@Test func metadatosYDirectorioTienenPermisosPrivados() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let store = ProfileStore(
        keychain: FakeKeychain(),
        directoryURL: directory
    )
    try store.saveProfile(
        identity: identidad("u1", "a@a.com"),
        credentials: credenciales("t1")
    )
    let fileMode = (
        try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("profiles.json").path
        )[.posixPermissions] as? NSNumber
    )?.intValue
    let directoryMode = (
        try FileManager.default.attributesOfItem(atPath: directory.path)[
            .posixPermissions
        ] as? NSNumber
    )?.intValue
    #expect(fileMode == 0o600)
    #expect(directoryMode == 0o700)
}

@Test func corrigePermisosHeredadosAlLeerSinCambiarContenido() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let profilesURL = directory.appendingPathComponent("profiles.json")
    let original = Data("[]".utf8)
    try original.write(to: profilesURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o644],
        ofItemAtPath: profilesURL.path
    )
    let store = ProfileStore(
        keychain: FakeKeychain(),
        directoryURL: directory
    )

    _ = try store.loadProfiles()
    let mode = (
        try FileManager.default.attributesOfItem(
            atPath: profilesURL.path
        )[.posixPermissions] as? NSNumber
    )?.intValue
    #expect(mode == 0o600)
    #expect(try Data(contentsOf: profilesURL) == original)
}

@Test func migracionImportaYEliminaSecretsSoloTrasVerificar() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let keychain = FakeKeychain()
    let store = ProfileStore(keychain: keychain, directoryURL: directory)
    let identity = try identidad("u1", "a@a.com")
    let credentials = try credenciales("t1")
    try store.saveProfile(identity: identity, credentials: credentials)
    try keychain.delete(service: ProfileStore.vaultService)

    let legacy = FileVault(directoryURL: directory)
    let encoded = String(
        data: try JSONSerialization.data(
            withJSONObject: ["u1": try credentials.asDictionary()]
        ),
        encoding: .utf8
    )!
    try legacy.writeString(encoded, service: "ClaudeSwitch-credentials")

    #expect(try store.migrateLegacyFileIfNeeded())
    #expect(try store.credentials(for: "u1")?.accessToken == "t1")
    #expect(
        !FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("secrets.json").path
        )
    )
}

@Test func migracionConEntradaDesconocidaConservaSecretsIntacto() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let legacy = FileVault(directoryURL: directory)
    try legacy.writeString("valor", service: "servicio-desconocido")
    let secretsURL = directory.appendingPathComponent("secrets.json")
    let original = try Data(contentsOf: secretsURL)
    let store = ProfileStore(
        keychain: FakeKeychain(),
        directoryURL: directory
    )

    #expect(throws: CoreError.self) {
        try store.migrateLegacyFileIfNeeded()
    }
    #expect(try Data(contentsOf: secretsURL) == original)
}
