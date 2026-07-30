import Foundation
import LocalAuthentication
import Security

public enum KeychainError: Error {
    case osStatus(OSStatus)
    case notUTF8
    /// La operación necesitaría mostrar una autorización o desbloquear el
    /// Llavero. ClaudeSwitch nunca abre ese diálogo de forma automática.
    case interactionRequired
    /// Fallo del binario `/usr/bin/security`.
    case commandFailed(Int32)
    /// Se intentó tocar una entrada del Llavero ajena a esta app.
    case serviceNotAllowed(String)
}

extension KeychainError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .osStatus(let status):
            return L10n.tr("keychain.error.command_failed_code", status)
        case .notUTF8:
            return L10n.tr("keychain.error.invalid_utf8")
        case .interactionRequired:
            return L10n.tr("keychain.error.interaction_required")
        case .commandFailed(let status):
            // El error no transporta `stderr`: `/usr/bin/security` puede
            // repetir el comando y, con `-X`, incluir el secreto hexadecimal.
            return L10n.tr("keychain.error.command_failed_code", status)
        case .serviceNotAllowed(let service):
            return L10n.tr(
                "keychain.error.service_not_allowed",
                service
            )
        }
    }
}

/// Abstracción del Llavero para poder testear con un doble en memoria.
public protocol KeychainStoring: Sendable {
    func readString(service: String) throws -> String?
    func writeString(_ value: String, service: String) throws
    func delete(service: String) throws
}

/// Entradas genéricas (`kSecClassGenericPassword`) del Llavero de inicio de
/// sesión creadas por ClaudeSwitch. El acceso interactivo está desactivado:
/// una firma rota o un Llavero bloqueado producen un error inmediato, nunca
/// una cascada de cuadros pidiendo la contraseña.
public final class KeychainService: KeychainStoring {
    private let allowedServices: Set<String>

    public init(allowedServices: Set<String>) {
        self.allowedServices = allowedServices
    }

    private func checkAllowed(_ service: String) throws {
        guard allowedServices.contains(service) else {
            throw KeychainError.serviceNotAllowed(service)
        }
    }

    private func baseQuery(service: String) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseAuthenticationContext as String: context
        ]
    }

    private func checked(_ status: OSStatus) throws {
        if status == errSecInteractionNotAllowed || status == errSecInteractionRequired {
            throw KeychainError.interactionRequired
        }
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
    }

    public func readString(service: String) throws -> String? {
        try checkAllowed(service)
        var query = baseQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        try checked(status)
        guard let data = item as? Data, let s = String(data: data, encoding: .utf8) else {
            throw KeychainError.notUTF8
        }
        return s
    }

    public func writeString(_ value: String, service: String) throws {
        try checkAllowed(service)
        let data = Data(value.utf8)
        let query = baseQuery(service: service)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccount as String] = NSUserName()
            add[kSecAttrLabel as String] = L10n.tr("keychain.item.label")
            status = SecItemAdd(add as CFDictionary, nil)
        }
        try checked(status)
    }

    public func delete(service: String) throws {
        try checkAllowed(service)
        let query = baseQuery(service: service)
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound { return }
        try checked(status)
    }
}
