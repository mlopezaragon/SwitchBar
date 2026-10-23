import Foundation

public enum SwitchError: Error, Equatable {
    case profileNotFound(String)
    case profileNeedsLogin(String)
    case nothingToUndo
    case unexpectedActiveAccount(expected: String, actual: String)
    /// El Llavero y ~/.claude.json no describen la misma cuenta: no es seguro
    /// volcar ni capturar hasta que Claude Code (o un cambio) los realinee.
    case inconsistentActiveState
}

extension SwitchError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .profileNotFound(let account):
            L10n.tr("switch.error.profile_not_found", account)
        case .profileNeedsLogin:
            L10n.tr("switch.error.profile_needs_login")
        case .nothingToUndo:
            L10n.tr("switch.error.nothing_to_undo")
        case .unexpectedActiveAccount:
            L10n.tr("switch.error.unexpected_active_account")
        case .inconsistentActiveState:
            L10n.tr("switch.error.inconsistent_active_state")
        }
    }
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
    /// Serializa cambios manuales, automáticos y capturas disparadas por
    /// `/login`. Dos operaciones simultáneas podrían guardar credenciales de
    /// una cuenta bajo la identidad de otra.
    private let operationLock = NSRecursiveLock()

    private static let lastSwitchKey = "lastSwitchFromTo"

    public init(store: ClaudeCodeStore, profiles: ProfileStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.profiles = profiles
        self.defaults = defaults
    }

    public func activeProfileID() -> String? {
        operationLock.lock(); defer { operationLock.unlock() }
        return try? store.readActiveIdentity()?.id
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
        guard let recheck = try store.readActiveIdentity(), recheck.id == identity.id else {
            throw SwitchError.inconsistentActiveState
        }
        let fingerprint = AccountProfile.fingerprint(of: credentials.refreshToken)
        for other in try profiles.loadProfiles() where other.id != identity.id {
            if let known = other.refreshTokenFingerprint, known == fingerprint {
                throw SwitchError.inconsistentActiveState
            }
        }
    }

    /// Vuelca el estado activo (credenciales + identidad) a su perfil, si existe.
    public func syncActiveIntoProfile() throws {
        operationLock.lock(); defer { operationLock.unlock() }
        guard let (identity, creds) = try readActivePair() else { return }
        let known = try profiles.loadProfiles().contains {
            $0.id == identity.id
        }
        guard known else { return }
        try profiles.saveProfile(identity: identity, credentials: creds, onlyIfFresher: true)
    }

    /// Deja en la sesión oficial de Claude Code un token que SwitchBar acaba
    /// de renovar para la cuenta activa.
    ///
    /// Solo se usa cuando no hay ninguna sesión de Claude Code viva: es
    /// exactamente lo que Claude Code habría hecho al arrancar, y sin ello el
    /// refresh token que quedaría en su Llavero sería el viejo, ya rotado por
    /// el servidor, y la siguiente terminal pediría iniciar sesión.
    ///
    /// Comprueba bajo el mismo cerrojo que la cuenta activa sigue siendo la
    /// esperada: un cambio de cuenta simultáneo haría que se escribieran las
    /// credenciales de una cuenta bajo la identidad de otra.
    public func adoptRenewedActiveCredentials(
        _ credentials: OAuthCredentials,
        for profileID: String
    ) throws {
        operationLock.lock(); defer { operationLock.unlock() }
        guard let identity = try store.readActiveIdentity(),
              identity.id == profileID else {
            throw SwitchError.inconsistentActiveState
        }
        try store.writeActiveCredentials(credentials)
    }

    @discardableResult
    public func switchTo(_ profileID: String) throws -> AccountIdentity {
        operationLock.lock(); defer { operationLock.unlock() }
        if let current = try store.readActiveIdentity(), current.id == profileID {
            try syncActiveIntoProfile()
            return current
        }
        let all = try profiles.loadProfiles()
        guard let target = all.first(where: { $0.id == profileID }) else {
            throw SwitchError.profileNotFound(profileID)
        }
        if target.needsLogin { throw SwitchError.profileNeedsLogin(profileID) }
        guard let creds = try profiles.credentials(for: profileID) else {
            throw SwitchError.profileNeedsLogin(profileID)
        }
        if creds.isRefreshTokenExpired() {
            try profiles.markNeedsLogin(profileID, true)
            throw SwitchError.profileNeedsLogin(profileID)
        }

        let previous = activeProfileID()
        // Una sola lectura del Llavero de Claude Code para todo el cambio:
        // sirve a la vez para volcar la sesión saliente a su perfil, para
        // preservar las demás claves (mcpOAuth…) y para poder revertir.
        let blob = try store.readCredentialsBlob()
        let previousCreds = blob?.credentials

        if let previousCreds,
           let previousIdentity = try store.readActiveIdentity(),
           all.contains(where: { $0.id == previousIdentity.id }) {
            try checkPairConsistency(identity: previousIdentity, credentials: previousCreds)
            try profiles.saveProfile(identity: previousIdentity, credentials: previousCreds, onlyIfFresher: true)
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

        if let previous, previous != profileID {
            defaults.set([previous, profileID], forKey: Self.lastSwitchKey)
        }
        return identity
    }

    /// Recuperación explícita tras una entrada activa corrupta o descasada.
    ///
    /// No intenta guardar la sesión saliente porque no se puede demostrar a
    /// qué cuenta pertenece. Si el blob aún es legible conserva sus claves
    /// auxiliares (mcpOAuth); si está truncado, reconstruye únicamente
    /// `claudeAiOauth` desde el perfil destino.
    @discardableResult
    public func repairAndSwitchTo(
        _ profileID: String
    ) throws -> AccountIdentity {
        operationLock.lock(); defer { operationLock.unlock() }
        let all = try profiles.loadProfiles()
        guard let target = all.first(where: {
            $0.id == profileID
        }) else {
            throw SwitchError.profileNotFound(profileID)
        }
        if target.needsLogin {
            throw SwitchError.profileNeedsLogin(profileID)
        }
        guard let creds = try profiles.credentials(for: profileID) else {
            throw SwitchError.profileNeedsLogin(profileID)
        }
        if creds.isRefreshTokenExpired() {
            try profiles.markNeedsLogin(profileID, true)
            throw SwitchError.profileNeedsLogin(profileID)
        }

        let previous = activeProfileID()
        let readableBlob = try? store.readCredentialsBlob()
        let base = try readableBlob
            ?? ClaudeCodeStore.CredentialsBlob(dictionary: [:])
        let repairedBlob = try base.replacingCredentials(creds)
        try store.writeCredentialsBlob(repairedBlob)

        let identity = try target.identity()
        do {
            try store.writeActiveIdentity(identity)
        } catch {
            if let readableBlob {
                try? store.writeCredentialsBlob(readableBlob)
            }
            throw error
        }
        if let previous, previous != profileID {
            defaults.set([previous, profileID], forKey: Self.lastSwitchKey)
        }
        return identity
    }

    /// Alta de cuenta: guarda la sesión activa de Claude Code como perfil.
    @discardableResult
    public func captureActiveAsProfile(
        expectedProfileID: String? = nil
    ) throws -> AccountProfile {
        operationLock.lock(); defer { operationLock.unlock() }
        guard let (identity, creds) = try readActivePair() else {
            throw SwitchError.profileNotFound(L10n.tr("core.active_account"))
        }
        if let expectedProfileID,
           identity.id != expectedProfileID {
            throw SwitchError.unexpectedActiveAccount(
                expected: expectedProfileID,
                actual: identity.id
            )
        }
        return try profiles.saveProfile(identity: identity, credentials: creds)
    }

    public var canUndo: Bool {
        operationLock.lock(); defer { operationLock.unlock() }
        return (defaults.array(forKey: Self.lastSwitchKey) as? [String])?.count == 2
    }

    @discardableResult
    public func undoLastSwitch() throws -> AccountIdentity {
        operationLock.lock(); defer { operationLock.unlock() }
        guard let pair = defaults.array(forKey: Self.lastSwitchKey) as? [String], pair.count == 2 else {
            throw SwitchError.nothingToUndo
        }
        // Un cambio hecho por la 1.0.3 o anterior guardó claves antiguas.
        let identity = try switchTo(
            ProfileID.currentKey(for: pair[0], profiles: try profiles.loadProfiles())
        )
        defaults.removeObject(forKey: Self.lastSwitchKey)
        return identity
    }
}
