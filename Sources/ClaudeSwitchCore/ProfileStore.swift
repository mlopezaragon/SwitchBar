import Foundation

/// Perfiles de cuenta guardados. Los metadatos (sin secretos) viven en
/// `profiles.json` dentro del directorio dado; los tokens de cada cuenta, en
/// una entrada del Llavero `ClaudeSwitch-profile-<accountUuid>`.
public final class ProfileStore: @unchecked Sendable {
    private let keychain: KeychainStoring
    private let directoryURL: URL
    private let lock = NSLock()

    public init(keychain: KeychainStoring, directoryURL: URL) {
        self.keychain = keychain
        self.directoryURL = directoryURL
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    public convenience init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(keychain: KeychainService(), directoryURL: support.appendingPathComponent("ClaudeSwitch"))
    }

    private var profilesURL: URL { directoryURL.appendingPathComponent("profiles.json") }

    private static func service(for accountUuid: String) -> String {
        "ClaudeSwitch-profile-\(accountUuid)"
    }

    // MARK: Metadatos

    public func loadProfiles() -> [AccountProfile] {
        lock.lock(); defer { lock.unlock() }
        return loadProfilesLocked()
    }

    private func loadProfilesLocked() -> [AccountProfile] {
        guard let data = try? Data(contentsOf: profilesURL),
              let profiles = try? JSONDecoder().decode([AccountProfile].self, from: data) else { return [] }
        return profiles
    }

    private func saveProfilesLocked(_ profiles: [AccountProfile]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: profilesURL, options: [.atomic])
    }

    // MARK: Operaciones

    @discardableResult
    public func saveProfile(identity: AccountIdentity, credentials: OAuthCredentials) throws -> AccountProfile {
        lock.lock(); defer { lock.unlock() }
        let profile = AccountProfile(identity: identity, subscriptionType: credentials.subscriptionType)
        var profiles = loadProfilesLocked()
        profiles.removeAll { $0.accountUuid == profile.accountUuid }
        profiles.append(profile)
        profiles.sort { $0.emailAddress < $1.emailAddress }
        try saveProfilesLocked(profiles)
        guard let s = String(data: credentials.rawJSON, encoding: .utf8) else { throw KeychainError.notUTF8 }
        try keychain.writeString(s, service: Self.service(for: profile.accountUuid))
        return profile
    }

    public func credentials(for accountUuid: String) throws -> OAuthCredentials? {
        guard let s = try keychain.readString(service: Self.service(for: accountUuid)) else { return nil }
        return try OAuthCredentials(claudeAiOauthJSON: Data(s.utf8))
    }

    public func updateCredentials(_ credentials: OAuthCredentials, for accountUuid: String) throws {
        lock.lock(); defer { lock.unlock() }
        // Si el perfil se eliminó mientras tanto, no recrear sus secretos.
        guard loadProfilesLocked().contains(where: { $0.accountUuid == accountUuid }) else { return }
        guard let s = String(data: credentials.rawJSON, encoding: .utf8) else { throw KeychainError.notUTF8 }
        try keychain.writeString(s, service: Self.service(for: accountUuid))
    }

    public func markNeedsLogin(_ accountUuid: String, _ flag: Bool) {
        lock.lock(); defer { lock.unlock() }
        var profiles = loadProfilesLocked()
        guard let i = profiles.firstIndex(where: { $0.accountUuid == accountUuid }) else { return }
        profiles[i].needsLogin = flag
        try? saveProfilesLocked(profiles)
    }

    public func removeProfile(_ accountUuid: String) throws {
        lock.lock(); defer { lock.unlock() }
        var profiles = loadProfilesLocked()
        profiles.removeAll { $0.accountUuid == accountUuid }
        try saveProfilesLocked(profiles)
        try keychain.delete(service: Self.service(for: accountUuid))
    }
}
