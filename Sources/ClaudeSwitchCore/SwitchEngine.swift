import Foundation

public enum SwitchError: Error, Equatable {
    case profileNotFound(String)
    case profileNeedsLogin(String)
    case nothingToUndo
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

    /// Vuelca el estado activo (credenciales + identidad) a su perfil, si existe.
    public func syncActiveIntoProfile() {
        guard let identity = try? store.readActiveIdentity(),
              let creds = try? store.readActiveCredentials() else { return }
        let known = profiles.loadProfiles().contains { $0.accountUuid == identity.accountUuid }
        guard known else { return }
        try? profiles.saveProfile(identity: identity, credentials: creds)
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

        let previous = activeAccountUuid()
        syncActiveIntoProfile()

        let identity = try target.identity()
        try store.writeActiveCredentials(creds)
        try store.writeActiveIdentity(identity)

        if let previous, previous != accountUuid {
            defaults.set([previous, accountUuid], forKey: Self.lastSwitchKey)
        }
        return identity
    }

    /// Alta de cuenta: guarda la sesión activa de Claude Code como perfil.
    @discardableResult
    public func captureActiveAsProfile() throws -> AccountProfile {
        guard let identity = try store.readActiveIdentity(),
              let creds = try store.readActiveCredentials() else {
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
