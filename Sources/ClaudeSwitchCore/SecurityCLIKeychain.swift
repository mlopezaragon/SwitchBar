import Foundation

/// Acceso al Llavero a través de `/usr/bin/security`, el mismo camino que usa
/// Claude Code (`find/add/delete-generic-password`).
///
/// Motivo: cuando dos programas distintos tocan la misma entrada, macOS ata la
/// autorización a la firma del que la escribió. Escribir con la API SecItem
/// desde esta app dejaba fuera a `/usr/bin/security`, así que Claude Code
/// volvía a pedir la contraseña del Llavero en cada arranque y el permiso
/// "Permitir siempre" se perdía tras cada cambio de cuenta. Usando el mismo
/// binario —firmado por Apple y con una firma que nunca cambia— la
/// autorización se concede una vez y se mantiene para ambos programas.
public final class SecurityCLIKeychain: KeychainStoring {
    private let account: String

    public init(account: String = NSUserName()) {
        self.account = account
    }

    private static let binary = "/usr/bin/security"

    /// Entradas que esta app puede tocar. Cualquier otra se rechaza: la app de
    /// escritorio de Claude, el navegador y el resto del Llavero quedan fuera
    /// de su alcance por construcción, no por convención.
    public static let allowedServices: Set<String> = [
        ClaudeCodeStore.credentialsService,
        "ClaudeSwitch-credentials",
        "ClaudeSwitch-selftest"
    ]

    private static func isAllowed(_ service: String) -> Bool {
        allowedServices.contains(service) || service.hasPrefix("ClaudeSwitch-profile-")
    }

    private struct Result_ {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    private static func run(_ arguments: [String]) -> Result_ {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return Result_(status: -1, stdout: "", stderr: String(describing: error))
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result_(
            status: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    /// Cuenta con la que está guardada la entrada, para conservarla al
    /// reescribir (Claude Code usa el nombre de usuario de macOS).
    private func existingAccount(service: String) -> String? {
        let result = Self.run(["find-generic-password", "-s", service])
        guard result.status == 0 else { return nil }
        for line in result.stdout.split(separator: "\n") where line.contains("\"acct\"") {
            if let range = line.range(of: "=\"") {
                return String(line[range.upperBound...].dropLast())
            }
        }
        return nil
    }

    public func readString(service: String) throws -> String? {
        guard Self.isAllowed(service) else { return nil }
        let result = Self.run(["find-generic-password", "-s", service, "-w"])
        if result.status == 44 { return nil } // errSecItemNotFound
        guard result.status == 0 else {
            if result.stderr.contains("SecKeychainSearchCopyNext") { return nil }
            throw KeychainError.osStatus(OSStatus(result.status))
        }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    public func writeString(_ value: String, service: String) throws {
        guard Self.isAllowed(service) else { throw KeychainError.serviceNotAllowed(service) }
        // -U actualiza la entrada si ya existe, conservando su identidad.
        // -A la deja accesible sin diálogo para los programas del usuario: es
        // lo que permite que ni esta app ni Claude Code vuelvan a pedir la
        // contraseña del Llavero en cada acceso. La protección efectiva pasa a
        // ser la de la sesión del usuario, como el fichero de credenciales que
        // usa Claude Code en Linux.
        let account = existingAccount(service: service) ?? self.account
        let result = Self.run([
            "add-generic-password", "-U", "-A",
            "-s", service,
            "-a", account,
            "-w", value
        ])
        guard result.status == 0 else { throw KeychainError.osStatus(OSStatus(result.status)) }
    }

    public func delete(service: String) throws {
        guard Self.isAllowed(service) else { throw KeychainError.serviceNotAllowed(service) }
        let result = Self.run(["delete-generic-password", "-s", service])
        guard result.status == 0 || result.status == 44 else {
            throw KeychainError.osStatus(OSStatus(result.status))
        }
    }
}
