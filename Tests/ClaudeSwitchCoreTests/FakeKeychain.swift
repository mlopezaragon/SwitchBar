import Foundation
@testable import ClaudeSwitchCore

/// Doble del Llavero en memoria, seguro para concurrencia.
final class FakeKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func readString(service: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[service]
    }

    func writeString(_ value: String, service: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[service] = value
    }

    func delete(service: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[service] = nil
    }
}
