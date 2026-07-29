import Foundation

/// Almacén de secretos en fichero (`secrets.json`, permisos 0600: solo legible
/// por el usuario). Es el mismo enfoque que usa Claude Code cuando no hay
/// Llavero disponible.
///
/// Motivo: los secretos de los perfiles guardados en el Llavero provocaban un
/// diálogo de autorización del sistema en cada consulta de uso (una por cuenta
/// y ronda), y esas autorizaciones se invalidaban con cada actualización de la
/// app. Un fichero 0600 en el directorio del usuario elimina los diálogos por
/// completo con una protección equivalente a la de `~/.claude.json`.
public final class FileVault: KeychainStoring, @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    public init(directoryURL: URL) {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        self.fileURL = directoryURL.appendingPathComponent("secrets.json")
    }

    private func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    private func save(_ dict: [String: String]) throws {
        let data = try JSONEncoder().encode(dict)
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public func readString(service: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return load()[service]
    }

    public func writeString(_ value: String, service: String) throws {
        lock.lock(); defer { lock.unlock() }
        var dict = load()
        dict[service] = value
        try save(dict)
    }

    public func delete(service: String) throws {
        lock.lock(); defer { lock.unlock() }
        var dict = load()
        dict[service] = nil
        try save(dict)
    }
}
