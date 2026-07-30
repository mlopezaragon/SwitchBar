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
        // Se usa el mismo camino que Claude Code (/usr/bin/security): escribir
        // esta entrada con la API SecItem le rompía la autorización y le hacía
        // pedir la contraseña del Llavero continuamente.
        self.init(
            keychain: SecurityCLIKeychain(),
            claudeJsonURL: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        )
    }

    // MARK: Credenciales (Llavero)

    /// Contenido completo de la entrada del Llavero. Las operaciones que
    /// necesitan leer y escribir (el cambio de cuenta) usan este blob una sola
    /// vez en lugar de encadenar varias lecturas.
    public struct CredentialsBlob: Sendable {
        /// Se guarda como JSON serializado (y no como diccionario) para poder
        /// cruzar límites de concurrencia sin perder la garantía de Sendable.
        let json: Data

        init(json: Data) { self.json = json }

        init(dictionary: [String: Any]) throws {
            self.json = try JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys])
        }

        func dictionary() throws -> [String: Any] {
            guard let dict = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
                throw CoreError.malformedJSON(
                    L10n.tr("core.error.keychain_entry_corrupt")
                )
            }
            return dict
        }

        public var credentials: OAuthCredentials? {
            guard let dict = try? dictionary(),
                  let oauth = dict["claudeAiOauth"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: oauth, options: [.sortedKeys]) else { return nil }
            return try? OAuthCredentials(claudeAiOauthJSON: data)
        }

        /// Copia del blob con `claudeAiOauth` sustituido; el resto (mcpOAuth…) intacto.
        public func replacingCredentials(_ creds: OAuthCredentials) throws -> CredentialsBlob {
            var copy = try dictionary()
            copy["claudeAiOauth"] = try creds.asDictionary()
            return try CredentialsBlob(dictionary: copy)
        }
    }

    public func readCredentialsBlob() throws -> CredentialsBlob? {
        guard let s = try keychain.readString(service: Self.credentialsService) else { return nil }
        let data = Data(s.utf8)
        guard (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] != nil else {
            throw CoreError.malformedJSON(
                L10n.tr("core.error.keychain_entry_object")
            )
        }
        return CredentialsBlob(json: data)
    }

    public func writeCredentialsBlob(_ blob: CredentialsBlob) throws {
        guard let s = String(data: blob.json, encoding: .utf8) else { throw KeychainError.notUTF8 }
        try keychain.writeString(s, service: Self.credentialsService)
    }

    public func readActiveCredentials() throws -> OAuthCredentials? {
        try readCredentialsBlob()?.credentials
    }

    /// Reemplaza únicamente la clave `claudeAiOauth`, preservando el resto.
    ///
    /// Si la entrada existe pero no se puede interpretar, se aborta con error:
    /// escribir "a ciegas" destruiría las demás claves (p. ej. `mcpOAuth.*`).
    public func writeActiveCredentials(_ creds: OAuthCredentials) throws {
        var dict: [String: Any] = [:]
        if let s = try keychain.readString(service: Self.credentialsService) {
            guard let existing = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else {
                throw CoreError.malformedJSON(
                    L10n.tr("core.error.keychain_entry_preserve")
                )
            }
            dict = existing
        }
        dict["claudeAiOauth"] = try creds.asDictionary()
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        guard let s = String(data: data, encoding: .utf8) else { throw KeychainError.notUTF8 }
        try keychain.writeString(s, service: Self.credentialsService)
    }

    // MARK: Identidad (~/.claude.json)

    public func readActiveIdentity() throws -> AccountIdentity? {
        guard FileManager.default.fileExists(atPath: claudeJsonURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: claudeJsonURL)
        guard let dict = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any] else {
            throw CoreError.malformedJSON(
                L10n.tr("core.error.claude_json_object")
            )
        }
        guard let account = dict["oauthAccount"] as? [String: Any] else {
            return nil
        }
        let json = try JSONSerialization.data(withJSONObject: account, options: [.sortedKeys])
        return try AccountIdentity(oauthAccountJSON: json)
    }

    public func identityModificationDate() -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: claudeJsonURL.path
        )
        return attributes?[.modificationDate] as? Date
    }

    /// Sustituye el bloque `oauthAccount` preservando el resto del fichero.
    ///
    /// Si `~/.claude.json` existe pero no se puede leer o parsear (p. ej.
    /// Claude Code lo está reescribiendo en ese instante), se aborta: jamás
    /// se sobrescribe un fichero cuyo contenido no se pudo conservar. Antes
    /// de cada escritura se deja una copia de seguridad al lado.
    public func writeActiveIdentity(_ identity: AccountIdentity) throws {
        var dict: [String: Any] = [:]
        let exists = FileManager.default.fileExists(atPath: claudeJsonURL.path)
        if exists {
            let original = try Data(contentsOf: claudeJsonURL)
            guard let existing = try? JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                throw CoreError.malformedJSON(
                    L10n.tr("core.error.claude_json_preserve")
                )
            }
            dict = existing
            let backupURL = claudeJsonURL.appendingPathExtension("claudeswitch-backup")
            try? SecureFileIO.writeAtomically(original, to: backupURL)
        }
        dict["oauthAccount"] = try identity.asDictionary()
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        try SecureFileIO.writeAtomically(data, to: claudeJsonURL)

        // Verificación: si otra escritura concurrente pisó la nuestra, avisar.
        if try readActiveIdentity()?.accountUuid != identity.accountUuid {
            throw CoreError.malformedJSON(
                L10n.tr("core.error.concurrent_write")
            )
        }
    }
}
