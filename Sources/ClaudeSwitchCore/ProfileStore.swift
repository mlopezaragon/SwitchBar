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
        // Mismo backend que la entrada de Claude Code: así una única
        // autorización de "/usr/bin/security" cubre todos los accesos.
        self.init(keychain: SecurityCLIKeychain(), directoryURL: support.appendingPathComponent("ClaudeSwitch"))
    }

    private var profilesURL: URL { directoryURL.appendingPathComponent("profiles.json") }

    /// Una única entrada del Llavero con las credenciales de todas las cuentas
    /// (`{accountUuid: {claudeAiOauth…}}`). Con una entrada por cuenta, macOS
    /// pedía autorización una vez por cada una; así el permiso se concede una
    /// sola vez.
    static let vaultService = "ClaudeSwitch-credentials"

    /// Formato antiguo: una entrada por cuenta. Se migra al arrancar.
    private static func legacyService(for accountUuid: String) -> String {
        "ClaudeSwitch-profile-\(accountUuid)"
    }

    private func loadVault() -> [String: Any] {
        guard let s = try? keychain.readString(service: Self.vaultService) ?? nil,
              let dict = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else { return [:] }
        return dict
    }

    private func saveVault(_ vault: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: vault, options: [.sortedKeys])
        guard let s = String(data: data, encoding: .utf8) else { throw KeychainError.notUTF8 }
        try keychain.writeString(s, service: Self.vaultService)
    }

    /// Mueve los secretos del formato antiguo (una entrada por cuenta) al
    /// almacén único. Se ejecuta una sola vez; después borra las entradas
    /// viejas para que no vuelvan a pedir autorización.
    public func migrateLegacyEntriesIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        var vault = loadVault()
        var migrated = false
        for profile in loadProfilesLocked() where vault[profile.accountUuid] == nil {
            guard let s = try? keychain.readString(service: Self.legacyService(for: profile.accountUuid)) ?? nil,
                  let dict = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else { continue }
            vault[profile.accountUuid] = dict
            migrated = true
        }
        guard migrated else { return }
        guard (try? saveVault(vault)) != nil else { return }
        for profile in loadProfilesLocked() {
            try? keychain.delete(service: Self.legacyService(for: profile.accountUuid))
        }
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
        var profile = AccountProfile(
            identity: identity,
            subscriptionType: credentials.subscriptionType,
            refreshTokenFingerprint: AccountProfile.fingerprint(of: credentials.refreshToken)
        )
        var profiles = loadProfilesLocked()
        // Al re-guardar (volcados periódicos) se conservan los ajustes propios
        // del perfil que no vienen de Claude Code, como los topes compartidos.
        if let existing = profiles.first(where: { $0.accountUuid == profile.accountUuid }) {
            profile.sharedFiveHourCap = existing.sharedFiveHourCap
            profile.sharedWeeklyCap = existing.sharedWeeklyCap
        }
        profiles.removeAll { $0.accountUuid == profile.accountUuid }
        profiles.append(profile)
        profiles.sort { $0.emailAddress < $1.emailAddress }
        try saveProfilesLocked(profiles)
        var vault = loadVault()
        vault[profile.accountUuid] = try credentials.asDictionary()
        try saveVault(vault)
        return profile
    }

    public func credentials(for accountUuid: String) throws -> OAuthCredentials? {
        guard let entry = loadVault()[accountUuid] as? [String: Any] else { return nil }
        let data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
        return try OAuthCredentials(claudeAiOauthJSON: data)
    }

    public func updateCredentials(_ credentials: OAuthCredentials, for accountUuid: String) throws {
        lock.lock(); defer { lock.unlock() }
        var profiles = loadProfilesLocked()
        // Si el perfil se eliminó mientras tanto, no recrear sus secretos.
        guard let i = profiles.firstIndex(where: { $0.accountUuid == accountUuid }) else { return }
        var vault = loadVault()
        vault[accountUuid] = try credentials.asDictionary()
        try saveVault(vault)
        profiles[i].refreshTokenFingerprint = AccountProfile.fingerprint(of: credentials.refreshToken)
        try? saveProfilesLocked(profiles)
    }

    /// Fija los topes personales de una cuenta compartida (nil = sin tope).
    public func setSharedCaps(fiveHour: Double?, weekly: Double?, for accountUuid: String) {
        lock.lock(); defer { lock.unlock() }
        var profiles = loadProfilesLocked()
        guard let i = profiles.firstIndex(where: { $0.accountUuid == accountUuid }) else { return }
        profiles[i].sharedFiveHourCap = fiveHour
        profiles[i].sharedWeeklyCap = weekly
        try? saveProfilesLocked(profiles)
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
        var vault = loadVault()
        vault[accountUuid] = nil
        try saveVault(vault)
        try? keychain.delete(service: Self.legacyService(for: accountUuid))
    }
}
