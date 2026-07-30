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
        "ClaudeSwitch-selftest"
    ]

    private static func isAllowed(_ service: String) -> Bool {
        allowedServices.contains(service)
    }

    private struct Result_ {
        var status: Int32
        var stdout: String
        var stderr: String
        var timedOut: Bool
    }

    private static func run(
        _ arguments: [String],
        input: Data? = nil,
        timeout: TimeInterval = 12
    ) -> Result_ {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let inputPipe = input.map { _ in Pipe() }
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return Result_(
                status: -1,
                stdout: "",
                stderr: String(describing: error),
                timedOut: false
            )
        }
        if let input, let inputPipe {
            do {
                try inputPipe.fileHandleForWriting.write(contentsOf: input)
                try inputPipe.fileHandleForWriting.close()
            } catch {
                process.terminate()
                return Result_(
                    status: -1,
                    stdout: "",
                    stderr: String(describing: error),
                    timedOut: false
                )
            }
        }
        let timedOut = finished.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        return Result_(
            status: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            timedOut: timedOut
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
        if result.timedOut { throw KeychainError.interactionRequired }
        if result.status == 44 { return nil } // errSecItemNotFound
        guard result.status == 0 else {
            if result.stderr.contains("SecKeychainSearchCopyNext") { return nil }
            throw KeychainError.commandFailed(result.status)
        }
        // `security -w` añade un salto de línea que no forma parte del valor.
        let value = result.stdout.hasSuffix("\n")
            ? String(result.stdout.dropLast())
            : result.stdout
        return value.isEmpty ? nil : value
    }

    public func writeString(_ value: String, service: String) throws {
        guard Self.isAllowed(service) else { throw KeychainError.serviceNotAllowed(service) }
        // Claude Code 2.1.x escribe por `security -i` y pasa el secreto como
        // hexadecimal por stdin mientras cabe en el límite del intérprete.
        // Para blobs grandes usa directamente `add-generic-password -X`:
        // `security -i` corta silenciosamente las líneas alrededor de 4 KiB
        // y dejaría la entrada como un JSON incompleto.
        //
        // Al no indicar -A/-T, la ACL nueva confía únicamente en el proceso
        // creador: /usr/bin/security. Tanto Claude Code como ClaudeSwitch usan
        // ese mismo binario, por lo que /login y los cambios de cuenta siguen
        // siendo compatibles sin diálogos repetidos.
        let account = existingAccount(service: service) ?? self.account
        let invocation = Self.writeInvocation(
            value: value,
            service: service,
            account: account
        )
        let result = Self.run(
            invocation.arguments,
            input: invocation.input.isEmpty
                ? nil
                : Data(invocation.input.utf8)
        )
        if result.timedOut { throw KeychainError.interactionRequired }
        guard result.status == 0 else {
            throw KeychainError.commandFailed(result.status)
        }
    }

    public func delete(service: String) throws {
        guard Self.isAllowed(service) else { throw KeychainError.serviceNotAllowed(service) }
        let result = Self.run(["delete-generic-password", "-s", service])
        if result.timedOut { throw KeychainError.interactionRequired }
        guard result.status == 0 || result.status == 44 else {
            throw KeychainError.commandFailed(result.status)
        }
    }

    /// El intérprete de `security -i` acepta comillas dobles. Los servicios
    /// permitidos son constantes, pero se escapa también la cuenta por defensa
    /// en profundidad.
    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
    }

    /// Margen conservador bajo el búfer de 4 KiB de `security -i`.
    private static let maximumInteractiveCommandBytes = 3_500

    /// Construcción pura usada por las pruebas. Los valores normales viajan
    /// por stdin. Para valores grandes se replica el fallback oficial de
    /// Claude Code a argv, porque truncarlos sería mucho más grave.
    static func writeInvocation(
        value: String,
        service: String,
        account: String
    ) -> (arguments: [String], input: String) {
        let hex = Data(value.utf8).map { String(format: "%02x", $0) }.joined()
        let interactive =
            "add-generic-password -U -a \"\(escaped(account))\" "
            + "-s \"\(escaped(service))\" -X \(hex)\n"
        if interactive.utf8.count <= maximumInteractiveCommandBytes {
            return (["-i"], interactive)
        }
        return (
            [
                "add-generic-password", "-U",
                "-a", account,
                "-s", service,
                "-X", hex
            ],
            ""
        )
    }
}
