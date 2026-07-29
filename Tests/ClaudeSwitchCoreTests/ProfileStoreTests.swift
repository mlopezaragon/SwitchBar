import Foundation
import Testing
@testable import ClaudeSwitchCore

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

    let profiles = store.loadProfiles()
    #expect(profiles.map(\.emailAddress) == ["a@a.com", "b@b.com"])
    #expect(profiles[0].subscriptionType == "max")
    #expect(try store.credentials(for: "u1")?.accessToken == "t1")
    #expect(try store.credentials(for: "u2")?.refreshToken == "ref-t2")
}

@Test func guardarDosVecesNoDuplica() throws {
    let store = try makeProfileStore()
    try store.saveProfile(identity: identidad("u1", "a@a.com"), credentials: credenciales("t1"))
    try store.saveProfile(identity: identidad("u1", "a@a.com"), credentials: credenciales("t9"))
    #expect(store.loadProfiles().count == 1)
    #expect(try store.credentials(for: "u1")?.accessToken == "t9")
}

@Test func actualizaCredencialesYMarcaNeedsLogin() throws {
    let store = try makeProfileStore()
    try store.saveProfile(identity: identidad("u1", "a@a.com"), credentials: credenciales("t1"))
    try store.updateCredentials(credenciales("t2"), for: "u1")
    #expect(try store.credentials(for: "u1")?.accessToken == "t2")

    store.markNeedsLogin("u1", true)
    #expect(store.loadProfiles()[0].needsLogin)
    store.markNeedsLogin("u1", false)
    #expect(!store.loadProfiles()[0].needsLogin)
}

@Test func eliminaPerfilYSecretos() throws {
    let store = try makeProfileStore()
    try store.saveProfile(identity: identidad("u1", "a@a.com"), credentials: credenciales("t1"))
    try store.removeProfile("u1")
    #expect(store.loadProfiles().isEmpty)
    #expect(try store.credentials(for: "u1") == nil)
}
