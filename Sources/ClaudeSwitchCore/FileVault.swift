import Foundation

/// Lector del formato legado `secrets.json`.
///
/// Ya no es el almacén de producción: los tokens vuelven al Llavero. Se
/// conserva únicamente para migrar instalaciones que usaron temporalmente el
/// fichero 0600. A diferencia de la versión antigua, un JSON corrupto nunca se
/// interpreta como un almacén vacío.
public final class FileVault: KeychainStoring, @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    public init(directoryURL: URL) {
        self.fileURL = directoryURL.appendingPathComponent("secrets.json")
    }

    private func load() throws -> [String: String] {
        guard let data = try SecureFileIO.readIfPresent(fileURL) else { return [:] }
        do {
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            throw CoreError.malformedJSON(
                L10n.tr("core.error.file_vault_corrupt")
            )
        }
    }

    private func save(_ dict: [String: String]) throws {
        let data = try JSONEncoder().encode(dict)
        try SecureFileIO.writeAtomically(data, to: fileURL)
    }

    public func readString(service: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return try load()[service]
    }

    public func writeString(_ value: String, service: String) throws {
        lock.lock(); defer { lock.unlock() }
        var dict = try load()
        dict[service] = value
        try save(dict)
    }

    public func delete(service: String) throws {
        lock.lock(); defer { lock.unlock() }
        var dict = try load()
        dict[service] = nil
        try save(dict)
    }

    func allValues() throws -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return try load()
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    func removeStorageFile() throws {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
