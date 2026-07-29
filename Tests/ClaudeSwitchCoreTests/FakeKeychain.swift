import Foundation
@testable import ClaudeSwitchCore

/// Doble del Llavero en memoria, seguro para concurrencia.
final class FakeKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]
    /// Accesos por servicio, para verificar que no se piden más de la cuenta
    /// (cada acceso real puede abrir un diálogo de autorización del sistema).
    private(set) var accessCount: [String: Int] = [:]

    func accesses(to service: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return accessCount[service] ?? 0
    }

    func resetCounters() {
        lock.lock(); defer { lock.unlock() }
        accessCount = [:]
    }

    func readString(service: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        accessCount[service, default: 0] += 1
        return storage[service]
    }

    func writeString(_ value: String, service: String) throws {
        lock.lock(); defer { lock.unlock() }
        accessCount[service, default: 0] += 1
        storage[service] = value
    }

    func delete(service: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[service] = nil
    }
}
