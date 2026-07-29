import Foundation

public enum SwitchError: Error, Equatable {
    case profileNotFound(String)
    case profileNeedsLogin(String)
    case nothingToUndo
    /// El Llavero y ~/.claude.json no describen la misma cuenta: no es seguro
    /// volcar ni capturar hasta que Claude Code (o un cambio) los realinee.
    case inconsistentActiveState
}

/// Cambio de cuenta activa de Claude Code.
///
/// Antes de escribir el perfil destino, vuelca las credenciales activas al
/// perfil de origen (si existe): Claude Code puede haberlas renovado y el
/// refresh token viejo quedaría inservible si no se recogiera.
public final class SwitchEngine: @unchecked Sendable {
    private let store: ClaudeCodeStore
    private let profiles: ProfileStore
    private let defaults: UserDefaults

    private static let lastSwitchKey = "lastSwitchFromTo"

    public init(store: ClaudeCodeStore, profiles: ProfileStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.profiles = profiles
        self.defaults = defaults
    }

    public func activeAccountUuid() -> String? {
        try? store.readActiveIdentity()?.accountUuid
    }

    /// Lee identidad y credenciales activas comprobando que describen la
    /// misma cuenta. Detecta dos estados descasados: la identidad cambió
    /// entre lecturas, o las credenciales del Llavero pertenecen a otro
    /// perfil guardado (cambio a medias). En ambos casos lanza
    /// `inconsistentActiveState` en vez de emparejar mal.
    private func readActivePair() throws -> (AccountIdentity, OAuthCredentials)? {
        guard let identity = try store.readActiveIdentity(),
              let creds = try store.readActiveCredentials() else { return nil }
        try checkPairConsistency(identity: identity, credentials: creds)
        return (identity, creds)
    }

    /// Comprueba que identidad y credenciales describen la misma cuenta. La
    /// pertenencia se decide con la huella del refresh token guardada en cada
    /// perfil, sin leer sus secretos del Llavero (cada lectura podría abrir un
    /// diálogo de autorización).
    private func checkPairConsistency(identity: AccountIdentity, credentials: OAuthCredentials) throws {
        guard let recheck = try store.readActiveIdentity(), recheck.accountUuid == identity.accountUuid else {
            throw SwitchError.inconsistentActiveState
        }
        let fingerprint = AccountProfile.fingerprint(of: credentials.refreshToken)
        for other in profiles.loadProfiles() where other.accountUuid != identity.accountUuid {
            if let known = other.refreshTokenFingerprint, known == fingerprint {
                throw SwitchError.inconsistentActiveState
            }
        }
    }

    /// Vuelca el estado activo (credenciales + identidad) a su perfil, si existe.
    public func syncActiveIntoProfile() throws {
        guard let (identity, creds) = try readActivePair() else { return }
        let known = profiles.loadProfiles().contains { $0.accountUuid == identity.accountUuid }
        guard known else { return }
        try profiles.saveProfile(identity: identity, credentials: creds)
        profiles.markNeedsLogin(identity.accountUuid, false)
    }

    @discardableResult
    public func switchTo(_ accountUuid: String) throws -> AccountIdentity {
        let all = profiles.loadProfiles()
        guard let target = all.first(where: { $0.accountUuid == accountUuid }) else {
            throw SwitchError.profileNotFound(accountUuid)
        }
        if target.needsLogin { throw SwitchError.profileNeedsLogin(accountUuid) }
        guard let creds = try profiles.credentials(for: accountUuid) else {
            throw SwitchError.profileNeedsLogin(accountUuid)
        }
        if creds.isRefreshTokenExpired() {
            profiles.markNeedsLogin(accountUuid, true)
            throw SwitchError.profileNeedsLogin(accountUuid)
        }

        let previous = activeAccountUuid()
        // Una sola lectura del Llavero de Claude Code para todo el cambio:
        // sirve a la vez para volcar la sesión saliente a su perfil, para
        // preservar las demás claves (mcpOAuth…) y para poder revertir.
        let blob = try store.readCredentialsBlob()
        let previousCreds = blob?.credentials

        if let previousCreds,
           let previousIdentity = try store.readActiveIdentity(),
           all.contains(where: { $0.accountUuid == previousIdentity.accountUuid }) {
            try checkPairConsistency(identity: previousIdentity, credentials: previousCreds)
            try profiles.saveProfile(identity: previousIdentity, credentials: previousCreds)
            profiles.markNeedsLogin(previousIdentity.accountUuid, false)
        }

        let identity = try target.identity()
        let base = try blob ?? ClaudeCodeStore.CredentialsBlob(dictionary: [:])
        let newBlob = try base.replacingCredentials(creds)
        try store.writeCredentialsBlob(newBlob)
        do {
            try store.writeActiveIdentity(identity)
        } catch {
            // Revertir el Llavero para no dejar credenciales e identidad descasadas.
            if let blob { try? store.writeCredentialsBlob(blob) }
            throw error
        }

        if let previous, previous != accountUuid {
            defaults.set([previous, accountUuid], forKey: Self.lastSwitchKey)
        }
        return identity
    }

    /// Alta de cuenta: guarda la sesión activa de Claude Code como perfil.
    @discardableResult
    public func captureActiveAsProfile() throws -> AccountProfile {
        guard let (identity, creds) = try readActivePair() else {
            throw SwitchError.profileNotFound("cuenta activa")
        }
        return try profiles.saveProfile(identity: identity, credentials: creds)
    }

    public var canUndo: Bool {
        (defaults.array(forKey: Self.lastSwitchKey) as? [String])?.count == 2
    }

    @discardableResult
    public func undoLastSwitch() throws -> AccountIdentity {
        guard let pair = defaults.array(forKey: Self.lastSwitchKey) as? [String], pair.count == 2 else {
            throw SwitchError.nothingToUndo
        }
        let identity = try switchTo(pair[0])
        defaults.removeObject(forKey: Self.lastSwitchKey)
        return identity
    }
}
