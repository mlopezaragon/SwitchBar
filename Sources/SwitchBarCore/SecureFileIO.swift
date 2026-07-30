import Darwin
import Foundation

/// Escritura atómica de ficheros privados.
///
/// `Data.write(.atomic)` crea primero un temporal con los permisos dictados
/// por el umask y solo aplica un chmod después. Para metadatos de cuentas y
/// migraciones de secretos evitamos esa ventana: el temporal nace con 0600,
/// se sincroniza y se renombra atómicamente sobre el destino.
enum SecureFileIO {
    static func ensurePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    static func readIfPresent(_ url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    static func writeAtomically(
        _ data: Data,
        to destination: URL,
        permissions: mode_t = 0o600
    ) throws {
        let directory = destination.deletingLastPathComponent()
        try ensurePrivateDirectory(directory)
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )

        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            permissions
        )
        guard descriptor >= 0 else { throw posixError() }

        var shouldUnlink = true
        defer {
            _ = Darwin.close(descriptor)
            if shouldUnlink { _ = Darwin.unlink(temporary.path) }
        }

        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: written),
                    rawBuffer.count - written
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                written += count
            }
        }

        guard Darwin.fsync(descriptor) == 0 else { throw posixError() }
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            throw posixError()
        }
        shouldUnlink = false

        // Persistir también la entrada de directorio cuando el sistema lo
        // permite. Un fallo aquí no invalida el rename ya completado.
        let directoryFD = Darwin.open(directory.path, O_RDONLY)
        if directoryFD >= 0 {
            _ = Darwin.fsync(directoryFD)
            _ = Darwin.close(directoryFD)
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
