import Foundation
import Testing
@testable import ClaudeSwitchCore

/// La app solo puede tocar la entrada de Claude Code y las suyas. Cualquier
/// otra —la app de escritorio de Claude, navegadores, correo…— está fuera de
/// su alcance por construcción.
@Test func soloSePermitenLasEntradasPropiasYLaDeClaudeCode() throws {
    let permitidas = [
        ClaudeCodeStore.credentialsService,
        "ClaudeSwitch-credentials",
        "ClaudeSwitch-profile-abc"
    ]
    for servicio in permitidas {
        #expect(SecurityCLIKeychain.allowedServices.contains(servicio) || servicio.hasPrefix("ClaudeSwitch-profile-"))
    }

    let ajenas = [
        "Claude", "Claude.app", "claude.ai", "Anthropic",
        "Chrome Safe Storage", "iCloud", "com.apple.account", "Slack"
    ]
    let keychain = SecurityCLIKeychain()
    for servicio in ajenas {
        #expect(!SecurityCLIKeychain.allowedServices.contains(servicio))
        // Escribir en una entrada ajena falla siempre, sin llegar al sistema.
        #expect(throws: KeychainError.self) {
            try keychain.writeString("x", service: servicio)
        }
        #expect(throws: KeychainError.self) {
            try keychain.delete(service: servicio)
        }
        // Leer una entrada ajena devuelve nil sin consultar al Llavero.
        #expect(try keychain.readString(service: servicio) == nil)
    }
}
