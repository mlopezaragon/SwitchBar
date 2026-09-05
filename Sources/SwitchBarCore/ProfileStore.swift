import Foundation

/// Perfiles vinculados de Claude Code.
///
/// - Metadatos no secretos: `profiles.json` (0600).
/// - Tokens: una única entrada privada del Llavero creada por SwitchBar.
///
/// La entrada usa una versión nueva para no heredar ACL defectuosas de builds
/// antiguas. La app empaquetada se firma siempre con una identidad estable, de
/// modo que las actualizaciones conservan el acceso sin volver a pedir la
/// contraseña del Mac.
public final class ProfileStore: @unchecked Sendable {
    private let keychain: KeychainStoring
    private let directoryURL: URL
    private let lock = NSLock()

    /// Formato actual. No reutilizar el nombre antiguo: una actualización de
    /// datos preserva su ACL, incluido cualquier permiso defectuoso.
    /// Los identificadores de almacenamiento conservan el nombre original del
    /// proyecto (ClaudeSwitch): son opacos para el usuario y cambiarlos
    /// dejaría huérfanas las sesiones ya guardadas en instalaciones previas.
    static let vaultService = "com.mlopara.ClaudeSwitch.profile-vault.v2"
    private static let legacyVaultService = "ClaudeSwitch-credentials"

    public init(keychain: KeychainStoring, directoryURL: URL) {
        self.keychain = keychain
        self.directoryURL = directoryURL
    }

