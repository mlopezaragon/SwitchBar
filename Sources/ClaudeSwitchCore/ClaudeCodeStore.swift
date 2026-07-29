import Foundation

/// Lee y escribe el estado de sesión de Claude Code:
/// - Entrada del Llavero "Claude Code-credentials": JSON cuya clave
///   `claudeAiOauth` contiene los tokens de la cuenta activa. La misma entrada
///   guarda otras claves (p. ej. `mcpOAuth.*`) que se preservan siempre.
/// - Bloque `oauthAccount` de `~/.claude.json` con la identidad de la cuenta.
///
/// Regla de oro: releer siempre justo antes de escribir, porque Claude Code
/// puede haber renovado tokens en paralelo.
public struct ClaudeCodeStore: Sendable {
    public static let credentialsService = "Claude Code-credentials"

    let keychain: KeychainStoring
    let claudeJsonURL: URL

    public init(keychain: KeychainStoring, claudeJsonURL: URL) {
        self.keychain = keychain
        self.claudeJsonURL = claudeJsonURL
    }

    public init() {
        self.init(
            keychain: KeychainService(),
            claudeJsonURL: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        )
    }

    // MARK: Credenciales (Llavero)

    public func readActiveCredentials() throws -> OAuthCredentials? {
        guard let s = try keychain.readString(service: Self.credentialsService),
              let dict = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
              let oauth = dict["claudeAiOauth"] as? [String: Any] else { return nil }
        let data = try JSONSerialization.data(withJSONObject: oauth, options: [.sortedKeys])
        return try OAuthCredentials(claudeAiOauthJSON: data)
    }

    /// Reemplaza únicamente la clave `claudeAiOauth`, preservando el resto.
    public func writeActiveCredentials(_ creds: OAuthCredentials) throws {
        var dict: [String: Any] = [:]
        if let s = try keychain.readString(service: Self.credentialsService),
           let existing = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] {
            dict = existing
        }
        dict["claudeAiOauth"] = try creds.asDictionary()
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        guard let s = String(data: data, encoding: .utf8) else { throw KeychainError.notUTF8 }
        try keychain.writeString(s, service: Self.credentialsService)
    }

    // MARK: Identidad (~/.claude.json)

    public func readActiveIdentity() throws -> AccountIdentity? {
        guard let data = try? Data(contentsOf: claudeJsonURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = dict["oauthAccount"] as? [String: Any] else { return nil }
        let json = try JSONSerialization.data(withJSONObject: account, options: [.sortedKeys])
        return try AccountIdentity(oauthAccountJSON: json)
    }

    /// Sustituye el bloque `oauthAccount` preservando el resto del fichero.
    public func writeActiveIdentity(_ identity: AccountIdentity) throws {
        var dict: [String: Any] = [:]
        if let data = try? Data(contentsOf: claudeJsonURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = existing
        }
        dict["oauthAccount"] = try identity.asDictionary()
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        try data.write(to: claudeJsonURL, options: [.atomic])
    }
}
