import Foundation
import Security

public enum KeychainError: Error {
    case osStatus(OSStatus)
    case notUTF8
}

/// Abstracción del Llavero para poder testear con un doble en memoria.
public protocol KeychainStoring: Sendable {
    func readString(service: String) throws -> String?
    func writeString(_ value: String, service: String) throws
    func delete(service: String) throws
}

/// Entradas genéricas (`kSecClassGenericPassword`) del Llavero de inicio de
/// sesión. La búsqueda es solo por servicio, igual que hace Claude Code con
/// su entrada "Claude Code-credentials".
public final class KeychainService: KeychainStoring {
    public init() {}

    public func readString(service: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
        guard let data = item as? Data, let s = String(data: data, encoding: .utf8) else {
            throw KeychainError.notUTF8
        }
        return s
    }

    public func writeString(_ value: String, service: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccount as String] = NSUserName()
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
    }

    public func delete(service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.osStatus(status)
        }
    }
}