    public convenience init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        // Nombre histórico: ver el comentario de `vaultService`.
        let directory = support.appendingPathComponent("ClaudeSwitch")
        self.init(
            keychain: KeychainService(allowedServices: [Self.vaultService]),
            directoryURL: directory
        )
    }

    private var profilesURL: URL {
        directoryURL.appendingPathComponent("profiles.json")
    }

    private static func legacyService(for accountUuid: String) -> String {
        "ClaudeSwitch-profile-\(accountUuid)"
    }

    // MARK: Lectura y escritura estrictas

    private func loadVaultLocked() throws -> [String: Any] {
        guard let encoded = try keychain.readString(service: Self.vaultService) else {
            return [:]
        }
        guard let dictionary = try? JSONSerialization.jsonObject(
            with: Data(encoded.utf8)
        ) as? [String: Any] else {
            throw CoreError.malformedJSON(
                L10n.tr("core.error.vault_corrupt")
            )
        }
        for (account, value) in dictionary {
            guard let credentials = value as? [String: Any],
                  let data = try? JSONSerialization.data(
                      withJSONObject: credentials,
                      options: [.sortedKeys]
                  ),
                  (try? OAuthCredentials(claudeAiOauthJSON: data)) != nil else {
                throw CoreError.malformedJSON(
                    L10n.tr(
                        "core.error.account_credentials_corrupt",
                        account
                    )
                )
            }
        }
        return dictionary
    }

    private func saveVaultLocked(_ vault: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: vault,
            options: [.sortedKeys]
        )
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw KeychainError.notUTF8
        }
        try keychain.writeString(encoded, service: Self.vaultService)
    }

    private func loadProfilesLocked() throws -> [AccountProfile] {
        try SecureFileIO.ensurePrivateDirectory(directoryURL)
        guard let data = try SecureFileIO.readIfPresent(profilesURL) else {
            return []
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: profilesURL.path
        )
        do {
            return try JSONDecoder().decode([AccountProfile].self, from: data)
        } catch {
            throw CoreError.malformedJSON(
                L10n.tr("core.error.profiles_corrupt")
            )
        }
    }

    private func saveProfilesLocked(_ profiles: [AccountProfile]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try SecureFileIO.writeAtomically(
            try encoder.encode(profiles),
            to: profilesURL
        )
    }

    /// Dos almacenes distintos no pueden confirmarse en una sola transacción.
    /// Se escribe primero el Llavero y, si falla el fichero, se restaura el
    /// blob anterior. Un fallo de restauración deja como mucho un secreto
    /// huérfano; nunca destruye el perfil anterior.
    private func commitLocked(
        profiles newProfiles: [AccountProfile],
        vault newVault: [String: Any],
        previousVault: [String: Any]
    ) throws {
        try saveVaultLocked(newVault)
        do {
            try saveProfilesLocked(newProfiles)
        } catch {
            try? saveVaultLocked(previousVault)
            throw error
        }
    }

    // MARK: Migración segura del breve formato en fichero

    /// Importa `secrets.json` al Llavero y solo elimina el fichero después de
    /// verificar que el nuevo blob se puede releer. No toca entradas antiguas
    /// del Llavero, porque hacerlo al arrancar podría solicitar autorización.
    @discardableResult
    public func migrateLegacyFileIfNeeded() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let legacy = FileVault(directoryURL: directoryURL)
        guard legacy.exists else { return false }

        let values = try legacy.allValues()
        var destination = try loadVaultLocked()
        var imported = false
        var recognizedServices = Set<String>()

        if let encoded = values[Self.legacyVaultService] {
            recognizedServices.insert(Self.legacyVaultService)
            guard let oldVault = try? JSONSerialization.jsonObject(
                with: Data(encoded.utf8)
            ) as? [String: Any] else {
                throw CoreError.malformedJSON(
                    L10n.tr("core.error.legacy_vault_corrupt")
                )
            }
            for (account, value) in oldVault {
                guard let credentials = value as? [String: Any],
                      let data = try? JSONSerialization.data(
                          withJSONObject: credentials,
                          options: [.sortedKeys]
                      ),
                      (try? OAuthCredentials(claudeAiOauthJSON: data)) != nil else {
                    throw CoreError.malformedJSON(
                        L10n.tr(
                            "core.error.legacy_account_corrupt",
                            account
                        )
                    )
                }
                if destination[account] == nil {
                    destination[account] = credentials
                    imported = true
                }
            }
        }

        let knownProfiles = try loadProfilesLocked()
        for profile in knownProfiles {
            let service = Self.legacyService(for: profile.accountUuid)
            guard let encoded = values[service] else { continue }
            recognizedServices.insert(service)
            guard let credentials = try? JSONSerialization.jsonObject(
                      with: Data(encoded.utf8)
                  ) as? [String: Any],
                  let data = try? JSONSerialization.data(
                      withJSONObject: credentials,
                      options: [.sortedKeys]
                  ),
                  (try? OAuthCredentials(claudeAiOauthJSON: data)) != nil else {
                throw CoreError.malformedJSON(
                    L10n.tr(
                        "core.error.legacy_account_corrupt",
                        profile.emailAddress
                    )
                )
            }
            if destination[profile.accountUuid] == nil {
                destination[profile.accountUuid] = credentials
                imported = true
            }
        }

        let unknownServices = Set(values.keys).subtracting(recognizedServices)
        guard unknownServices.isEmpty else {
            throw CoreError.malformedJSON(
                L10n.tr("core.error.unknown_legacy_entries")
            )
        }

        if imported {
            try saveVaultLocked(destination)
            let verified = try loadVaultLocked()
            guard Set(verified.keys) == Set(destination.keys) else {
                throw CoreError.malformedJSON(
                    L10n.tr("core.error.secret_migration_verification")
                )
            }
        }
        try legacy.removeStorageFile()
        return imported
    }

    // MARK: Metadatos y operaciones

    public func loadProfiles() throws -> [AccountProfile] {
        lock.lock(); defer { lock.unlock() }
        return try loadProfilesLocked()
    }

    @discardableResult
    public func saveProfile(
        identity: AccountIdentity,
        credentials: OAuthCredentials,
        onlyIfFresher: Bool = false
    ) throws -> AccountProfile {
        lock.lock(); defer { lock.unlock() }
        var profile = AccountProfile(
            identity: identity,
            subscriptionType: credentials.subscriptionType,
            refreshTokenFingerprint: AccountProfile.fingerprint(
                of: credentials.refreshToken
            )
        )
        var currentProfiles = try loadProfilesLocked()
        let originalProfiles = currentProfiles
        let previousVault = try loadVaultLocked()
        if let existing = currentProfiles.first(where: {
            $0.accountUuid == profile.accountUuid
        }) {
            if onlyIfFresher,
               let stored = previousVault[profile.accountUuid] as? [String: Any],
               let storedExpiry = (stored["expiresAt"] as? NSNumber)?.intValue,
               storedExpiry > (credentials.expiresAt ?? 0) {
                return existing
            }
            profile.subscriptionType = credentials.subscriptionType ?? existing.subscriptionType
            profile.sharedFiveHourCap = existing.sharedFiveHourCap
            profile.sharedWeeklyCap = existing.sharedWeeklyCap
        }
        currentProfiles.removeAll { $0.accountUuid == profile.accountUuid }
        currentProfiles.append(profile)
        currentProfiles.sort {
            $0.emailAddress.localizedCaseInsensitiveCompare($1.emailAddress)
                == .orderedAscending
        }

        var newVault = previousVault
        newVault[profile.accountUuid] = try credentials.asDictionary()
        // The identity watcher runs often. Unchanged syncs must not rewrite
        // the entire vault and fsync metadata on every polling interval.
        if currentProfiles == originalProfiles,
           NSDictionary(dictionary: newVault).isEqual(to: previousVault) {
            return profile
        }
        try commitLocked(
            profiles: currentProfiles,
            vault: newVault,
            previousVault: previousVault
        )
        return profile
    }

    public func credentials(for accountUuid: String) throws -> OAuthCredentials? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = try loadVaultLocked()[accountUuid] as? [String: Any] else {
            return nil
        }
        let data = try JSONSerialization.data(
            withJSONObject: entry,
            options: [.sortedKeys]
        )
        return try OAuthCredentials(claudeAiOauthJSON: data)
    }

    @discardableResult
    public func updateCredentials(
        _ credentials: OAuthCredentials,
        for accountUuid: String,
        expectedAccessToken: String? = nil
    ) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        var currentProfiles = try loadProfilesLocked()
        guard let index = currentProfiles.firstIndex(where: {
            $0.accountUuid == accountUuid
        }) else { return false }

        let previousVault = try loadVaultLocked()
        if let expectedAccessToken,
           (previousVault[accountUuid] as? [String: Any])?["accessToken"] as? String != expectedAccessToken {
            return false
        }
        var newVault = previousVault
        newVault[accountUuid] = try credentials.asDictionary()
        currentProfiles[index].refreshTokenFingerprint =
            AccountProfile.fingerprint(of: credentials.refreshToken)
        currentProfiles[index].needsLogin = false
        try commitLocked(
            profiles: currentProfiles,
            vault: newVault,
            previousVault: previousVault
        )
        return true
    }

    public func setSharedCaps(
        fiveHour: Double?,
        weekly: Double?,
        for accountUuid: String
    ) throws {
        lock.lock(); defer { lock.unlock() }
        var currentProfiles = try loadProfilesLocked()
        guard let index = currentProfiles.firstIndex(where: {
            $0.accountUuid == accountUuid
        }) else { return }
        currentProfiles[index].sharedFiveHourCap = fiveHour
        currentProfiles[index].sharedWeeklyCap = weekly
        try saveProfilesLocked(currentProfiles)
    }

    public func markNeedsLogin(_ accountUuid: String, _ flag: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        var currentProfiles = try loadProfilesLocked()
        guard let index = currentProfiles.firstIndex(where: {
            $0.accountUuid == accountUuid
        }) else { return }
        currentProfiles[index].needsLogin = flag
        try saveProfilesLocked(currentProfiles)
    }

    public func removeProfile(_ accountUuid: String) throws {
        lock.lock(); defer { lock.unlock() }
        var currentProfiles = try loadProfilesLocked()
        currentProfiles.removeAll { $0.accountUuid == accountUuid }
        let previousVault = try loadVaultLocked()
        var newVault = previousVault
        newVault[accountUuid] = nil
        try commitLocked(
            profiles: currentProfiles,
            vault: newVault,
            previousVault: previousVault
        )
    }
}
